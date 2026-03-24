import Foundation
import ImageIO
import CryptoKit

struct ArchiveIndexRefreshSummary {
    let unorganizedCount: Int

    static let empty = ArchiveIndexRefreshSummary(unorganizedCount: 0)
}

final class ArchiveIndexer: @unchecked Sendable {
    private let database: DatabaseManager
    private let fileManager = FileManager.default
    private let organizer = ArchiveOrganizer()
    private let supportedExtensions: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "tif", "tiff"]
    private let exifDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()

    init(database: DatabaseManager) {
        self.database = database
    }

    func refreshIndex() throws -> ArchiveIndexRefreshSummary {
        guard database.assetRepository != nil else { return .empty }

        guard let archiveTreeRoot = ArchiveSettings.currentArchiveTreeRootURL() else {
            let existing = try database.assetRepository.fetchArchivedSignatures()
            if !existing.isEmpty {
                try database.assetRepository.deleteArchivedItems(relativePaths: Array(existing.keys))
            }
            return .empty
        }

        let didAccess = archiveTreeRoot.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                archiveTreeRoot.stopAccessingSecurityScopedResource()
            }
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: archiveTreeRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            let existing = try database.assetRepository.fetchArchivedSignatures()
            if !existing.isEmpty {
                try database.assetRepository.deleteArchivedItems(relativePaths: Array(existing.keys))
            }
            return .empty
        }

        let existing = try database.assetRepository.fetchArchivedSignatures()
        var seenRelativePaths = Set<String>()
        var upserts: [ArchivedItem] = []
        let now = Date()

        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]
        guard let enumerator = fileManager.enumerator(
            at: archiveTreeRoot,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants, .skipsHiddenFiles]
        ) else {
            return .empty
        }

        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent.hasPrefix(".") {
                continue
            }
            let lowerExtension = fileURL.pathExtension.lowercased()
            guard supportedExtensions.contains(lowerExtension) else { continue }

            let resourceValues = try? fileURL.resourceValues(forKeys: Set(keys))
            guard resourceValues?.isRegularFile == true else { continue }

            let relativePath = fileURL.path.replacingOccurrences(of: archiveTreeRoot.path + "/", with: "")
            guard !relativePath.hasPrefix(".librarian-thumbnails/") else { continue }
            seenRelativePaths.insert(relativePath)

            let fileSize = Int64(resourceValues?.fileSize ?? 0)
            let fileModificationDate = resourceValues?.contentModificationDate ?? now
            if let signature = existing[relativePath],
               signature.fileSizeBytes == fileSize,
               signature.fileModificationDate == fileModificationDate {
                continue
            }

            let metadata = readMetadata(from: fileURL)
            let thumbnailRelativePath = ".librarian-thumbnails/\(sha256Hex(relativePath)).jpg"
            upserts.append(
                ArchivedItem(
                    relativePath: relativePath,
                    absolutePath: fileURL.path,
                    filename: fileURL.lastPathComponent,
                    fileExtension: lowerExtension,
                    fileSizeBytes: fileSize,
                    fileModificationDate: fileModificationDate,
                    captureDate: metadata.captureDate,
                    sortDate: metadata.captureDate ?? fileModificationDate,
                    pixelWidth: metadata.pixelWidth,
                    pixelHeight: metadata.pixelHeight,
                    thumbnailRelativePath: thumbnailRelativePath,
                    lastIndexedAt: now
                )
            )
        }

        let deletedRelativePaths = existing.keys.filter { !seenRelativePaths.contains($0) }
        if !deletedRelativePaths.isEmpty {
            try database.assetRepository.deleteArchivedItems(relativePaths: deletedRelativePaths)
        }
        if !upserts.isEmpty {
            try database.assetRepository.upsertArchivedItems(upserts)
        }
        let unorganizedCount = (try? organizer.scanUnorganizedCount(in: archiveTreeRoot)) ?? 0
        return ArchiveIndexRefreshSummary(unorganizedCount: unorganizedCount)
    }

    private func readMetadata(from fileURL: URL) -> (captureDate: Date?, pixelWidth: Int, pixelHeight: Int) {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return (nil, 0, 0)
        }

        let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int ?? 0

        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            if let date = parseDate(exif[kCGImagePropertyExifDateTimeOriginal] as? String) {
                return (date, pixelWidth, pixelHeight)
            }
            if let date = parseDate(exif[kCGImagePropertyExifDateTimeDigitized] as? String) {
                return (date, pixelWidth, pixelHeight)
            }
        }
        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let date = parseDate(tiff[kCGImagePropertyTIFFDateTime] as? String) {
            return (date, pixelWidth, pixelHeight)
        }

        return (nil, pixelWidth, pixelHeight)
    }

    private func parseDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        return exifDateFormatter.date(from: value)
    }

    private func sha256Hex(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
