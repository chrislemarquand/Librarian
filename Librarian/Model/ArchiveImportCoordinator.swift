import Foundation
import CryptoKit
import ImageIO

// MARK: - Result types

struct ArchiveImportPreflightResult: Sendable {
    let totalDiscovered: Int
    let duplicatesInSource: Int
    let existsInPhotoKit: Int
    let toImport: Int
    let candidateURLs: [URL]
}

struct ArchiveImportRunSummary: Sendable {
    let imported: Int
    let skippedDuplicateInSource: Int
    let skippedExistsInPhotoKit: Int
    let failed: Int
    let failures: [(path: String, reason: String)]
    let completedAt: Date
}

enum ArchiveImportProgressEvent: Sendable {
    case progress(completed: Int, total: Int)
    case done(summary: ArchiveImportRunSummary)
}

// MARK: - Coordinator

final class ArchiveImportCoordinator: @unchecked Sendable {

    private let archiveRoot: URL
    private let sourceFolders: [URL]
    private let database: DatabaseManager
    private let fileManager = FileManager.default

    private static let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "heic", "heif", "png", "tif", "tiff"
    ]

    init(archiveRoot: URL, sourceFolders: [URL], database: DatabaseManager) {
        self.archiveRoot = archiveRoot
        self.sourceFolders = sourceFolders
        self.database = database
    }

    // MARK: - Preflight (blocking — call on a background thread)

    func runPreflight() throws -> ArchiveImportPreflightResult {
        // Enumerate eligible files from all source folders (read-only).
        var allFiles: [URL] = []
        for sourceFolder in sourceFolders {
            let didAccess = sourceFolder.startAccessingSecurityScopedResource()
            defer { if didAccess { sourceFolder.stopAccessingSecurityScopedResource() } }
            try enumerateFiles(in: sourceFolder) { url in
                allFiles.append(url)
            }
        }

        // SHA-256 in-source deduplication.
        var seenHashes = Set<String>()
        var deduplicatedFiles: [URL] = []
        var duplicatesInSource = 0
        for fileURL in allFiles {
            let hash = try sha256(of: fileURL)
            if seenHashes.contains(hash) {
                duplicatesInSource += 1
            } else {
                seenHashes.insert(hash)
                deduplicatedFiles.append(fileURL)
            }
        }

        // Check deduplicated files against the PhotoKit asset index.
        // Exact match: same file size AND same capture day (YYYY-MM-DD).
        let photoKitIndex = try database.assetRepository.fetchAssetSizeDayIndex()
        var candidateURLs: [URL] = []
        var existsInPhotoKit = 0
        for fileURL in deduplicatedFiles {
            let size = fileSizeBytes(of: fileURL)
            if size > 0, matchesPhotoKit(fileURL: fileURL, fileSize: size, index: photoKitIndex) {
                existsInPhotoKit += 1
            } else {
                candidateURLs.append(fileURL)
            }
        }

        return ArchiveImportPreflightResult(
            totalDiscovered: allFiles.count,
            duplicatesInSource: duplicatesInSource,
            existsInPhotoKit: existsInPhotoKit,
            toImport: candidateURLs.count,
            candidateURLs: candidateURLs
        )
    }

    // MARK: - Import

    func runImport(preflight: ArchiveImportPreflightResult) -> AsyncThrowingStream<ArchiveImportProgressEvent, Error> {
        AsyncThrowingStream { continuation in
            Task.detached(priority: .utility) { [self] in
                do {
                    let importResult = try self.performImport(candidates: preflight.candidateURLs) { completed, total in
                        continuation.yield(.progress(completed: completed, total: total))
                    }
                    let summary = ArchiveImportRunSummary(
                        imported: importResult.imported,
                        skippedDuplicateInSource: preflight.duplicatesInSource,
                        skippedExistsInPhotoKit: preflight.existsInPhotoKit,
                        failed: importResult.failed,
                        failures: importResult.failures,
                        completedAt: importResult.completedAt
                    )
                    continuation.yield(.done(summary: summary))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Import execution

    private struct ImportResult {
        let imported: Int
        let failed: Int
        let failures: [(path: String, reason: String)]
        let completedAt: Date
    }

    private func performImport(
        candidates: [URL],
        onProgress: @escaping (Int, Int) -> Void
    ) throws -> ImportResult {
        let archiveTreeRoot = archiveRoot.appendingPathComponent("Archive", isDirectory: true)

        let archiveAccess = archiveRoot.startAccessingSecurityScopedResource()
        defer { if archiveAccess { archiveRoot.stopAccessingSecurityScopedResource() } }

        // Maintain source folder access for the duration of the copy.
        var sourceAccess: [(URL, Bool)] = []
        for folder in sourceFolders {
            sourceAccess.append((folder, folder.startAccessingSecurityScopedResource()))
        }
        defer {
            for (folder, didAccess) in sourceAccess {
                if didAccess { folder.stopAccessingSecurityScopedResource() }
            }
        }

        try fileManager.createDirectory(at: archiveTreeRoot, withIntermediateDirectories: true)

        let total = candidates.count
        var imported = 0
        var failures: [(path: String, reason: String)] = []

        for (index, sourceURL) in candidates.enumerated() {
            do {
                let modDate = (try? sourceURL.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? Date()
                let captureDate = readCaptureDateIfAvailable(from: sourceURL) ?? modDate

                let cal = Calendar(identifier: .gregorian)
                let comps = cal.dateComponents([.year, .month, .day], from: captureDate)
                let year  = String(format: "%04d", comps.year  ?? 1970)
                let month = String(format: "%02d", comps.month ?? 1)
                let day   = String(format: "%02d", comps.day   ?? 1)

                let destDir = archiveTreeRoot
                    .appendingPathComponent(year,  isDirectory: true)
                    .appendingPathComponent(month, isDirectory: true)
                    .appendingPathComponent(day,   isDirectory: true)
                try fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)

                let destURL = uniqueDestinationURL(in: destDir, fileName: sourceURL.lastPathComponent)
                try fileManager.copyItem(at: sourceURL, to: destURL)
                imported += 1
            } catch {
                failures.append((sourceURL.path, error.localizedDescription))
            }
            onProgress(index + 1, total)
        }

        // Remove only empty intermediate directories created during this import.
        // Source folders are never touched.
        removeEmptyIntermediateDirectories(in: archiveTreeRoot)

        return ImportResult(
            imported: imported,
            failed: failures.count,
            failures: failures,
            completedAt: Date()
        )
    }

    // MARK: - Helpers

    private func enumerateFiles(in folder: URL, visitor: (URL) throws -> Void) throws {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants, .skipsHiddenFiles]
        ) else { return }

        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent.hasPrefix(".") { continue }
            let ext = fileURL.pathExtension.lowercased()
            guard Self.supportedExtensions.contains(ext) else { continue }
            let values = try? fileURL.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            try visitor(fileURL)
        }
    }

    private func sha256(of url: URL) throws -> String {
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

    private func fileSizeBytes(of url: URL) -> Int64 {
        (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    private func matchesPhotoKit(fileURL: URL, fileSize: Int64, index: [Int64: Set<String>]) -> Bool {
        guard let dayStrings = index[fileSize] else { return false }
        let captureDate = readCaptureDateIfAvailable(from: fileURL)
            ?? (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? Date()
        return dayStrings.contains(dayString(from: captureDate))
    }

    private func readCaptureDateIfAvailable(from fileURL: URL) -> Date? {
        let lowerExt = fileURL.pathExtension.lowercased()
        guard Self.supportedExtensions.contains(lowerExt) else { return nil }
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

    private func dayString(from date: Date) -> String {
        let cal = Calendar(identifier: .gregorian)
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private func uniqueDestinationURL(in directory: URL, fileName: String) -> URL {
        var candidate = directory.appendingPathComponent(fileName, isDirectory: false)
        guard fileManager.fileExists(atPath: candidate.path) else { return candidate }
        let ext = (fileName as NSString).pathExtension
        let baseName = (fileName as NSString).deletingPathExtension
        var counter = 2
        while true {
            let suffix = "-\(counter)"
            let nextName = ext.isEmpty ? "\(baseName)\(suffix)" : "\(baseName)\(suffix).\(ext)"
            candidate = directory.appendingPathComponent(nextName, isDirectory: false)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            counter += 1
        }
    }

    private func removeEmptyIntermediateDirectories(in root: URL) {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants, .skipsHiddenFiles]
        ) else { return }

        var directories: [URL] = []
        for case let url as URL in enumerator {
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                directories.append(url)
            }
        }
        // Deepest first so we remove children before parents.
        directories.sort { $0.pathComponents.count > $1.pathComponents.count }
        for dir in directories {
            if dir.standardizedFileURL == root.standardizedFileURL { continue }
            if let contents = try? fileManager.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ), contents.isEmpty {
                try? fileManager.removeItem(at: dir)
            }
        }
    }
}
