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

@Test func whatsAppFilenameDetectionMatchesLegacyPrefixes() {
    #expect(AssetIndexer.isWhatsAppFilename("WhatsApp Image 2026-03-22 at 20.00.00.jpg"))
    #expect(AssetIndexer.isWhatsAppFilename("WhatsApp Video 2026-03-22 at 20.00.00.mp4"))
    #expect(AssetIndexer.isWhatsAppFilename("IMG_0001_from_whatsapp_export.jpg"))
}

@Test func whatsAppFilenameDetectionMatchesUUIDStyleBasenames() {
    let afterHDRollout = Date(timeIntervalSince1970: 1_700_000_000) // Nov 2023
    #expect(
        AssetIndexer.isWhatsAppFilename(
            "054742c5-4789-454d-b223-cc6a3ba2f578.jpg",
            creationDate: afterHDRollout,
            pixelWidth: 3024,
            pixelHeight: 4032
        )
    )
    #expect(
        AssetIndexer.isWhatsAppFilename(
            "3b159952-8a6a-4fcc-a420-712584139f72 (1).jpg",
            creationDate: afterHDRollout,
            pixelWidth: 4032,
            pixelHeight: 3024
        )
    )
    #expect(
        AssetIndexer.isWhatsAppFilename(
            "A656B73D-558C-420E-81BB-890C041BBF66.HEIC",
            creationDate: afterHDRollout,
            pixelWidth: 4096,
            pixelHeight: 2692
        )
    )
}

@Test func whatsAppFilenameDetectionRejectsUUIDAboveEraResolutionCaps() {
    let beforeHDRollout = Date(timeIntervalSince1970: 1_650_000_000) // Apr 2022
    #expect(
        !AssetIndexer.isWhatsAppFilename(
            "054742c5-4789-454d-b223-cc6a3ba2f578.jpg",
            creationDate: beforeHDRollout,
            pixelWidth: 3024,
            pixelHeight: 4032
        )
    )
    let afterHDRollout = Date(timeIntervalSince1970: 1_700_000_000) // Nov 2023
    #expect(
        !AssetIndexer.isWhatsAppFilename(
            "054742c5-4789-454d-b223-cc6a3ba2f578.jpg",
            creationDate: afterHDRollout,
            pixelWidth: 6000,
            pixelHeight: 4000
        )
    )
}

@Test func whatsAppFilenameDetectionRejectsNonWhatsAppLikeNames() {
    #expect(!AssetIndexer.isWhatsAppFilename("IMG_1234.JPG"))
    #expect(!AssetIndexer.isWhatsAppFilename("photo-from-camera-roll.jpg"))
    #expect(!AssetIndexer.isWhatsAppFilename("3b159952-8a6a-4fcc-a420-712584139f72.txt"))
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

@Test func resolveArchiveRootPrefersParentWhenArchiveFolderIsSelected() throws {
    let fm = FileManager.default
    let parent = fm.temporaryDirectory.appendingPathComponent("librarian-resolve-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: parent) }

    #expect(ArchiveSettings.ensureControlFolder(at: parent))
    let archiveFolder = ArchiveSettings.archiveTreeRootURL(from: parent)
    let resolved = ArchiveSettings.resolveArchiveRoot(fromUserSelection: archiveFolder)
    #expect(resolved?.standardizedFileURL == parent.standardizedFileURL)
}

@Test func archiveRootResolutionIsNotConfiguredWithoutBookmark() {
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

    defaults.removeObject(forKey: ArchiveSettings.bookmarkKey)
    defaults.removeObject(forKey: ArchiveSettings.archiveIDKey)

    let resolution = ArchiveSettings.currentArchiveRootResolution()
    #expect(resolution.rootURL == nil)
    #expect(resolution.availability == .notConfigured)
}

@Test func archiveRootResolutionMarksMissingArchiveFolderAsUnavailable() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("librarian-resolution-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: root) }

    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    let resolution = ArchiveSettings.archiveRootResolution(for: root)
    #expect(resolution.rootURL?.standardizedFileURL == root.standardizedFileURL)
    #expect(resolution.availability == .unavailable)
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

@Test func windowSubtitlePriorityPrefersActiveOperationsBeforeStatus() {
    let subtitle = LibrarianWindowSubtitlePriority.compute(
        isSendingArchive: true,
        isImportingArchive: true,
        importStatusText: "Importing 2 / 10…",
        isIndexing: true,
        indexingStatusText: "Running (4 / 12)",
        isAnalysing: true,
        analysisStatusText: "Scanning…",
        archiveRootAvailability: .unavailable,
        archiveBindingState: .mismatch,
        statusMessage: "Set Aside: 3 photo(s)."
    )
    #expect(subtitle == "Importing 2 / 10…")
}

@Test func windowSubtitlePriorityFallsBackToArchiveAndStatusStates() {
    let archiveUnavailable = LibrarianWindowSubtitlePriority.compute(
        isSendingArchive: false,
        isImportingArchive: false,
        importStatusText: "",
        isIndexing: false,
        indexingStatusText: "Idle",
        isAnalysing: false,
        analysisStatusText: "",
        archiveRootAvailability: .unavailable,
        archiveBindingState: .mismatch,
        statusMessage: "Set Aside: 3 photo(s)."
    )
    #expect(archiveUnavailable == ArchiveSettings.ArchiveRootAvailability.unavailable.userVisibleDescription)

    let bindingMismatch = LibrarianWindowSubtitlePriority.compute(
        isSendingArchive: false,
        isImportingArchive: false,
        importStatusText: "",
        isIndexing: false,
        indexingStatusText: "Idle",
        isAnalysing: false,
        analysisStatusText: "",
        archiveRootAvailability: .available,
        archiveBindingState: .mismatch,
        statusMessage: "Set Aside: 3 photo(s)."
    )
    #expect(bindingMismatch == "Archive linked to a different photo library.")

    let statusMessage = LibrarianWindowSubtitlePriority.compute(
        isSendingArchive: false,
        isImportingArchive: false,
        importStatusText: "",
        isIndexing: false,
        indexingStatusText: "Idle",
        isAnalysing: false,
        analysisStatusText: "",
        archiveRootAvailability: .available,
        archiveBindingState: .match,
        statusMessage: "Set Aside: 3 photo(s)."
    )
    #expect(statusMessage == "Set Aside: 3 photo(s).")
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

@Test func resolveArchiveRootWithExpectedArchiveIDFlagsMismatch() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("librarian-resolve-expected-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: root) }

    let archiveA = root.appendingPathComponent("ArchiveA", isDirectory: true)
    let archiveB = root.appendingPathComponent("ArchiveB", isDirectory: true)
    #expect(ArchiveSettings.ensureControlFolder(at: archiveA))
    #expect(ArchiveSettings.ensureControlFolder(at: archiveB))

    guard let expectedArchiveID = ArchiveSettings.archiveID(for: archiveA) else {
        Issue.record("Expected archive ID for archiveA")
        return
    }

    let resolution = ArchiveSettings.resolveArchiveRoot(
        fromUserSelection: ArchiveSettings.archiveTreeRootURL(from: archiveB),
        expectedArchiveID: expectedArchiveID
    )

    switch resolution {
    case .archiveIDMismatch(let rootURL, let expected, let selected):
        #expect(rootURL.standardizedFileURL == archiveB.standardizedFileURL)
        #expect(expected == expectedArchiveID)
        #expect(selected == ArchiveSettings.archiveID(for: archiveB))
    default:
        Issue.record("Expected archiveIDMismatch resolution")
    }
}

@Test func resolveArchiveRootWithExpectedArchiveIDAcceptsMatch() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("librarian-resolve-expected-match-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: root) }

    #expect(ArchiveSettings.ensureControlFolder(at: root))
    guard let expectedArchiveID = ArchiveSettings.archiveID(for: root) else {
        Issue.record("Expected archive ID for root")
        return
    }

    let resolution = ArchiveSettings.resolveArchiveRoot(
        fromUserSelection: ArchiveSettings.archiveTreeRootURL(from: root),
        expectedArchiveID: expectedArchiveID
    )

    switch resolution {
    case .resolved(let rootURL, let archiveID):
        #expect(rootURL.standardizedFileURL == root.standardizedFileURL)
        #expect(archiveID == expectedArchiveID)
    default:
        Issue.record("Expected resolved result")
    }
}

@Test @MainActor func updateArchiveRootRefreshesModelStateForRelink() throws {
    let fm = FileManager.default
    let parent = fm.temporaryDirectory.appendingPathComponent("librarian-relink-sync-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: parent) }

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

    let rootA = parent.appendingPathComponent("RootA", isDirectory: true)
    let rootB = parent.appendingPathComponent("RootB", isDirectory: true)
    #expect(ArchiveSettings.ensureControlFolder(at: rootA))
    #expect(ArchiveSettings.ensureControlFolder(at: rootB))
    #expect(ArchiveSettings.persistArchiveRootURL(rootA))

    let model = AppModel()

    #expect(model.updateArchiveRoot(rootB))
    #expect(model.archiveRootURL?.standardizedFileURL == rootB.standardizedFileURL)
    #expect(model.archiveRootAvailability == .available)
}
