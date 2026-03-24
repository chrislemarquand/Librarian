import Testing
import Foundation
@testable import Librarian

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

@Test func archiveControlConfigStartsUnboundByDefault() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("librarian-bind-unbound-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: root) }

    #expect(ArchiveSettings.ensureControlFolder(at: root))
    let config = ArchiveSettings.controlConfig(for: root)
    #expect(config?.photoLibraryBinding == nil)
}

@Test func archiveControlConfigPersistsBindingDetails() throws {
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

    let config = ArchiveSettings.controlConfig(for: root)
    #expect(config?.photoLibraryBinding?.libraryFingerprint == "sha256:bound")
    #expect(config?.photoLibraryBinding?.libraryPathHint == "/tmp/Bound.photoslibrary")
    #expect(config?.photoLibraryBinding?.bindingMode == .strict)
}

@Test func archiveControlConfigPersistsLastSeenMatchAt() throws {
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

    #expect(
        ArchiveSettings.updateControlConfig(at: root) { config in
            config.photoLibraryBinding?.lastSeenMatchAt = now
        }
    )
    let config = ArchiveSettings.controlConfig(for: root)
    #expect(config?.photoLibraryBinding?.lastSeenMatchAt == now)
}

@Test func archiveControlConfigPersistsBindingPathHint() throws {
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

    #expect(
        ArchiveSettings.updateControlConfig(at: root) { config in
            config.photoLibraryBinding?.libraryPathHint = "/tmp/Current.photoslibrary"
        }
    )
    let config = ArchiveSettings.controlConfig(for: root)
    #expect(config?.photoLibraryBinding?.libraryPathHint == "/tmp/Current.photoslibrary")
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
    withArchiveDefaultsBackup {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: ArchiveSettings.bookmarkKey)
        defaults.removeObject(forKey: ArchiveSettings.archiveIDKey)

        let resolution = ArchiveSettings.currentArchiveRootResolution()
        #expect(resolution.rootURL == nil)
        #expect(resolution.availability == .notConfigured)
    }
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

    withArchiveDefaultsBackup {
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
}
