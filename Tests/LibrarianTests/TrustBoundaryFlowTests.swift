import Testing
import GRDB
import Foundation
@testable import Librarian

@Test func trustBoundary_archiveDedupeSuppressesExactDuplicateAndLogsEvent() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("librarian-trust-dedupe-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: root) }
    try fm.createDirectory(at: root, withIntermediateDirectories: true)

    let dayFolder = root.appendingPathComponent("Archive/2026/03/24", isDirectory: true)
    try fm.createDirectory(at: dayFolder, withIntermediateDirectories: true)
    let fileA = dayFolder.appendingPathComponent("A.jpg")
    let fileB = dayFolder.appendingPathComponent("B.jpg")
    let payload = Data("same-bytes".utf8)
    try payload.write(to: fileA)
    try payload.write(to: fileB)

    let dbQueue = try makeMigratedDatabaseQueue()
    let database = DatabaseManager(testingDatabaseQueue: dbQueue)
    let service = ArchiveDedupeService(database: database)

    let result = try service.evaluateFiles(
        archiveTreeRoot: root,
        fileURLs: [fileA, fileB],
        ingestSource: "test",
        flow: "trust-boundary-test"
    )

    #expect(result.summary.total == 2)
    #expect(result.summary.kept == 1)
    #expect(result.summary.suppressedDuplicates == 1)

    let keptPaths = Set(
        result.decisions.compactMap { decision -> String? in
            if case .keep = decision.outcome { return decision.relativePath }
            return nil
        }
    )
    #expect(keptPaths.count == 1)

    let suppressed = result.decisions.first {
        if case .suppressDuplicate = $0.outcome { return true }
        return false
    }
    if case .suppressDuplicate(let canonicalRelativePath)? = suppressed?.outcome {
        #expect(keptPaths.contains(canonicalRelativePath))
    } else {
        Issue.record("Expected one suppressed duplicate decision.")
    }

    let eventCount = try database.assetRepository.countArchiveDuplicateEvents(reason: "exact_match")
    #expect(eventCount == 1)
}

@Test func trustBoundary_archiveDedupeRejectsPathOutsideArchiveRoot() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("librarian-trust-root-\(UUID().uuidString)", isDirectory: true)
    let outside = fm.temporaryDirectory.appendingPathComponent("librarian-trust-outside-\(UUID().uuidString).jpg", isDirectory: false)
    defer {
        try? fm.removeItem(at: root)
        try? fm.removeItem(at: outside)
    }

    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: outside)

    let dbQueue = try makeMigratedDatabaseQueue()
    let database = DatabaseManager(testingDatabaseQueue: dbQueue)
    let service = ArchiveDedupeService(database: database)

    do {
        _ = try service.evaluateFiles(
            archiveTreeRoot: root,
            fileURLs: [outside],
            ingestSource: "test",
            flow: "trust-boundary-test"
        )
        Issue.record("Expected path-outside-root to fail.")
    } catch {
        let message = (error as NSError).localizedDescription
        #expect(message.contains("Could not compute relative path"))
    }
}

@Test func trustBoundary_osxPhotosRunnerInjectsBundledExiftoolEnvironment() throws {
    let fm = FileManager.default
    let tempRoot = fm.temporaryDirectory.appendingPathComponent("librarian-trust-osxphotos-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: tempRoot) }
    try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)

    let fakeOsxPhotos = tempRoot.appendingPathComponent("osxphotos", isDirectory: false)
    let fakeExifTool = tempRoot.appendingPathComponent("bin/exiftool", isDirectory: false)
    let exifLib = tempRoot.appendingPathComponent("bin/lib", isDirectory: true)
    try fm.createDirectory(at: exifLib, withIntermediateDirectories: true)
    try Data().write(to: fakeOsxPhotos)
    try Data().write(to: fakeExifTool)

    var capturedEnvironment: [String: String] = [:]
    let runner = OsxPhotosRunner(
        resolveBundledOsxPhotosExecutableOverride: { fakeOsxPhotos },
        resolveBundledExifToolExecutableOverride: { fakeExifTool },
        runProcessOverride: { _, _, environment, _ in
            capturedEnvironment = environment ?? [:]
            return (0, "")
        }
    )

    let result = runner.run(arguments: ["query", "--json"], includeExifToolEnvironment: true)
    #expect(result.exitCode == 0)
    #expect(result.usedExternalFallback == false)
    #expect(capturedEnvironment["EXIFTOOL_PATH"] == fakeExifTool.path)

    let perl5Lib = capturedEnvironment["PERL5LIB"] ?? ""
    #expect(perl5Lib.contains(exifLib.path))
}
