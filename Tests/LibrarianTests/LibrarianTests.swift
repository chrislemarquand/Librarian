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

@Test func archiveControlConfigMigrationUpgradesSchemaVersionToV2() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("librarian-migration-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: root) }

    #expect(ArchiveSettings.ensureControlFolder(at: root))
    let paths = ArchiveSettings.ArchiveControlPaths(rootURL: root)
    let archiveID = "TEST-ARCHIVE-ID-123"
    let v1JSON = """
    {
      "schemaVersion" : 1,
      "archiveID" : "\(archiveID)",
      "createdAt" : "2026-03-21T00:00:00Z",
      "createdByVersion" : "1.0",
      "layoutMode" : "YYYY/MM/DD",
      "paths" : {
        "reports" : "reports",
        "thumbnails" : "thumbnails"
      }
    }
    """
    try v1JSON.data(using: .utf8)?.write(to: paths.configURL, options: .atomic)

    #expect(ArchiveSettings.ensureControlFolder(at: root))
    let migrated = ArchiveSettings.controlConfig(for: root)
    #expect(migrated != nil)
    #expect(migrated?.schemaVersion == ArchiveSettings.configSchemaVersion)
    #expect(migrated?.archiveID == archiveID)
    #expect(migrated?.photoLibraryBinding == nil)
}

@Test func archiveLibraryBindingEvaluatorReturnsUnboundWhenNoBinding() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("librarian-bind-unbound-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: root) }

    #expect(ArchiveSettings.ensureControlFolder(at: root))
    let evaluation = ArchiveLibraryBindingEvaluator.evaluate(
        rootURL: root,
        currentFingerprintProvider: {
            PhotoLibraryFingerprint(
                fingerprint: "sha256:current",
                source: "test",
                pathHint: "/tmp/Test.photoslibrary"
            )
        }
    )
    #expect(evaluation.state == .unbound)
}

@Test func archiveLibraryBindingEvaluatorReturnsMismatchWhenFingerprintDiffers() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("librarian-bind-mismatch-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: root) }

    #expect(ArchiveSettings.ensureControlFolder(at: root))
    let boundAt = Date(timeIntervalSince1970: 1_700_000_000)
    #expect(
        ArchiveSettings.updateControlConfig(at: root) { config in
            config.photoLibraryBinding = .init(
                libraryFingerprint: "sha256:bound",
                libraryIDSource: "test",
                libraryPathHint: "/tmp/Bound.photoslibrary",
                boundAt: boundAt,
                bindingMode: .strict,
                lastSeenMatchAt: nil
            )
        }
    )

    let evaluation = ArchiveLibraryBindingEvaluator.evaluate(
        rootURL: root,
        currentFingerprintProvider: {
            PhotoLibraryFingerprint(
                fingerprint: "sha256:current",
                source: "test",
                pathHint: "/tmp/Current.photoslibrary"
            )
        }
    )
    #expect(evaluation.state == .mismatch)
}

@Test func archiveLibraryBindingEvaluatorPersistsLastSeenMatchAtOnMatch() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("librarian-bind-match-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: root) }

    #expect(ArchiveSettings.ensureControlFolder(at: root))
    let now = Date(timeIntervalSince1970: 1_700_000_123)
    #expect(
        ArchiveSettings.updateControlConfig(at: root) { config in
            config.photoLibraryBinding = .init(
                libraryFingerprint: "sha256:same",
                libraryIDSource: "test",
                libraryPathHint: "/tmp/Same.photoslibrary",
                boundAt: now.addingTimeInterval(-3600),
                bindingMode: .strict,
                lastSeenMatchAt: nil
            )
        }
    )

    let evaluation = ArchiveLibraryBindingEvaluator.evaluate(
        rootURL: root,
        currentFingerprintProvider: {
            PhotoLibraryFingerprint(
                fingerprint: "sha256:same",
                source: "test",
                pathHint: "/tmp/Same.photoslibrary"
            )
        },
        persistMatchTimestamp: true,
        now: now
    )
    #expect(evaluation.state == .match)
    #expect(evaluation.didPersistMatchTimestamp)
    let config = ArchiveSettings.controlConfig(for: root)
    #expect(config?.photoLibraryBinding?.lastSeenMatchAt == now)
}

@Test func archiveLibraryBindingEvaluatorReturnsUnknownWhenFingerprintUnavailable() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("librarian-bind-unknown-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: root) }

    #expect(ArchiveSettings.ensureControlFolder(at: root))
    #expect(
        ArchiveSettings.updateControlConfig(at: root) { config in
            config.photoLibraryBinding = .init(
                libraryFingerprint: "sha256:bound",
                libraryIDSource: "test",
                libraryPathHint: "/tmp/Bound.photoslibrary",
                boundAt: Date(timeIntervalSince1970: 1_700_000_000),
                bindingMode: .strict,
                lastSeenMatchAt: nil
            )
        }
    )

    let evaluation = ArchiveLibraryBindingEvaluator.evaluate(
        rootURL: root,
        currentFingerprintProvider: {
            throw PhotoLibraryFingerprintError.noLibraryURLFound
        }
    )
    #expect(evaluation.state == .unknown)
    #expect(evaluation.reason == "current_library_fingerprint_unavailable")
}

@Test @MainActor func archiveImportFlowIsBlockedWhenLibraryBindingRequiresResolution() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("librarian-gate-import-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: root) }

    let defaults = UserDefaults.standard
    let bookmarkBackup = defaults.object(forKey: ArchiveSettings.bookmarkKey)
    let archiveIDBackup = defaults.object(forKey: ArchiveSettings.archiveIDKey)
    defer {
        if let bookmarkBackup {
            defaults.set(bookmarkBackup, forKey: ArchiveSettings.bookmarkKey)
        } else {
            defaults.removeObject(forKey: ArchiveSettings.bookmarkKey)
        }
        if let archiveIDBackup {
            defaults.set(archiveIDBackup, forKey: ArchiveSettings.archiveIDKey)
        } else {
            defaults.removeObject(forKey: ArchiveSettings.archiveIDKey)
        }
    }

    #expect(ArchiveSettings.ensureControlFolder(at: root))
    #expect(ArchiveSettings.persistArchiveRootURL(root))
    #expect(
        ArchiveSettings.updateControlConfig(at: root) { config in
            config.photoLibraryBinding = .init(
                libraryFingerprint: "sha256:definitely-not-the-current-library-fingerprint",
                libraryIDSource: "test",
                libraryPathHint: "/tmp/Bound.photoslibrary",
                boundAt: Date(timeIntervalSince1970: 1_700_000_000),
                bindingMode: .strict,
                lastSeenMatchAt: nil
            )
        }
    )

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
        Issue.record("Expected runArchiveImport to fail when binding requires resolution")
    } catch {
        let nsError = error as NSError
        let message = (nsError.userInfo[NSLocalizedDescriptionKey] as? String) ?? ""
        #expect(message.contains("Resolve") || message.contains("linked") || message.contains("verify"))
    }
}

@Test @MainActor func archivePathBEquivalentWriteFlowIsBlockedWhenLibraryBindingRequiresResolution() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("librarian-gate-export-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: root) }

    #expect(ArchiveSettings.ensureControlFolder(at: root))
    #expect(
        ArchiveSettings.updateControlConfig(at: root) { config in
            config.photoLibraryBinding = .init(
                libraryFingerprint: "sha256:definitely-not-the-current-library-fingerprint",
                libraryIDSource: "test",
                libraryPathHint: "/tmp/Bound.photoslibrary",
                boundAt: Date(timeIntervalSince1970: 1_700_000_000),
                bindingMode: .strict,
                lastSeenMatchAt: nil
            )
        }
    )

    let model = AppModel()
    do {
        _ = try await model.sendArchiveCandidatesWithOutcome(
            to: root,
            options: .default,
            localIdentifiers: []
        )
        Issue.record("Expected sendArchiveCandidatesWithOutcome to fail when binding requires resolution")
    } catch {
        let nsError = error as NSError
        let message = (nsError.userInfo[NSLocalizedDescriptionKey] as? String) ?? ""
        #expect(message.contains("Resolve") || message.contains("linked") || message.contains("verify"))
    }
}
