import Testing
import Foundation
@testable import Librarian

@Test func importPartitionAfterExactDedupeSkipsOnlyExactMatches() {
    let fileA = URL(fileURLWithPath: "/tmp/import-a.jpg")
    let fileB = URL(fileURLWithPath: "/tmp/import-b.jpg")
    let fileC = URL(fileURLWithPath: "/tmp/import-c.jpg")

    let partition = ArchiveImportCoordinator.partitionAfterExactDedupe(
        deduplicatedFiles: [fileA, fileB, fileC],
        results: [
            ArchiveExactDedupeResult(fileURL: fileA, outcome: .exactMatch(photoLibraryLocalIdentifier: "ph://1"), candidateCount: 3),
            ArchiveExactDedupeResult(fileURL: fileB, outcome: .noMatch, candidateCount: 3),
            ArchiveExactDedupeResult(fileURL: fileC, outcome: .indeterminate(reason: "unavailable"), candidateCount: 3),
        ]
    )

    #expect(partition.existsInPhotoKit == 1)
    #expect(partition.candidateURLs == [fileB, fileC])
}

@Test func pathBDuplicateQuarantinePreservesRelativeSubtree() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("librarian-pathb-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: root) }

    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root
        .appendingPathComponent("Incoming", isDirectory: true)
        .appendingPathComponent("CameraRoll", isDirectory: true)
        .appendingPathComponent("2024", isDirectory: true)
    try fm.createDirectory(at: source, withIntermediateDirectories: true)
    let duplicate = source.appendingPathComponent("IMG_0001.jpg")
    try Data("x".utf8).write(to: duplicate)

    let summary = try ArchiveImportSession.test_executePathBPlan(
        archiveTreeRoot: root,
        exactDuplicates: [duplicate],
        accepted: []
    )

    let quarantined = root
        .appendingPathComponent("Already in Photo Library", isDirectory: true)
        .appendingPathComponent("Incoming/CameraRoll/2024/IMG_0001.jpg")
    #expect(fm.fileExists(atPath: quarantined.path))
    #expect(!fm.fileExists(atPath: duplicate.path))
    #expect(summary.skippedExistsInPhotoKit == 1)
}

@Test @MainActor func archiveImportFlowFailsWhenArchiveIsNotConfigured() async {
    await withArchiveDefaultsBackupAsync {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: ArchiveSettings.bookmarkKey)
        defaults.removeObject(forKey: ArchiveSettings.archiveIDKey)

        let model = AppModel()
        let preflight = ArchiveImportPreflightResult(
            totalDiscovered: 0,
            duplicatesInSource: 0,
            existsInPhotoKit: 0,
            toImport: 0,
            candidateURLs: []
        )

        do {
            _ = try await model.runArchiveImport(sourceFolders: [], preflight: preflight)
            Issue.record("Expected runArchiveImport to fail when Archive is not configured")
        } catch {
            let nsError = error as NSError
            let message = (nsError.userInfo[NSLocalizedDescriptionKey] as? String) ?? ""
            #expect(message.contains("No Archive destination is configured"))
        }
    }
}

@Test @MainActor func sendArchiveCandidatesReturnsEmptyOutcomeWhenNoCandidates() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("librarian-gate-export-empty-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: root) }

    #expect(ArchiveSettings.ensureControlFolder(at: root))

    let model = AppModel()
    try model.database.open()
    let outcome = try await model.sendArchiveCandidatesWithOutcome(
        to: root,
        options: .default,
        localIdentifiers: []
    )
    #expect(outcome.exportedCount == 0)
    #expect(outcome.failedCount == 0)
    #expect(outcome.notDeletedCount == 0)
}
