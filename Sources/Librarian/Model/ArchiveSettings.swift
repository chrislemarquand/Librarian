import Foundation

enum ArchiveSettings {
    struct ArchiveRootResolution: Equatable {
        let rootURL: URL?
        let availability: ArchiveRootAvailability

        var isAvailable: Bool { availability == .available }
    }

    enum ArchiveRootAvailability: Equatable {
        case notConfigured
        case available
        case unavailable
        case readOnly
        case permissionDenied

        var userVisibleDescription: String {
            switch self {
            case .notConfigured:
                return "No Archive destination is configured."
            case .available:
                return "Archive destination is available."
            case .unavailable:
                return "The Archive destination is currently unavailable. It may be offline or disconnected."
            case .readOnly:
                return "The Archive destination is read-only."
            case .permissionDenied:
                return "Librarian does not currently have permission to access the Archive destination."
            }
        }
    }

    // MARK: - Keys

    static let bookmarkKey       = "com.librarian.app.archiveRootBookmark"
    static let archiveIDKey      = "com.librarian.app.archiveID"
    static let archiveFolderName = "Archive"
    static let controlFolderName = ".librarian"
    static let configFileName    = "archive.json"
    static let configSchemaVersion = 2

    struct ArchiveControlPaths {
        /// The user-chosen root (e.g. `Testing/`). The archive subfolder lives inside this.
        let rootURL: URL

        /// The designated archive folder (`Testing/Archive/`). This is where the red icon
        /// is applied, where `.librarian/` lives, and where file content is written.
        var archiveFolderURL: URL {
            rootURL.appendingPathComponent(ArchiveSettings.archiveFolderName, isDirectory: true)
        }

        var controlRootURL: URL {
            archiveFolderURL.appendingPathComponent(ArchiveSettings.controlFolderName, isDirectory: true)
        }

        var configURL: URL {
            controlRootURL.appendingPathComponent(ArchiveSettings.configFileName, isDirectory: false)
        }

        var thumbnailsURL: URL {
            controlRootURL.appendingPathComponent("thumbnails", isDirectory: true)
        }

        var reportsURL: URL {
            controlRootURL.appendingPathComponent("reports", isDirectory: true)
        }
    }

    struct ArchiveControlConfig: Codable {
        var schemaVersion: Int
        var archiveID: String
        var createdAt: Date
        var createdByVersion: String
        var layoutMode: String
        var paths: Paths
        var photoLibraryBinding: PhotoLibraryBinding?

        struct Paths: Codable {
            var thumbnails: String
            var reports: String
        }

        struct PhotoLibraryBinding: Codable, Equatable {
            enum BindingMode: String, Codable {
                case strict
                case advisory
            }

            var libraryFingerprint: String
            var libraryIDSource: String
            var libraryPathHint: String?
            var boundAt: Date
            var bindingMode: BindingMode
            var lastSeenMatchAt: Date?
        }
    }

    enum ArchiveRootSelectionResolution: Equatable {
        case unresolved
        case resolved(rootURL: URL, archiveID: String)
        case archiveIDMismatch(rootURL: URL, expectedArchiveID: String, selectedArchiveID: String)
    }

    static func restoreArchiveRootURL() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else {
            return nil
        }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else {
            return nil
        }
        let resolved = resolveArchiveRoot(fromUserSelection: url) ?? url
        if stale || resolved.standardizedFileURL != url.standardizedFileURL {
            _ = persistArchiveRootURL(resolved)
        }
        return resolved
    }

    @discardableResult
    static func persistArchiveRootURL(_ url: URL) -> Bool {
        let normalizedRoot = resolveArchiveRoot(fromUserSelection: url) ?? url.standardizedFileURL
        guard ensureControlFolder(at: normalizedRoot) else { return false }
        let newArchiveID = archiveID(for: normalizedRoot)
        let previousArchiveID = UserDefaults.standard.string(forKey: archiveIDKey)
        guard let bookmark = try? normalizedRoot.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else {
            AppLog.shared.error("Failed to save archive root bookmark")
            return false
        }
        UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
        if let newArchiveID {
            UserDefaults.standard.set(newArchiveID, forKey: archiveIDKey)
            if let previousArchiveID {
                if previousArchiveID == newArchiveID {
                    AppLog.shared.info("Archive root relinked to existing archive id \(newArchiveID)")
                } else {
                    AppLog.shared.info("Archive root switched from archive id \(previousArchiveID) to \(newArchiveID)")
                }
            } else {
                AppLog.shared.info("Archive root linked to archive id \(newArchiveID)")
            }
        }
        AppLog.shared.info("Archive root set to: \(normalizedRoot.path)")
        return true
    }

    @discardableResult
    static func ensureControlFolder(at rootURL: URL) -> Bool {
        let didAccess = rootURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                rootURL.stopAccessingSecurityScopedResource()
            }
        }

        let fileManager = FileManager.default
        let paths = ArchiveControlPaths(rootURL: rootURL)
        do {
            try fileManager.createDirectory(at: paths.archiveFolderURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: paths.controlRootURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: paths.thumbnailsURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: paths.reportsURL, withIntermediateDirectories: true)
            if !fileManager.fileExists(atPath: paths.configURL.path) {
                try writeInitialControlConfig(to: paths.configURL)
            } else {
                try migrateControlConfigIfNeeded(at: paths.configURL)
            }
            return true
        } catch {
            AppLog.shared.error("Failed to initialize archive control folder: \(error.localizedDescription)")
            return false
        }
    }

    private static func writeInitialControlConfig(to configURL: URL) throws {
        let bundle = Bundle.main
        let version = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let config = ArchiveControlConfig(
            schemaVersion: configSchemaVersion,
            archiveID: UUID().uuidString,
            createdAt: Date(),
            createdByVersion: (version?.isEmpty == false ? version! : "dev"),
            layoutMode: "YYYY/MM/DD",
            paths: .init(
                thumbnails: "thumbnails",
                reports: "reports"
            ),
            photoLibraryBinding: nil
        )
        try writeControlConfig(config, to: configURL)
    }

    static func archiveID(for rootURL: URL) -> String? {
        let didAccess = rootURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                rootURL.stopAccessingSecurityScopedResource()
            }
        }
        let configURL = ArchiveControlPaths(rootURL: rootURL).configURL
        return readControlConfig(at: configURL)?.archiveID
    }

    /// Normalizes a user-selected folder to the archive root model (`{root}/Archive/.librarian`).
    /// Accepts selection of:
    /// - archive root parent (`{root}`)
    /// - archive subfolder (`{root}/Archive`)
    /// - control folder (`{root}/Archive/.librarian`)
    /// Returns nil when the selection is not a recognized existing archive.
    static func resolveArchiveRoot(fromUserSelection selectedURL: URL) -> URL? {
        let selected = selectedURL.standardizedFileURL
        let fileManager = FileManager.default

        // Highest-priority intent: user selected the Archive folder itself.
        if selected.lastPathComponent == archiveFolderName {
            let directControlURL = selected
                .appendingPathComponent(controlFolderName, isDirectory: true)
                .appendingPathComponent(configFileName, isDirectory: false)
            if fileManager.fileExists(atPath: directControlURL.path) {
                return selected.deletingLastPathComponent()
            }
        }

        if selected.lastPathComponent == archiveFolderName {
            let parent = selected.deletingLastPathComponent()
            if archiveID(for: parent) != nil {
                return parent
            }
        }

        if selected.lastPathComponent == controlFolderName {
            let archiveFolder = selected.deletingLastPathComponent()
            let parent = archiveFolder.deletingLastPathComponent()
            if archiveFolder.lastPathComponent == archiveFolderName,
               archiveID(for: parent) != nil {
                return parent
            }
        }

        if archiveID(for: selected) != nil {
            return selected
        }

        return nil
    }

    static func resolveArchiveRoot(
        fromUserSelection selectedURL: URL,
        expectedArchiveID: String?
    ) -> ArchiveRootSelectionResolution {
        guard let resolvedRoot = resolveArchiveRoot(fromUserSelection: selectedURL),
              let selectedArchiveID = archiveID(for: resolvedRoot) else {
            return .unresolved
        }

        if let expectedArchiveID, expectedArchiveID != selectedArchiveID {
            return .archiveIDMismatch(
                rootURL: resolvedRoot,
                expectedArchiveID: expectedArchiveID,
                selectedArchiveID: selectedArchiveID
            )
        }

        return .resolved(rootURL: resolvedRoot, archiveID: selectedArchiveID)
    }

    static func controlConfig(for rootURL: URL) -> ArchiveControlConfig? {
        let didAccess = rootURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                rootURL.stopAccessingSecurityScopedResource()
            }
        }
        let configURL = ArchiveControlPaths(rootURL: rootURL).configURL
        return readControlConfig(at: configURL)
    }

    @discardableResult
    static func updateControlConfig(
        at rootURL: URL,
        mutate: (inout ArchiveControlConfig) -> Void
    ) -> Bool {
        guard ensureControlFolder(at: rootURL) else { return false }
        let didAccess = rootURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                rootURL.stopAccessingSecurityScopedResource()
            }
        }
        let configURL = ArchiveControlPaths(rootURL: rootURL).configURL
        guard var config = readControlConfig(at: configURL) else { return false }
        mutate(&config)
        if config.schemaVersion < configSchemaVersion {
            config.schemaVersion = configSchemaVersion
        }
        do {
            try writeControlConfig(config, to: configURL)
            return true
        } catch {
            AppLog.shared.error("Failed to update archive control config: \(error.localizedDescription)")
            return false
        }
    }

    private static func migrateControlConfigIfNeeded(at configURL: URL) throws {
        guard var config = readControlConfig(at: configURL) else { return }
        var didChange = false
        if config.schemaVersion < configSchemaVersion {
            config.schemaVersion = configSchemaVersion
            didChange = true
        }
        if didChange {
            try writeControlConfig(config, to: configURL)
        }
    }

    private static func readControlConfig(at configURL: URL) -> ArchiveControlConfig? {
        guard let data = try? Data(contentsOf: configURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ArchiveControlConfig.self, from: data)
    }

    private static func writeControlConfig(_ config: ArchiveControlConfig, to configURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(config)
        try data.write(to: configURL, options: .atomic)
    }

    /// The archive subfolder inside the user-chosen root — always `{root}/Archive/`.
    /// Content lands in `{root}/Archive/YYYY/MM/DD/`.
    static func archiveTreeRootURL(from rootURL: URL) -> URL {
        rootURL.appendingPathComponent(archiveFolderName, isDirectory: true)
    }

    /// The folder where Path-B imports (Add Photos to Archive) write new files.
    /// Same as the archive tree root — all content uses `YYYY/MM/DD` structure.
    static func importDestinationRoot(from rootURL: URL) -> URL {
        archiveTreeRootURL(from: rootURL)
    }

    static func currentArchiveTreeRootURL() -> URL? {
        let resolution = currentArchiveRootResolution()
        guard let root = resolution.rootURL else { return nil }
        return archiveTreeRootURL(from: root)
    }

    static func currentArchiveRootAvailability() -> ArchiveRootAvailability {
        currentArchiveRootResolution().availability
    }

    static func currentArchiveRootResolution() -> ArchiveRootResolution {
        guard let rootURL = restoreArchiveRootURL() else {
            return ArchiveRootResolution(rootURL: nil, availability: .notConfigured)
        }
        return ArchiveRootResolution(
            rootURL: rootURL,
            availability: archiveRootAvailability(for: rootURL)
        )
    }

    static func archiveRootResolution(for rootURL: URL?) -> ArchiveRootResolution {
        guard let rootURL else {
            return ArchiveRootResolution(rootURL: nil, availability: .notConfigured)
        }
        return ArchiveRootResolution(
            rootURL: rootURL,
            availability: archiveRootAvailability(for: rootURL)
        )
    }

    /// Returns the path to the current system photo library, or nil if unavailable.
    static func currentPhotoLibraryPath() -> String? {
        // Read the Photos.app preferences plist directly to find the default library bookmark.
        let home = FileManager.default.homeDirectoryForCurrentUser
        let plistCandidates = [
            home.appendingPathComponent(
                "Library/Containers/com.apple.Photos/Data/Library/Preferences/com.apple.Photos.plist"
            ),
            home.appendingPathComponent("Library/Preferences/com.apple.Photos.plist"),
        ]

        for plistURL in plistCandidates {
            guard let data = try? Data(contentsOf: plistURL),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
                  let dict = plist as? [String: Any],
                  let bookmarkData = dict["IPXDefaultLibraryURLBookmark"] as? Data
            else { continue }

            var isStale = false
            guard let resolvedURL = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withoutUI, .withoutMounting],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else { continue }

            let standardized = resolvedURL.standardizedFileURL
            guard standardized.pathExtension == "photoslibrary" else { continue }
            return standardized.path
        }

        // Heuristic fallback: look for *.photoslibrary in Pictures
        if let picturesURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first,
           let contents = try? FileManager.default.contentsOfDirectory(
               at: picturesURL,
               includingPropertiesForKeys: nil,
               options: [.skipsHiddenFiles]
           ),
           let library = contents.first(where: { $0.pathExtension == "photoslibrary" }) {
            return library.standardizedFileURL.path
        }
        return nil
    }

    static func archiveRootAvailability(for rootURL: URL) -> ArchiveRootAvailability {
        let didAccess = rootURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                rootURL.stopAccessingSecurityScopedResource()
            }
        }

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: rootURL.path) else {
            return .unavailable
        }

        // Detect folders that have been moved to the Trash — they still exist on disk
        // but should be treated as unavailable so the relink flow fires.
        let trashURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash")
            .standardized
        if rootURL.standardized.path.hasPrefix(trashURL.path + "/") {
            return .unavailable
        }

        do {
            let values = try rootURL.resourceValues(forKeys: [.isDirectoryKey, .volumeIsReadOnlyKey])
            if values.isDirectory == false {
                return .unavailable
            }
            if values.volumeIsReadOnly == true {
                return .readOnly
            }
        } catch {
            AppLog.shared.error("Failed to read archive root resource values: \(error.localizedDescription)")
        }

        if !didAccess && !fileManager.isReadableFile(atPath: rootURL.path) {
            return .permissionDenied
        }
        if !fileManager.isWritableFile(atPath: rootURL.path) {
            return .permissionDenied
        }

        // The bookmark tracks the user-chosen parent folder. The actual archive
        // lives under `{root}/Archive/.librarian`. If `Archive/` was moved away,
        // the root can still exist but the archive is unavailable.
        let paths = ArchiveControlPaths(rootURL: rootURL)
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: paths.archiveFolderURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .unavailable
        }
        guard fileManager.fileExists(atPath: paths.controlRootURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .unavailable
        }
        return .available
    }
}
