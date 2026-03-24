import Foundation
import CryptoKit
import ImageIO

// MARK: - Result types

struct ArchiveImportPreflightResult: Sendable {
    let totalDiscovered: Int
    let duplicatesInSource: Int
    let existsInPhotoKit: Int
    let existsInArchive: Int
    let toImport: Int
    let candidateURLs: [URL]

    init(
        totalDiscovered: Int,
        duplicatesInSource: Int,
        existsInPhotoKit: Int,
        existsInArchive: Int = 0,
        toImport: Int,
        candidateURLs: [URL]
    ) {
        self.totalDiscovered = totalDiscovered
        self.duplicatesInSource = duplicatesInSource
        self.existsInPhotoKit = existsInPhotoKit
        self.existsInArchive = existsInArchive
        self.toImport = toImport
        self.candidateURLs = candidateURLs
    }
}

struct ArchiveImportRunSummary: Sendable {
    let imported: Int
    let skippedDuplicateInSource: Int
    let skippedExistsInPhotoKit: Int
    let skippedExistsInArchive: Int
    let failed: Int
    let failures: [(path: String, reason: String)]
    let completedAt: Date

    init(
        imported: Int,
        skippedDuplicateInSource: Int,
        skippedExistsInPhotoKit: Int,
        skippedExistsInArchive: Int = 0,
        failed: Int,
        failures: [(path: String, reason: String)],
        completedAt: Date
    ) {
        self.imported = imported
        self.skippedDuplicateInSource = skippedDuplicateInSource
        self.skippedExistsInPhotoKit = skippedExistsInPhotoKit
        self.skippedExistsInArchive = skippedExistsInArchive
        self.failed = failed
        self.failures = failures
        self.completedAt = completedAt
    }
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
    private let exactDedupeClassifier: ArchiveExactDedupeClassifying?
    private let fileManager = FileManager.default

    private static let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "heic", "heif", "png", "tif", "tiff"
    ]

    init(
        archiveRoot: URL,
        sourceFolders: [URL],
        database: DatabaseManager,
        photosService: PhotosLibraryService? = nil,
        exactDedupeClassifier: ArchiveExactDedupeClassifying? = nil
    ) {
        self.archiveRoot = archiveRoot
        self.sourceFolders = sourceFolders
        self.database = database
        self.exactDedupeClassifier = exactDedupeClassifier
            ?? photosService.map { ArchiveExactDedupeService(database: database, photosService: $0) }
    }

    // MARK: - Preflight (blocking — call on a background thread)

    func runPreflight() async throws -> ArchiveImportPreflightResult {
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
        var hashByURL: [URL: String] = [:]
        var duplicatesInSource = 0
        for fileURL in allFiles {
            let hash = try sha256(of: fileURL)
            hashByURL[fileURL.standardizedFileURL] = hash
            if seenHashes.contains(hash) {
                duplicatesInSource += 1
            } else {
                seenHashes.insert(hash)
                deduplicatedFiles.append(fileURL)
            }
        }

        var candidateURLs = deduplicatedFiles
        var existsInPhotoKit = 0
        if let exactDedupeClassifier {
            let results = await exactDedupeClassifier.classifyFiles(deduplicatedFiles, allowNetworkAccess: false)
            let partition = Self.partitionAfterExactDedupe(deduplicatedFiles: deduplicatedFiles, results: results)
            candidateURLs = partition.candidateURLs
            existsInPhotoKit = partition.existsInPhotoKit
        } else {
            // Fallback for callers that don't provide PhotosLibraryService yet.
            let photoKitIndex = try database.assetRepository.fetchAssetDateSecondIndex()
            candidateURLs.removeAll(keepingCapacity: true)
            for fileURL in deduplicatedFiles {
                if matchesPhotoKit(fileURL: fileURL, index: photoKitIndex) {
                    existsInPhotoKit += 1
                } else {
                    candidateURLs.append(fileURL)
                }
            }
        }

        let archiveHashes = try existingArchiveHashes()
        var seenArchiveHashes = archiveHashes
        var existsInArchive = 0
        var archiveFilteredCandidates: [URL] = []
        archiveFilteredCandidates.reserveCapacity(candidateURLs.count)
        for fileURL in candidateURLs {
            let standardized = fileURL.standardizedFileURL
            let incomingHash: String
            if let knownHash = hashByURL[standardized] {
                incomingHash = knownHash
            } else {
                incomingHash = try sha256(of: fileURL)
            }
            if seenArchiveHashes.contains(incomingHash) {
                existsInArchive += 1
            } else {
                seenArchiveHashes.insert(incomingHash)
                archiveFilteredCandidates.append(fileURL)
            }
        }
        candidateURLs = archiveFilteredCandidates

        return ArchiveImportPreflightResult(
            totalDiscovered: allFiles.count,
            duplicatesInSource: duplicatesInSource,
            existsInPhotoKit: existsInPhotoKit,
            existsInArchive: existsInArchive,
            toImport: candidateURLs.count,
            candidateURLs: candidateURLs
        )
    }

    nonisolated static func partitionAfterExactDedupe(
        deduplicatedFiles: [URL],
        results: [ArchiveExactDedupeResult]
    ) -> (candidateURLs: [URL], existsInPhotoKit: Int) {
        let outcomeByURL = Dictionary(
            uniqueKeysWithValues: results.map { ($0.fileURL.standardizedFileURL, $0.outcome) }
        )
        var candidateURLs: [URL] = []
        candidateURLs.reserveCapacity(deduplicatedFiles.count)
        var existsInPhotoKit = 0
        for fileURL in deduplicatedFiles {
            switch outcomeByURL[fileURL.standardizedFileURL] {
            case .exactMatch:
                existsInPhotoKit += 1
            case .none, .noMatch, .indeterminate:
                candidateURLs.append(fileURL)
            }
        }
        return (candidateURLs, existsInPhotoKit)
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
                        skippedExistsInArchive: preflight.existsInArchive,
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
        let archiveTreeRoot = ArchiveSettings.importDestinationRoot(from: archiveRoot)

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
                let captureDate = bestAvailableDate(for: sourceURL)

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

    private func matchesPhotoKit(fileURL: URL, index: Set<String>) -> Bool {
        // Only EXIF timestamps are precise enough to reliably match a PHAsset.
        // Filename/filesystem dates are not reliable enough — if we can't read
        // EXIF, we import the file rather than risk wrongly skipping it.
        guard let exifDate = readCaptureDateIfAvailable(from: fileURL) else { return false }
        return index.contains(secondString(from: exifDate))
    }

    private func existingArchiveHashes() throws -> Set<String> {
        let archiveTreeRoot = ArchiveSettings.importDestinationRoot(from: archiveRoot)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: archiveTreeRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return []
        }

        let didAccess = archiveRoot.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                archiveRoot.stopAccessingSecurityScopedResource()
            }
        }

        var hashes = Set<String>()
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = fileManager.enumerator(
            at: archiveTreeRoot,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants, .skipsHiddenFiles]
        ) else { return [] }

        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent.hasPrefix(".") { continue }
            let ext = fileURL.pathExtension.lowercased()
            guard Self.supportedExtensions.contains(ext) else { continue }
            let values = try? fileURL.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            if let hash = try? sha256(of: fileURL) {
                hashes.insert(hash)
            }
        }
        return hashes
    }

    /// Best-effort date for routing a file into the archive.
    /// Priority: EXIF capture date → filename-embedded date → file creation date → file modification date.
    private func bestAvailableDate(for fileURL: URL) -> Date {
        if let exif = readCaptureDateIfAvailable(from: fileURL) { return exif }
        if let fromName = parseDateFromFilename(fileURL.lastPathComponent) { return fromName }
        let keys: Set<URLResourceKey> = [.creationDateKey, .contentModificationDateKey]
        if let values = try? fileURL.resourceValues(forKeys: keys) {
            if let created = values.creationDate { return created }
            if let modified = values.contentModificationDate { return modified }
        }
        return Date()
    }

    /// Tries to extract a date from common camera/export filename patterns:
    /// - Separated: `YYYY-MM-DD`, `YYYY_MM_DD`, `YYYY.MM.DD`
    /// - Compact:   `YYYYMMDD` (e.g. `IMG_20230415_142530`)
    private func parseDateFromFilename(_ filename: String) -> Date? {
        let stem = (filename as NSString).deletingPathExtension
        let cal = Calendar(identifier: .gregorian)

        // Separated pattern: YYYY[-_.]MM[-_.]DD
        let separated = Self.separatedDateRegex
        if let m = separated.firstMatch(in: stem, range: NSRange(stem.startIndex..., in: stem)),
           let range = Range(m.range(at: 0), in: stem) {
            let digits = String(stem[range]).filter(\.isNumber)
            if digits.count >= 8,
               let y = Int(digits.prefix(4)),
               let mo = Int(digits.dropFirst(4).prefix(2)),
               let d = Int(digits.dropFirst(6).prefix(2)),
               mo >= 1, mo <= 12, d >= 1, d <= 31 {
                return cal.date(from: DateComponents(year: y, month: mo, day: d))
            }
        }

        // Compact pattern: YYYYMMDD (not preceded or followed by another digit)
        let compact = Self.compactDateRegex
        if let m = compact.firstMatch(in: stem, range: NSRange(stem.startIndex..., in: stem)),
           let range = Range(m.range(at: 0), in: stem) {
            let part = String(stem[range])
            if let y = Int(part.prefix(4)),
               let mo = Int(part.dropFirst(4).prefix(2)),
               let d = Int(part.dropFirst(6).prefix(2)),
               y >= 1900, y <= 2100, mo >= 1, mo <= 12, d >= 1, d <= 31 {
                return cal.date(from: DateComponents(year: y, month: mo, day: d))
            }
        }

        return nil
    }

    private static let separatedDateRegex: NSRegularExpression = {
        // Matches YYYY[-_.]MM[-_.]DD where year starts with 19 or 20
        try! NSRegularExpression(pattern: #"(?<!\d)((?:19|20)\d{2})[-_.](0[1-9]|1[0-2])[-_.](0[1-9]|[12]\d|3[01])(?!\d)"#)
    }()

    private static let compactDateRegex: NSRegularExpression = {
        // Matches eight consecutive digits YYYYMMDD not surrounded by other digits
        try! NSRegularExpression(pattern: #"(?<!\d)((?:19|20)\d{2})(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])(?!\d)"#)
    }()

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

    private func secondString(from date: Date) -> String {
        return Self.secondFormatter.string(from: date)
    }

    private static let secondFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

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
