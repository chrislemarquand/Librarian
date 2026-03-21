import Foundation
import Photos
import CryptoKit
import ImageIO

enum ArchiveExactMatchOutcome: Equatable {
    case exactMatch(photoLibraryLocalIdentifier: String)
    case noMatch
    case indeterminate(reason: String)
}

struct ArchiveExactDedupeResult {
    let fileURL: URL
    let outcome: ArchiveExactMatchOutcome
    let candidateCount: Int
}

protocol ArchiveExactDedupeClassifying: Sendable {
    func classifyFiles(_ fileURLs: [URL], allowNetworkAccess: Bool) async -> [ArchiveExactDedupeResult]
}

/// Exact dedupe service for archive imports.
///
/// Strategy:
/// 1) Cheap prefilter from indexed PhotoKit metadata (size/date) via DB.
/// 2) SHA-256 exact check against narrowed candidates only.
/// 3) Lazy cache of PhotoKit content hashes in DB for reuse.
final class ArchiveExactDedupeService: @unchecked Sendable {
    private let database: DatabaseManager
    private let photosService: PhotosLibraryService
    private let fileManager = FileManager.default

    private let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "heic", "heif", "png", "tif", "tiff"
    ]

    init(database: DatabaseManager, photosService: PhotosLibraryService) {
        self.database = database
        self.photosService = photosService
    }

    func classifyFiles(
        _ fileURLs: [URL],
        allowNetworkAccess: Bool = false
    ) async -> [ArchiveExactDedupeResult] {
        var results: [ArchiveExactDedupeResult] = []
        results.reserveCapacity(fileURLs.count)
        for fileURL in fileURLs {
            let result = await classifyFile(fileURL, allowNetworkAccess: allowNetworkAccess)
            results.append(result)
        }
        return results
    }

    func classifyFile(
        _ fileURL: URL,
        allowNetworkAccess: Bool = false
    ) async -> ArchiveExactDedupeResult {
        do {
            let metadata = try readIncomingMetadata(fileURL)
            guard let fileSizeBytes = metadata.fileSizeBytes else {
                return ArchiveExactDedupeResult(
                    fileURL: fileURL,
                    outcome: .indeterminate(reason: "Unable to read file size."),
                    candidateCount: 0
                )
            }

            let primaryCandidates = try database.assetRepository.fetchPhotoLibraryHashCandidates(
                fileSizeBytes: fileSizeBytes,
                creationDate: metadata.captureDate,
                maxResults: 500
            )
            let candidates: [PhotoLibraryHashCandidate]
            if primaryCandidates.isEmpty, metadata.captureDate != nil {
                // Fallback to size-only prefilter when capture-date precision differs.
                candidates = try database.assetRepository.fetchPhotoLibraryHashCandidates(
                    fileSizeBytes: fileSizeBytes,
                    creationDate: nil,
                    maxResults: 500
                )
            } else {
                candidates = primaryCandidates
            }

            guard !candidates.isEmpty else {
                return ArchiveExactDedupeResult(fileURL: fileURL, outcome: .noMatch, candidateCount: 0)
            }

            let incomingHash = try sha256Hex(ofFileAt: fileURL)
            for candidate in candidates {
                let candidateHash = try await hashForPhotoLibraryCandidate(
                    candidate,
                    allowNetworkAccess: allowNetworkAccess
                )
                guard let candidateHash else { continue }
                if candidateHash == incomingHash {
                    return ArchiveExactDedupeResult(
                        fileURL: fileURL,
                        outcome: .exactMatch(photoLibraryLocalIdentifier: candidate.localIdentifier),
                        candidateCount: candidates.count
                    )
                }
            }

            return ArchiveExactDedupeResult(fileURL: fileURL, outcome: .noMatch, candidateCount: candidates.count)
        } catch {
            return ArchiveExactDedupeResult(
                fileURL: fileURL,
                outcome: .indeterminate(reason: error.localizedDescription),
                candidateCount: 0
            )
        }
    }

    private func hashForPhotoLibraryCandidate(
        _ candidate: PhotoLibraryHashCandidate,
        allowNetworkAccess: Bool
    ) async throws -> String? {
        if let cached = normalizedHashHex(candidate.contentHashSHA256) {
            return cached
        }
        guard let asset = photosService.fetchAsset(localIdentifier: candidate.localIdentifier) else {
            return nil
        }
        guard let resource = preferredResource(for: asset) else {
            return nil
        }

        let hash = try await sha256Hex(for: resource, allowNetworkAccess: allowNetworkAccess)
        try database.assetRepository.updatePhotoLibraryContentHash(
            localIdentifier: candidate.localIdentifier,
            hashHex: hash
        )
        return hash
    }

    private func preferredResource(for asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        guard !resources.isEmpty else { return nil }
        return resources.first(where: { $0.type == .fullSizePhoto })
            ?? resources.first(where: { $0.type == .photo })
            ?? resources.first(where: { $0.type == .alternatePhoto })
            ?? resources.first
    }

    private struct IncomingMetadata {
        let fileSizeBytes: Int?
        let captureDate: Date?
    }

    private func readIncomingMetadata(_ fileURL: URL) throws -> IncomingMetadata {
        let keys: Set<URLResourceKey> = [.fileSizeKey]
        let values = try fileURL.resourceValues(forKeys: keys)
        return IncomingMetadata(
            fileSizeBytes: values.fileSize,
            captureDate: readCaptureDateIfAvailable(from: fileURL)
        )
    }

    private func normalizedHashHex(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.count == 64 else { return nil }
        return trimmed
    }

    private func sha256Hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 65_536)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02hhx", $0) }.joined()
    }

    private func sha256Hex(for resource: PHAssetResource, allowNetworkAccess: Bool) async throws -> String {
        let tempURL = fileManager.temporaryDirectory
            .appendingPathComponent("librarian-asset-hash-\(UUID().uuidString)")
            .appendingPathExtension("tmp")

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = allowNetworkAccess
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(
                for: resource,
                toFile: tempURL,
                options: options
            ) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }

        defer { try? fileManager.removeItem(at: tempURL) }
        return try sha256Hex(ofFileAt: tempURL)
    }

    private func readCaptureDateIfAvailable(from fileURL: URL) -> Date? {
        let lowerExt = fileURL.pathExtension.lowercased()
        guard supportedExtensions.contains(lowerExt) else { return nil }
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"

        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            if let str = exif[kCGImagePropertyExifDateTimeOriginal] as? String,
               let date = formatter.date(from: str) { return date }
            if let str = exif[kCGImagePropertyExifDateTimeDigitized] as? String,
               let date = formatter.date(from: str) { return date }
        }
        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let str = tiff[kCGImagePropertyTIFFDateTime] as? String {
            return formatter.date(from: str)
        }
        return nil
    }
}

extension ArchiveExactDedupeService: ArchiveExactDedupeClassifying {}
