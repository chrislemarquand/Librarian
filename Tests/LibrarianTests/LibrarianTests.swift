import Testing
import GRDB
import Foundation
@testable import Librarian

@Test func recoverStaleArchiveExportsMarksExportingAsFailed() throws {
    let dbQueue = try DatabaseQueue()
    var migrator = DatabaseMigrator()
    LibrarianMigrations.register(in: &migrator)
    try migrator.migrate(dbQueue)

    try dbQueue.write { db in
        try db.execute(
            sql: """
                INSERT INTO asset (localIdentifier, creationDate, mediaType)
                VALUES (?, CURRENT_TIMESTAMP, 1), (?, CURRENT_TIMESTAMP, 1), (?, CURRENT_TIMESTAMP, 1)
            """,
            arguments: ["asset-exporting-1", "asset-exporting-2", "asset-pending"]
        )
        try db.execute(
            sql: """
                INSERT INTO archive_candidate (assetLocalIdentifier, status, queuedAt)
                VALUES (?, ?, CURRENT_TIMESTAMP), (?, ?, CURRENT_TIMESTAMP), (?, ?, CURRENT_TIMESTAMP)
            """,
            arguments: [
                "asset-exporting-1", ArchiveCandidateStatus.exporting.rawValue,
                "asset-exporting-2", ArchiveCandidateStatus.exporting.rawValue,
                "asset-pending", ArchiveCandidateStatus.pending.rawValue,
            ]
        )
    }

    let repository = AssetRepository(db: dbQueue)
    let recovered = try repository.recoverStaleArchiveExports(errorMessage: "stale launch recovery")

    #expect(recovered == 2)

    let exporting = try repository.fetchArchiveCandidateIdentifiers(statuses: [.exporting])
    #expect(exporting.isEmpty)

    let failed = try Set(repository.fetchArchiveCandidateIdentifiers(statuses: [.failed]))
    #expect(failed == Set(["asset-exporting-1", "asset-exporting-2"]))

    let pending = try repository.fetchArchiveCandidateIdentifiers(statuses: [.pending])
    #expect(pending == ["asset-pending"])

    let failedInfo = try repository.fetchArchiveCandidateInfo(localIdentifier: "asset-exporting-1")
    #expect(failedInfo?.lastError == "stale launch recovery")
}

@Test func recoverStaleArchiveExportsNoOpWhenNoExportingRows() throws {
    let dbQueue = try DatabaseQueue()
    var migrator = DatabaseMigrator()
    LibrarianMigrations.register(in: &migrator)
    try migrator.migrate(dbQueue)

    let repository = AssetRepository(db: dbQueue)
    let recovered = try repository.recoverStaleArchiveExports(errorMessage: "unused")
    #expect(recovered == 0)
}

@Test func archiveMovePreflightBlocksDestinationInsideSource() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("librarian-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: root) }

    let source = root.appendingPathComponent("Archive", isDirectory: true)
    let destinationInside = source.appendingPathComponent("NestedDestination", isDirectory: true)
    try fm.createDirectory(at: source, withIntermediateDirectories: true)
    try fm.createDirectory(at: source.appendingPathComponent(".librarian", isDirectory: true), withIntermediateDirectories: true)

    do {
        try ArchiveSettingsViewController.test_preflightArchiveMove(sourceRoot: source, destinationRoot: destinationInside)
        Issue.record("Expected preflight to throw for destination-inside-source")
    } catch {
        let nsError = error as NSError
        #expect(nsError.code == 11)
    }
}

@Test func archiveMovePreflightAllowsParentDestination() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("librarian-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: root) }

    let source = root.appendingPathComponent("Librarian", isDirectory: true)
    let destinationParent = root

    try fm.createDirectory(at: source, withIntermediateDirectories: true)
    #expect(ArchiveSettings.ensureControlFolder(at: source))
    try Data("x".utf8).write(to: source.appendingPathComponent("photo1.jpg"))

    try ArchiveSettingsViewController.test_preflightArchiveMove(sourceRoot: source, destinationRoot: destinationParent)
}

@Test func archiveMoveCopyGuardsAgainstRecursiveDestinationTraversal() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("librarian-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: root) }

    let source = root.appendingPathComponent("Archive", isDirectory: true)
    let destinationInside = source.appendingPathComponent("Archive", isDirectory: true)

    try fm.createDirectory(at: source, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: source.appendingPathComponent("photo1.jpg"))

    do {
        try ArchiveSettingsViewController.test_copyAndVerifyArchiveMove(
            sourceRoot: source,
            destinationRoot: destinationInside,
            expectedFileCount: 1
        )
        Issue.record("Expected copy to throw for destination-inside-source")
    } catch {
        let nsError = error as NSError
        #expect(nsError.code == 11)
    }
}
