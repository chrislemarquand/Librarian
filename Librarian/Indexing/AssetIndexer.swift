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

                    try await self.database.jobRepository.markCompleted(job)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

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
    @MainActor init(from asset: PHAsset, lastSeenAt: Date) {
        let subtypes = asset.mediaSubtypes
        let isScreenshot = subtypes.contains(.photoScreenshot)
        let isCloudOnly = !asset.isLocallyAvailable

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
            isCloudOnly: isCloudOnly,
            hasLocalThumbnail: true, // thumbnails are always locally cached by Photos
            hasLocalOriginal: asset.isLocallyAvailable,
            iCloudDownloadState: isCloudOnly ? "pending" : "notRequired",
            analysisVersion: 0,
            lastSeenInLibraryAt: lastSeenAt,
            isDeletedFromPhotos: false
        )
    }
}

// MARK: - PHAsset local availability

private extension PHAsset {
    /// True when the original resource is present on disk (not cloud-only).
    var isLocallyAvailable: Bool {
        let resources = PHAssetResource.assetResources(for: self)
        return resources.contains { resource in
            let key = "locallyAvailable" as NSString
            let value = resource.value(forKey: key as String)
            if let boolValue = value as? Bool { return boolValue }
            return true // Assume local if key unavailable
        }
    }
}
