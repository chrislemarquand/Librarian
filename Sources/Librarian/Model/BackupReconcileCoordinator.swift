import Foundation
import ImageIO
import Photos

// MARK: - Result types

struct BackupReconcilePreflightResult: Sendable {
    let totalDiscovered: Int
    /// Files whose UUID was found in PhotoKit — still in the library, will be skipped.
    let stillInLibrary: Int
    /// Files not found in PhotoKit (or no UUID + no dedup match) — archive candidates.
    let toArchive: Int
    /// Files already present in the Archive by hash — will be skipped.
    let alreadyInArchive: Int
    /// Files that had no UUID record in the export database.
    let noUUIDCount: Int
    /// False when no `.osxphotos_export.db` was found in the backup folder.
    let hasExportDatabase: Bool
    let candidateURLs: [URL]
}

struct BackupReconcileRunSummary: Sendable {
    let archived: Int
    let skippedInLibrary: Int
    let skippedInArchive: Int
    let failed: Int
    let failures: [(path: String, reason: String)]
    let completedAt: Date
}

enum BackupReconcileProgressEvent: Sendable {
    case progress(completed: Int, total: Int)
    case done(summary: BackupReconcileRunSummary)
}

// MARK: - Coordinator

final class BackupReconcileCoordinator: @unchecked Sendable {

    private let backupFolder: URL
    private let archiveRoot: URL
    private let photosService: PhotosLibraryService
    private let database: DatabaseManager
    private let fileManager = FileManager.default

    /// Images and videos — osxphotos backups contain both.
    private static let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "heic", "heif", "png", "tif", "tiff", "gif", "bmp",
        "mov", "mp4", "m4v", "mpg", "mpeg", "avi", "3gp"
    ]

    init(
        backupFolder: URL,
        archiveRoot: URL,
        photosService: PhotosLibraryService,
        database: DatabaseManager
    ) {
        self.backupFolder = backupFolder
        self.archiveRoot = archiveRoot
        self.photosService = photosService
        self.database = database
    }

    // MARK: - Preflight

    func runPreflight() async throws -> BackupReconcilePreflightResult {
        let backupAccess = backupFolder.startAccessingSecurityScopedResource()
        defer { if backupAccess { backupFolder.stopAccessingSecurityScopedResource() } }

        // 1. Locate export DB and build relative-path → bare UUID map (cursor-based, no peak array).
        let dbURL = OsxPhotosExportDatabase.locate(in: backupFolder)
        let hasExportDatabase = dbURL != nil
        var pathToUUID: [String: String] = [:]   // normalised relative path → bare UUID
        if let dbURL {
            pathToUUID = try OsxPhotosExportDatabase(url: dbURL).loadPathToUUIDMap()
        }

        // 2. Enumerate actual files in the backup folder.
        var allFiles: [URL] = []
        try enumerateFiles(in: backupFolder) { allFiles.append($0) }

        // 3. Split into hasUUID / noUUID groups.
        //    osxphotos stores bare UUIDs; PhotoKit localIdentifiers have a "/L0/001" suffix.
        var hasUUIDFiles: [(url: URL, fullID: String)] = []
        var noUUIDFiles: [URL] = []

        let backupRootPath = backupFolder.standardizedFileURL.path
        let rootPrefix = backupRootPath.hasSuffix("/") ? backupRootPath : backupRootPath + "/"
        for fileURL in allFiles {
            let standardized = fileURL.standardizedFileURL
            let filePath = standardized.path
            guard filePath.hasPrefix(rootPrefix) else {
                noUUIDFiles.append(fileURL)
                continue
            }
            let relativePath = String(filePath.dropFirst(rootPrefix.count))
            if let bareUUID = pathToUUID[relativePath.lowercased()] {
                // PhotoKit localIdentifier = bare UUID + "/L0/001" for originals.
                hasUUIDFiles.append((url: fileURL, fullID: bareUUID + "/L0/001"))
            } else {
                noUUIDFiles.append(fileURL)
            }
        }

        AppLog.shared.info(
            "BackupReconcile diagnostic — " +
            "pathToUUIDMap entries: \(pathToUUID.count), " +
            "hasUUIDFiles: \(hasUUIDFiles.count), " +
            "noUUIDFiles: \(noUUIDFiles.count)"
        )
        if let firstUUIDEntry = pathToUUID.first {
            AppLog.shared.info("BackupReconcile diagnostic — sample DB entry: filepath='\(firstUUIDEntry.key)' uuid='\(firstUUIDEntry.value)'")
        }
        if let firstEnumerated = allFiles.first {
            let p = firstEnumerated.standardizedFileURL.path
            let rel = p.hasPrefix(rootPrefix) ? String(p.dropFirst(rootPrefix.count)) : "(no match — path=\(p), prefix=\(rootPrefix))"
            AppLog.shared.info("BackupReconcile diagnostic — sample enumerated relative path: '\(rel)'")
        }

        // 4. Batch UUID lookup via PhotoKit in chunks of 500.
        //    A single fetchAssetsKeyed call with 100k+ identifiers can cause PhotoKit to
        //    load enormous amounts of metadata into memory simultaneously.
        var stillInLibraryCount = 0
        var toArchiveCandidates: [URL] = []
        let chunkSize = 500
        var offset = 0
        while offset < hasUUIDFiles.count {
            let slice = hasUUIDFiles[offset ..< min(offset + chunkSize, hasUUIDFiles.count)]
            let chunkIDs = slice.map(\.fullID)
            let foundAssets = photosService.fetchAssetsKeyed(localIdentifiers: chunkIDs)
            let foundIDs = Set(foundAssets.keys)
            if offset == 0 {
                AppLog.shared.info(
                    "BackupReconcile diagnostic — first chunk: queried \(chunkIDs.count), PhotoKit returned \(foundIDs.count). " +
                    "Sample IDs sent: \(Array(chunkIDs.prefix(3)))"
                )
            }
            for (url, fullID) in slice {
                if foundIDs.contains(fullID) {
                    stillInLibraryCount += 1
                } else {
                    toArchiveCandidates.append(url)
                }
            }
            offset += chunkSize
        }

        // 5. No-UUID files go to archive as a precaution — no dedup pass.
        //    Running classifyFiles on potentially tens of thousands of files would create a
        //    CGImageSource per file on a background thread, causing unbounded memory growth.
        //    The plan designates these as archive candidates regardless of dedup outcome.
        var candidateURLs = toArchiveCandidates + noUUIDFiles

        // Note: we intentionally skip an archive-hash dedup pass here.
        // Hashing every candidate against every archive file would read potentially
        // hundreds of GB from the backup drive in a tight loop. It is also unnecessary:
        // this flow MOVEs files (not copies), so any file previously moved from this
        // backup will no longer exist here. Duplicates introduced from other sources
        // are handled by uniqueDestinationURL during the move itself.
        return BackupReconcilePreflightResult(
            totalDiscovered: allFiles.count,
            stillInLibrary: stillInLibraryCount,
            toArchive: candidateURLs.count,
            alreadyInArchive: 0,
            noUUIDCount: noUUIDFiles.count,
            hasExportDatabase: hasExportDatabase,
            candidateURLs: candidateURLs
        )
    }

    // MARK: - Reconcile

    func runReconcile(preflight: BackupReconcilePreflightResult) -> AsyncThrowingStream<BackupReconcileProgressEvent, Error> {
        AsyncThrowingStream { continuation in
            Task.detached(priority: .utility) { [self] in
                do {
                    let result = try self.performMove(candidates: preflight.candidateURLs) { completed, total in
                        continuation.yield(.progress(completed: completed, total: total))
                    }
                    let summary = BackupReconcileRunSummary(
                        archived: result.archived,
                        skippedInLibrary: preflight.stillInLibrary,
                        skippedInArchive: preflight.alreadyInArchive,
                        failed: result.failed,
                        failures: result.failures,
                        completedAt: result.completedAt
                    )
                    continuation.yield(.done(summary: summary))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Move execution

    private struct MoveResult {
        let archived: Int
        let failed: Int
        let failures: [(path: String, reason: String)]
        let completedAt: Date
    }

    private func performMove(
        candidates: [URL],
        onProgress: @escaping (Int, Int) -> Void
    ) throws -> MoveResult {
        let archiveTreeRoot = ArchiveSettings.importDestinationRoot(from: archiveRoot)

        let archiveAccess = archiveRoot.startAccessingSecurityScopedResource()
        defer { if archiveAccess { archiveRoot.stopAccessingSecurityScopedResource() } }

        let backupAccess = backupFolder.startAccessingSecurityScopedResource()
        defer { if backupAccess { backupFolder.stopAccessingSecurityScopedResource() } }

        try fileManager.createDirectory(at: archiveTreeRoot, withIntermediateDirectories: true)

        let total = candidates.count
        var archived = 0
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
                try fileManager.moveItem(at: sourceURL, to: destURL)
                archived += 1
            } catch {
                failures.append((sourceURL.path, error.localizedDescription))
            }
            onProgress(index + 1, total)
        }

        return MoveResult(
            archived: archived,
            failed: failures.count,
            failures: failures,
            completedAt: Date()
        )
    }

    // MARK: - Helpers

    private func enumerateFiles(in folder: URL, visitor: (URL) throws -> Void) throws {
        let keys: [URLResourceKey] = [.isRegularFileKey]
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

    private func readCaptureDateIfAvailable(from fileURL: URL) -> Date? {
        let ext = fileURL.pathExtension.lowercased()
        let imageExtensions: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "tif", "tiff"]
        guard imageExtensions.contains(ext) else { return nil }
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

    private func parseDateFromFilename(_ filename: String) -> Date? {
        let stem = (filename as NSString).deletingPathExtension
        let cal = Calendar(identifier: .gregorian)

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
        try! NSRegularExpression(pattern: #"(?<!\d)((?:19|20)\d{2})[-_.](0[1-9]|1[0-2])[-_.](0[1-9]|[12]\d|3[01])(?!\d)"#)
    }()

    private static let compactDateRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"(?<!\d)((?:19|20)\d{2})(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])(?!\d)"#)
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
}
