import Testing
import Foundation
@testable import Librarian

@Test func recoverStaleArchiveExportsMarksExportingAsFailed() throws {
    let dbQueue = try makeMigratedDatabaseQueue()

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
    let dbQueue = try makeMigratedDatabaseQueue()
    let repository = AssetRepository(db: dbQueue)
    let recovered = try repository.recoverStaleArchiveExports(errorMessage: "unused")
    #expect(recovered == 0)
}

@Test func archiveMovePreflightBlocksDestinationInsideSource() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("librarian-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: root) }

    let sourceRoot = root.appendingPathComponent("SourceRoot", isDirectory: true)
    #expect(ArchiveSettings.ensureControlFolder(at: sourceRoot))
    let sourceArchive = ArchiveSettings.archiveTreeRootURL(from: sourceRoot)
    let destinationInside = sourceArchive.appendingPathComponent("NestedDestinationRoot", isDirectory: true)

    do {
        try ArchiveSettingsViewController.test_preflightArchiveMove(sourceRoot: sourceRoot, destinationRoot: destinationInside)
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

    let source = root.appendingPathComponent("LibrarianRoot", isDirectory: true)
    let destinationParent = root

    #expect(ArchiveSettings.ensureControlFolder(at: source))
    let sourceArchive = ArchiveSettings.archiveTreeRootURL(from: source)
    try Data("x".utf8).write(to: sourceArchive.appendingPathComponent("photo1.jpg"))

    try ArchiveSettingsViewController.test_preflightArchiveMove(sourceRoot: source, destinationRoot: destinationParent)
}

@Test func archiveMoveCopyGuardsAgainstRecursiveDestinationTraversal() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("librarian-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: root) }

    let source = root.appendingPathComponent("SourceRoot", isDirectory: true)
    #expect(ArchiveSettings.ensureControlFolder(at: source))
    let sourceArchive = ArchiveSettings.archiveTreeRootURL(from: source)
    let destinationInside = sourceArchive.appendingPathComponent("Archive", isDirectory: true)

    try Data("x".utf8).write(to: sourceArchive.appendingPathComponent("photo1.jpg"))

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

@Test func archiveSendNotDeletedIdentifiersReconcilesExportAndDeleteSets() {
    let exported = ["a", "b", "c", "c"]
    let deleted = ["b"]
    let notDeleted = Set(
        AppModel.notDeletedIdentifiers(
            exportedIdentifiers: exported,
            deletedIdentifiers: deleted
        )
    )
    #expect(notDeleted == Set(["a", "c"]))
}

@Test func archiveSendClassificationCoversMixedOutcomeStates() {
    #expect(AppModel.classifyArchiveSendOutcome(exportedCount: 0, failedCount: 4, notDeletedCount: 0) == .noExports)
    #expect(AppModel.classifyArchiveSendOutcome(exportedCount: 4, failedCount: 0, notDeletedCount: 1) == .deleteMismatch)
    #expect(AppModel.classifyArchiveSendOutcome(exportedCount: 4, failedCount: 2, notDeletedCount: 0) == .partialFailures)
    #expect(AppModel.classifyArchiveSendOutcome(exportedCount: 4, failedCount: 0, notDeletedCount: 0) == .success)
}

@Test func exportPreflightEstimateUsesKnownAndFallbackSizes() {
    let stats = AssetRepository.FileSizeStats(
        knownBytes: 3_000_000,
        unknownCount: 2
    )
    let estimate = ArchiveOperationPreflightService.estimateExportWriteBytes(fileSizeStats: stats)
    #expect(estimate == 3_000_000 + (2 * 8 * 1024 * 1024))
}

