import Foundation
import Photos

struct IndexingProgressUpdate {
    let completed: Int
    let total: Int
}

/// Reads PHAssets from PhotoKit and upserts them into the GRDB asset table.
/// Yields progress updates via an AsyncStream. Must be run off the main thread.
struct AssetIndexer {

    private let database: DatabaseManager
    private let batchSize = 500

    init(database: DatabaseManager) {
        self.database = database
    }

    func run() -> AsyncThrowingStream<IndexingProgressUpdate, Error> {
        AsyncThrowingStream { continuation in
            Task.detached(priority: .utility) {
                do {
                    let result = PHAsset.fetchAssets(with: Self.fetchOptions())
                    let total = result.count

                    guard total > 0 else {
                        continuation.finish()
                        return
                    }

                    // Create a job record
                    let job = try await self.database.jobRepository.create(type: .initialIndex)
                    try await self.database.jobRepository.markRunning(job)

                    // Collect all assets synchronously first, then upsert in async batches.
                    let now = Date()
                    var allAssets: [IndexedAsset] = []
                    allAssets.reserveCapacity(total)
                    result.enumerateObjects { asset, _, _ in
                        allAssets.append(IndexedAsset(from: asset, lastSeenAt: now))
                    }

                    var completed = 0
                    var offset = 0
                    while offset < allAssets.count {
                        let batch = Array(allAssets[offset ..< min(offset + self.batchSize, allAssets.count)])
                        try await self.database.assetRepository.upsert(batch)
                        completed += batch.count
                        offset += self.batchSize
                        continuation.yield(IndexingProgressUpdate(completed: completed, total: total))
                    }

                    // Catch WhatsApp assets whose filenames don't match the pattern
                    // (e.g. forwarded media) by scanning the WhatsApp album directly.
                    let waOptions = PHFetchOptions()
                    waOptions.predicate = NSPredicate(format: "localizedTitle == %@", "WhatsApp")
                    let waCollections = PHAssetCollection.fetchAssetCollections(
                        with: .album, subtype: .any, options: waOptions
                    )
                    if let waAlbum = waCollections.firstObject {
                        let waAssets = PHAsset.fetchAssets(in: waAlbum, options: nil)
                        var waIdentifiers: [String] = []
                        waAssets.enumerateObjects { asset, _, _ in waIdentifiers.append(asset.localIdentifier) }
                        if !waIdentifiers.isEmpty {
                            try self.database.assetRepository.markWhatsAppFromAlbum(identifiers: waIdentifiers)
                        }
                    }

                    try await self.database.jobRepository.markCompleted(job)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    nonisolated static func isWhatsAppFilename(_ filename: String) -> Bool {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let lowercased = trimmed.lowercased()
        if lowercased.hasPrefix("whatsapp image ") || lowercased.hasPrefix("whatsapp video ") {
            return true
        }

        let nsName = lowercased as NSString
        let ext = nsName.pathExtension
        guard Self.whatsAppUUIDFilenameExtensions.contains(ext) else { return false }

        let stem = nsName.deletingPathExtension
        let normalizedStem = stem.replacingOccurrences(
            of: #" \(\d+\)$"#,
            with: "",
            options: .regularExpression
        )
        return UUID(uuidString: normalizedStem) != nil
    }

    private nonisolated static let whatsAppUUIDFilenameExtensions: Set<String> = [
        "jpg", "jpeg", "heic", "png", "webp"
    ]

    private nonisolated static func fetchOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.includeHiddenAssets = true
        options.includeAllBurstAssets = false
        return options
    }
}

// MARK: - IndexedAsset init from PHAsset

extension IndexedAsset {
    init(from asset: PHAsset, lastSeenAt: Date) {
        let subtypes = asset.mediaSubtypes
        let isScreenshot = subtypes.contains(.photoScreenshot)
        let isCloudShared = asset.isSharedLibraryItem

        let resources = PHAssetResource.assetResources(for: asset)
        let locallyAvailable = resources.contains { resource in
            let value = resource.value(forKey: "locallyAvailable")
            if let boolValue = value as? Bool { return boolValue }
            return true
        }
        let primaryFilename = resources.first?.originalFilename ?? ""
        let isWhatsApp = AssetIndexer.isWhatsAppFilename(primaryFilename)

        self.init(
            localIdentifier: asset.localIdentifier,
            creationDate: asset.creationDate,
            modificationDate: asset.modificationDate,
            mediaType: asset.mediaType.rawValue,
            mediaSubtypes: Int(subtypes.rawValue),
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            duration: asset.duration,
            isFavorite: asset.isFavorite,
            isHidden: asset.isHidden,
            isScreenshot: isScreenshot,
            isCloudShared: isCloudShared,
            isWhatsApp: isWhatsApp,
            isCloudOnly: !locallyAvailable,
            hasLocalThumbnail: true, // thumbnails are always locally cached by Photos
            hasLocalOriginal: locallyAvailable,
            iCloudDownloadState: locallyAvailable ? "notRequired" : "pending",
            analysisVersion: 0,
            lastSeenInLibraryAt: lastSeenAt,
            isDeletedFromPhotos: false
        )
    }
}

// MARK: - PHAsset local availability

private extension PHAsset {
    var isSharedLibraryItem: Bool {
        if sourceType.contains(.typeCloudShared) {
            return true
        }

        // iCloud Shared Library items on macOS currently surface via this runtime flag.
        // Keep this as a fallback when sourceType does not expose the scope.
        if let participatesInLibraryScope = value(forKey: "participatesInLibraryScope") as? Bool {
            return participatesInLibraryScope
        }
        return false
    }

}
