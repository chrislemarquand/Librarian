import Cocoa
import Photos
import Combine
import SwiftUI
import SharedUI

enum AppBrand {
    private static let fallbackDisplayName = "Librarian"

    static var displayName: String {
        let bundle = Bundle.main
        if let display = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
           !display.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return display
        }
        if let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return name
        }
        return fallbackDisplayName
    }

    static var identifierPrefix: String {
        let cleaned = displayName.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
        return cleaned.isEmpty ? fallbackDisplayName : cleaned
    }
}

enum ArchiveSettings {
    enum ArchiveRootAvailability: Equatable {
        case notConfigured
        case available
        case unavailable
        case readOnly
        case permissionDenied

        var userVisibleDescription: String {
            switch self {
            case .notConfigured:
                return "No archive destination is configured."
            case .available:
                return "Archive destination is available."
            case .unavailable:
                return "The archive destination is currently unavailable. It may be offline or disconnected."
            case .readOnly:
                return "The archive destination is read-only."
            case .permissionDenied:
                return "Librarian does not currently have permission to access the archive destination."
            }
        }
    }

    // MARK: - Folder layout

    enum ArchiveFolderLayout: String {
        /// All files land in `Archive/YYYY/MM/DD`. Simple flat structure.
        case dateOnly     = "dateOnly"
        /// Photos land in `Photos/YYYY/MM/DD`. Categorised content (screenshots, documents, etc.)
        /// lands in `Other/{type}/YYYY/MM/DD`. Aligns with spec section 23.2.
        case kindThenDate = "kindThenDate"
    }

    static let folderLayoutKey = "com.librarian.app.archiveFolderLayout"

    static var folderLayout: ArchiveFolderLayout {
        get {
            guard let raw = UserDefaults.standard.string(forKey: folderLayoutKey),
                  let layout = ArchiveFolderLayout(rawValue: raw) else { return .dateOnly }
            return layout
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: folderLayoutKey) }
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
        if stale {
            _ = persistArchiveRootURL(url)
        }
        return url
    }

    @discardableResult
    static func persistArchiveRootURL(_ url: URL) -> Bool {
        guard ensureControlFolder(at: url) else { return false }
        let newArchiveID = archiveID(for: url)
        let previousArchiveID = UserDefaults.standard.string(forKey: archiveIDKey)
        guard let bookmark = try? url.bookmarkData(
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
        AppLog.shared.info("Archive root set to: \(url.path)")
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
    /// This is where `.librarian/` lives, where the red icon is applied, and the root
    /// from which the indexer and organizer scan.
    /// - `dateOnly`:     content at `{root}/Archive/YYYY/MM/DD/`
    /// - `kindThenDate`: content at `{root}/Archive/Photos/YYYY/MM/DD/` etc.
    static func archiveTreeRootURL(from rootURL: URL) -> URL {
        rootURL.appendingPathComponent(archiveFolderName, isDirectory: true)
    }

    /// The folder where Path-B imports (Add Photos to Archive) write new files.
    static func importDestinationRoot(from rootURL: URL) -> URL {
        let archiveFolder = archiveTreeRootURL(from: rootURL)
        switch folderLayout {
        case .dateOnly:     return archiveFolder
        case .kindThenDate: return archiveFolder.appendingPathComponent("Photos", isDirectory: true)
        }
    }

    static func currentArchiveTreeRootURL() -> URL? {
        guard let root = restoreArchiveRootURL() else { return nil }
        return archiveTreeRootURL(from: root)
    }

    static func currentArchiveRootAvailability() -> ArchiveRootAvailability {
        guard let rootURL = restoreArchiveRootURL() else { return .notConfigured }
        return archiveRootAvailability(for: rootURL)
    }

    static func currentPhotoLibraryFingerprint() throws -> PhotoLibraryFingerprint {
        try PhotoLibraryFingerprintService.currentFingerprint()
    }

    static func evaluatePhotoLibraryBinding(
        for rootURL: URL,
        persistMatchTimestamp: Bool = false
    ) -> ArchiveLibraryBindingEvaluation {
        ArchiveLibraryBindingEvaluator.evaluate(
            rootURL: rootURL,
            persistMatchTimestamp: persistMatchTimestamp
        )
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

enum ArchiveWriteOperation {
    case importIntoArchive
    case organizeArchive
    case exportArchive

    var displayName: String {
        switch self {
        case .importIntoArchive:
            return "import photos"
        case .organizeArchive:
            return "organize the archive"
        case .exportArchive:
            return "export"
        }
    }
}

struct ArchiveWriteGateDecision {
    enum Status {
        case allowed
        case requiresResolution
        case error
    }

    let status: Status
    let rootURL: URL?
    let evaluation: ArchiveLibraryBindingEvaluation?
    let message: String

    var isAllowed: Bool { status == .allowed }
}

@MainActor
final class AppModel: ObservableObject {
    private static let staleArchiveExportMessage =
        "Previous archive export was interrupted. Item returned to Set Aside."

    // MARK: - Services (owned here, accessed by coordinators)

    let photosService: PhotosLibraryService
    let database: DatabaseManager

    // MARK: - Published state

    @Published var photosAuthState: PHAuthorizationStatus = .notDetermined
    @Published var selectedSidebarItem: SidebarItem? = SidebarItem.allItems.first
    @Published var isInspectorCollapsed = false
    @Published var isIndexing = false
    @Published var isSendingArchive = false
    @Published var isAnalysing = false
    @Published var analysisStatusText: String = ""
    @Published var isImportingArchive = false
    @Published var importStatusText: String = ""
    @Published var indexedAssetCount = 0
    @Published var pendingArchiveCandidateCount = 0
    @Published var failedArchiveCandidateCount = 0
    @Published var assetDataVersion: Int = 0
    @Published var selectedAsset: IndexedAsset?
    @Published var selectedArchivedItem: ArchivedItem?
    @Published var selectedAssetCount: Int = 0
    @Published var activeInspectorFieldCatalog: [InspectorFieldCatalogEntry] = AppModel.defaultInspectorFieldCatalog()
    @Published var indexingProgress: IndexingProgress = .idle
    @Published var archiveRootAvailability: ArchiveSettings.ArchiveRootAvailability = .notConfigured
    @Published var archiveRootURL: URL? = ArchiveSettings.restoreArchiveRootURL()
    @Published var currentSystemPhotoLibraryPath: String?
    @Published var currentSystemPhotoLibraryFingerprint: String?
    @Published var latestArchiveLibraryBindingEvaluation: ArchiveLibraryBindingEvaluation?
    @Published var galleryGridLevel: Int = 4 {
        didSet {
            let clamped = min(max(galleryGridLevel, Self.galleryColumnRange.lowerBound), Self.galleryColumnRange.upperBound)
            if galleryGridLevel != clamped {
                galleryGridLevel = clamped
                return
            }
            UserDefaults.standard.set(galleryGridLevel, forKey: Self.galleryGridLevelKey)
            NotificationCenter.default.post(name: .librarianGalleryZoomChanged, object: nil)
        }
    }

    private var changeTracker: PhotosChangeTracker?
    private var pendingDeltaApplyTask: Task<Void, Never>?
    private var pendingUnknownReconcileTask: Task<Void, Never>?
    private var pendingLibraryIdentityCheckTask: Task<Void, Never>?
    private var libraryMonitorTimer: Timer?
    private var suppressChangeSyncUntil: Date = .distantPast
    private var suppressChangeSyncReason: String?
    private var pendingUpsertsByIdentifier: [String: IndexedAsset] = [:]
    private var pendingDeletedIdentifiers: Set<String> = []

    static let galleryColumnRange = 2 ... 9
    private static let galleryGridLevelKey = "ui.gallery.grid.level"
    static let inspectorFieldVisibilityKey = "ui.inspector.field.visibility"

    // MARK: - Init

    init() {
        self.photosService = PhotosLibraryService()
        self.database = DatabaseManager()
        let defaults = UserDefaults.standard
        let storedLevel = defaults.integer(forKey: Self.galleryGridLevelKey)
        if storedLevel == 0 {
            galleryGridLevel = 4
        } else {
            galleryGridLevel = min(max(storedLevel, Self.galleryColumnRange.lowerBound), Self.galleryColumnRange.upperBound)
        }
        activeInspectorFieldCatalog = Self.applyingInspectorVisibilityPreferences(to: Self.defaultInspectorFieldCatalog())
    }

    // MARK: - Setup

    func setup() async {
        do {
            try database.open()
        } catch {
            // Database open failure is unrecoverable — surface via overlay
            indexingProgress = .failed(error.localizedDescription)
            AppLog.shared.error("Database open failed: \(error.localizedDescription)")
            return
        }
        AppLog.shared.info("Database opened")

        do {
            let recovered = try database.assetRepository.recoverStaleArchiveExports(
                errorMessage: Self.staleArchiveExportMessage
            )
            if recovered > 0 {
                AppLog.shared.info("Recovered \(recovered) stale archive export item(s) at launch")
            }
        } catch {
            AppLog.shared.error("Failed to recover stale archive exports: \(error.localizedDescription)")
        }

        // Load persisted count before requesting Photos access so UI isn't blank
        indexedAssetCount = (try? database.assetRepository.count()) ?? 0
        pendingArchiveCandidateCount = (try? database.assetRepository.countArchiveCandidates(statuses: [.pending, .exporting, .failed])) ?? 0
        failedArchiveCandidateCount = (try? database.assetRepository.countArchiveCandidates(statuses: [.failed])) ?? 0
        AppLog.shared.info("Loaded persisted index count: \(indexedAssetCount)")
        let availability = refreshArchiveRootAvailability()
        // Always post so the breadcrumb and archive view reflect any bookmark
        // the OS silently resolved to a new path (e.g. archive moved in Finder).
        NotificationCenter.default.post(name: .librarianArchiveRootChanged, object: nil)
        if availability == .unavailable {
            NotificationCenter.default.post(name: .librarianArchiveNeedsRelink, object: nil)
        }
        startSystemPhotoLibraryMonitoring()
        scheduleSystemPhotoLibraryRefresh(reason: "startup", debounceMilliseconds: 0)

        await requestPhotosAccess()
    }

    // MARK: - Photos access

    private func requestPhotosAccess() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        photosAuthState = status
        AppLog.shared.info("Photos authorization status: \(String(describing: status.rawValue))")
        notifyIndexingStateChanged()

        switch status {
        case .authorized:
            registerChangeTracking()
            suppressChangeSync(for: 8, reason: "initialAuthorization")
            if indexedAssetCount == 0 {
                await startInitialIndex()
            } else {
                AppLog.shared.info("Skipping full launch re-index; existing index count is \(indexedAssetCount)")
            }
        case .limited:
            // Limited access: show locked state — full access required
            unregisterChangeTracking()
            break
        default:
            unregisterChangeTracking()
            break
        }
    }

    func retryPhotosAccess() async {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        photosAuthState = status
        notifyIndexingStateChanged()
        if status == .authorized {
            registerChangeTracking()
            if indexedAssetCount == 0 {
                await startInitialIndex()
            }
        } else {
            unregisterChangeTracking()
        }
    }

    // MARK: - Indexing

    private func startInitialIndex() async {
        await startIndexing(reason: "initial", userVisibleProgress: true)
    }

    func rebuildIndexManually() async {
        await startIndexing(reason: "manualRebuild", userVisibleProgress: true)
    }

    private func startBackgroundSync(reason: String) async {
        await startIndexing(reason: reason, userVisibleProgress: false)
    }

    private func startIndexing(reason: String, userVisibleProgress: Bool) async {
        guard !isIndexing else { return }
        isIndexing = true
        if userVisibleProgress {
            indexingProgress = .running(completed: 0, total: 0)
        }
        AppLog.shared.info("Indexing started (\(reason))")
        notifyIndexingStateChanged()

        let indexer = AssetIndexer(database: database)
        do {
            for try await progress in indexer.run() {
                if userVisibleProgress {
                    indexingProgress = .running(completed: progress.completed, total: progress.total)
                }
                indexedAssetCount = progress.completed
                if userVisibleProgress {
                    notifyIndexingStateChanged()
                }
            }
            if userVisibleProgress {
                indexingProgress = .idle
            }
            AppLog.shared.info("Indexing completed (\(reason))")
        } catch {
            indexingProgress = .failed(error.localizedDescription)
            AppLog.shared.error("Indexing failed (\(reason)): \(error.localizedDescription)")
        }

        isIndexing = false
        indexedAssetCount = (try? database.assetRepository.count()) ?? indexedAssetCount
        assetDataVersion &+= 1
        notifyIndexingStateChanged()
    }

    private func notifyIndexingStateChanged() {
        NotificationCenter.default.post(name: .librarianIndexingStateChanged, object: nil)
    }

    func setSelectedSidebarItem(_ item: SidebarItem) {
        if selectedSidebarItem?.kind == item.kind {
            return
        }
        selectedSidebarItem = item
        NotificationCenter.default.post(name: .librarianSidebarSelectionChanged, object: nil)
    }

    func setSelectedAsset(_ asset: IndexedAsset?, count: Int = 1) {
        let newCount = asset == nil ? 0 : count
        if selectedAsset?.localIdentifier == asset?.localIdentifier,
           selectedArchivedItem == nil,
           selectedAssetCount == newCount {
            return
        }
        selectedAsset = asset
        selectedArchivedItem = nil
        selectedAssetCount = newCount
        NotificationCenter.default.post(name: .librarianSelectionChanged, object: nil)
    }

    func setSelectedArchivedItem(_ item: ArchivedItem?, count: Int = 1) {
        let newCount = item == nil ? 0 : count
        if selectedArchivedItem?.relativePath == item?.relativePath,
           selectedAsset == nil,
           selectedAssetCount == newCount {
            return
        }
        selectedArchivedItem = item
        selectedAsset = nil
        selectedAssetCount = newCount
        NotificationCenter.default.post(name: .librarianSelectionChanged, object: nil)
    }

    func queueAssetsForArchive(localIdentifiers: [String]) throws {
        let identifiers = Array(Set(localIdentifiers))
        guard !identifiers.isEmpty else { return }
        try database.assetRepository.queueForArchive(identifiers: identifiers)
        AppLog.shared.info("Queued \(identifiers.count) item(s) for archive")
        refreshArchiveCandidateCount()
    }

    func unqueueAssetsForArchive(localIdentifiers: [String]) throws {
        let identifiers = Array(Set(localIdentifiers))
        guard !identifiers.isEmpty else { return }
        try database.assetRepository.removeFromArchiveQueue(identifiers: identifiers)
        AppLog.shared.info("Removed \(identifiers.count) item(s) from archive set-aside queue")
        refreshArchiveCandidateCount()
    }

    func unqueueFailedArchiveAssets() throws -> Int {
        let failed = try database.assetRepository.fetchArchiveCandidateIdentifiers(statuses: [.failed])
        guard !failed.isEmpty else { return 0 }
        try database.assetRepository.removeFromArchiveQueue(identifiers: failed)
        AppLog.shared.info("Removed \(failed.count) failed item(s) from archive set-aside queue")
        refreshArchiveCandidateCount()
        assetDataVersion &+= 1
        return failed.count
    }

    @discardableResult
    func updateArchiveRoot(_ url: URL) -> Bool {
        // Remove the custom icon from the current Archive/ subfolder before switching.
        if let oldRoot = ArchiveSettings.restoreArchiveRootURL(),
           oldRoot.standardizedFileURL != url.standardizedFileURL {
            ArchiveFolderIcon.remove(from: ArchiveSettings.archiveTreeRootURL(from: oldRoot), accessedVia: oldRoot)
        }
        guard ArchiveSettings.persistArchiveRootURL(url) else { return false }
        ArchiveFolderIcon.apply(to: ArchiveSettings.archiveTreeRootURL(from: url), accessedVia: url)
        refreshArchiveRootAvailability()
        NotificationCenter.default.post(name: .librarianArchiveRootChanged, object: nil)
        NotificationCenter.default.post(name: .librarianArchiveQueueChanged, object: nil)
        scheduleSystemPhotoLibraryRefresh(reason: "archiveRootUpdated", debounceMilliseconds: 0)
        return true
    }

    @discardableResult
    func refreshArchiveRootAvailability() -> ArchiveSettings.ArchiveRootAvailability {
        let previous = archiveRootAvailability
        let current = ArchiveSettings.currentArchiveRootAvailability()
        archiveRootAvailability = current
        archiveRootURL = ArchiveSettings.restoreArchiveRootURL()
        if previous != current {
            AppLog.shared.info("Archive root availability changed: \(String(describing: previous)) -> \(String(describing: current))")
        }
        return current
    }

    func runLibraryAnalysis() async {
        guard !isAnalysing else { return }
        isAnalysing = true
        analysisStatusText = "Starting…"
        notifyAnalysisStateChanged()

        let analyser = LibraryAnalyser(database: database)
        do {
            for try await progress in analyser.run() {
                analysisStatusText = progress.statusText
                notifyAnalysisStateChanged()
            }
            analysisStatusText = ""
            assetDataVersion &+= 1
        } catch {
            analysisStatusText = "Failed: \(error.localizedDescription)"
            AppLog.shared.error("Library analysis failed: \(error.localizedDescription)")
        }

        isAnalysing = false
        notifyAnalysisStateChanged()
    }

    private func notifyAnalysisStateChanged() {
        NotificationCenter.default.post(name: .librarianAnalysisStateChanged, object: nil)
    }

    func runArchiveImport(
        sourceFolders: [URL],
        preflight: ArchiveImportPreflightResult
    ) async throws -> ArchiveImportRunSummary {
        let gate = evaluateArchiveWriteGate(for: .importIntoArchive)
        guard gate.isAllowed, let archiveRoot = gate.rootURL else {
            throw NSError(domain: "\(AppBrand.identifierPrefix).archiveImport", code: 6, userInfo: [
                NSLocalizedDescriptionKey: gate.message
            ])
        }
        guard !isImportingArchive else {
            throw NSError(domain: "\(AppBrand.identifierPrefix).archiveImport", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "An archive import is already in progress."
            ])
        }
        isImportingArchive = true
        importStatusText = "Starting import…"
        defer {
            isImportingArchive = false
        }

        let jobStartedAt = Date()
        let jobID = UUID().uuidString
        let job = try await database.jobRepository.create(type: .archiveImport)
        try await database.jobRepository.markRunning(job)

        let coordinator = ArchiveImportCoordinator(
            archiveRoot: archiveRoot,
            sourceFolders: sourceFolders,
            database: database
        )

        var finalSummary: ArchiveImportRunSummary?
        do {
            for try await event in coordinator.runImport(preflight: preflight) {
                switch event {
                case .progress(let completed, let total):
                    importStatusText = "Importing \(completed.formatted()) / \(total.formatted())…"
                case .done(let summary):
                    finalSummary = summary
                    importStatusText = ""
                }
            }

            guard let summary = finalSummary else {
                throw NSError(domain: "\(AppBrand.identifierPrefix).archiveImport", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Import produced no result."
                ])
            }

            try database.assetRepository.saveArchiveImportRun(
                id: jobID,
                startedAt: jobStartedAt,
                summary: summary,
                archiveRootPath: archiveRoot.path,
                sourcePaths: sourceFolders.map(\.path)
            )

            if summary.imported > 0 {
                // Re-index the archive on a background thread so sidebar counts update.
                let db = self.database
                Task.detached(priority: .utility) {
                    let indexer = ArchiveIndexer(database: db)
                    _ = try? indexer.refreshIndex()
                    await MainActor.run {
                        NotificationCenter.default.post(name: .librarianArchiveQueueChanged, object: nil)
                    }
                }
            }

            try await database.jobRepository.markCompleted(job)
            AppLog.shared.info(
                "Archive import completed. imported=\(summary.imported), " +
                "skippedDuplicateInSource=\(summary.skippedDuplicateInSource), " +
                "skippedExistsInPhotoKit=\(summary.skippedExistsInPhotoKit), " +
                "failed=\(summary.failed)"
            )
            return summary

        } catch {
            try? await database.jobRepository.markFailed(job, error: error.localizedDescription)
            importStatusText = "Import failed: \(error.localizedDescription)"
            AppLog.shared.error("Archive import failed: \(error.localizedDescription)")
            throw error
        }
    }

    func archiveCandidateInfo(for localIdentifier: String) -> ArchiveCandidateInfo? {
        try? database.assetRepository.fetchArchiveCandidateInfo(localIdentifier: localIdentifier)
    }

    func sendPendingArchive(to archiveRootURL: URL) async throws {
        let outcome = try await sendPendingArchiveWithOutcome(to: archiveRootURL, options: .default)
        if outcome.exportedCount == 0 {
            throw NSError(domain: "\(AppBrand.identifierPrefix).archive", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Export failed for \(outcome.failedCount) item(s). Nothing was deleted."
            ])
        }
        if outcome.notDeletedCount > 0 {
            throw NSError(domain: "\(AppBrand.identifierPrefix).archive", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "Exported \(outcome.exportedCount) item(s), but \(outcome.notDeletedCount) could not be removed from Photos. Those items were returned to Set Aside."
            ])
        }
        if outcome.failedCount > 0 {
            throw NSError(domain: "\(AppBrand.identifierPrefix).archive", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "Exported \(outcome.exportedCount) item(s). \(outcome.failedCount) failed and remain in Set Aside."
            ])
        }
    }

    func sendPendingArchiveWithOutcome(
        to archiveRootURL: URL,
        options: ArchiveExportOptions
    ) async throws -> ArchiveSendOutcome {
        try await sendArchiveCandidatesWithOutcome(
            to: archiveRootURL,
            options: options,
            localIdentifiers: nil
        )
    }

    func sendArchiveCandidatesWithOutcome(
        to archiveRootURL: URL,
        options: ArchiveExportOptions,
        localIdentifiers: [String]? = nil
    ) async throws -> ArchiveSendOutcome {
        let gate = evaluateArchiveWriteGate(for: .exportArchive, preferredRootURL: archiveRootURL)
        guard gate.isAllowed else {
            throw NSError(domain: "\(AppBrand.identifierPrefix).archive", code: 9, userInfo: [
                NSLocalizedDescriptionKey: gate.message
            ])
        }
        guard ArchiveSettings.ensureControlFolder(at: archiveRootURL) else {
            throw NSError(domain: "\(AppBrand.identifierPrefix).archive", code: 8, userInfo: [
                NSLocalizedDescriptionKey: "Couldn’t initialize archive control folder at the selected location."
            ])
        }
        guard !isSendingArchive else {
            return ArchiveSendOutcome(exportedCount: 0, deletedCount: 0, failedCount: 0, notDeletedCount: 0, failures: [])
        }
        let pendingOrFailedIdentifiers = try database.assetRepository.fetchArchiveCandidateIdentifiers(statuses: [.pending, .failed])
        let identifiers: [String]
        if let localIdentifiers {
            let scopedSet = Set(localIdentifiers)
            identifiers = pendingOrFailedIdentifiers.filter { scopedSet.contains($0) }
        } else {
            identifiers = pendingOrFailedIdentifiers
        }
        guard !identifiers.isEmpty else {
            return ArchiveSendOutcome(exportedCount: 0, deletedCount: 0, failedCount: 0, notDeletedCount: 0, failures: [])
        }

        isSendingArchive = true
        defer { isSendingArchive = false }

        let job = try await database.jobRepository.create(type: .archiveExport)
        try await database.jobRepository.markRunning(job)

        do {
            try database.assetRepository.markArchiveCandidatesExporting(identifiers: identifiers)
            refreshArchiveCandidateCount()
            let exportTargets = [
                ArchiveExportTarget(
                    destination: archiveRootForExport(archiveRootURL),
                    localIdentifiers: identifiers
                )
            ]
            let exportRoot = archiveRootURL
            let exportResult = try await Task.detached(priority: .utility) {
                try withArchiveRootAccess(root: exportRoot) {
                    try runOsxPhotosExportBatch(targets: exportTargets, options: options)
                }
            }.value
            let exportedIdentifiers = Array(Set(exportResult.exportedGroups.flatMap(\.localIdentifiers)))
            var failures = exportResult.failures
            let failedIdentifiers = Array(Set(failures.map(\.identifier)))

            if !failedIdentifiers.isEmpty {
                let failedByIdentifier = Dictionary(grouping: failures, by: \.identifier)
                let summary = failedIdentifiers.compactMap { identifier -> String? in
                    guard let groupedFailures = failedByIdentifier[identifier], let message = groupedFailures.first?.message else { return nil }
                    return "\(identifier): \(message)"
                }.joined(separator: " | ")
                try database.assetRepository.markArchiveCandidatesFailed(identifiers: failedIdentifiers, error: summary)
                AppLog.shared.error("Archive export failed for \(failedIdentifiers.count) item(s): \(summary)")
            }

            guard !exportedIdentifiers.isEmpty else {
                try await database.jobRepository.markFailed(job, error: "No items were exported.")
                refreshArchiveCandidateCount()
                return ArchiveSendOutcome(
                    exportedCount: 0,
                    deletedCount: 0,
                    failedCount: failedIdentifiers.count,
                    notDeletedCount: 0,
                    failures: failures
                )
            }

            for group in exportResult.exportedGroups where !group.localIdentifiers.isEmpty {
                try database.assetRepository.markArchiveCandidatesExported(identifiers: group.localIdentifiers, archivePath: group.destinationPath)
            }
            suppressChangeSync(for: 20, reason: "archiveDelete")
            let deletedIdentifiers = try await photosService.deleteAssets(localIdentifiers: exportedIdentifiers)
            let deletedSet = Set(deletedIdentifiers)
            let expectedSet = Set(exportedIdentifiers)
            let notDeleted = Array(expectedSet.subtracting(deletedSet))

            if !deletedIdentifiers.isEmpty {
                try database.assetRepository.markDeleted(identifiers: deletedIdentifiers, at: Date())
                try database.assetRepository.markArchiveCandidatesDeleted(identifiers: deletedIdentifiers)
            }

            if !notDeleted.isEmpty {
                let errorText = "Delete step did not remove \(notDeleted.count) item(s) from Photos. Returned to archive box."
                try database.assetRepository.markArchiveCandidatesFailed(identifiers: notDeleted, error: errorText)
                failures.append(contentsOf: notDeleted.map { ArchiveExportFailure(identifier: $0, message: errorText) })
                try await database.jobRepository.markFailed(job, error: errorText)
                AppLog.shared.error("Archive send partially failed. Exported \(exportedIdentifiers.count), deleted \(deletedIdentifiers.count), not deleted \(notDeleted.count).")
                indexedAssetCount = (try? database.assetRepository.count()) ?? indexedAssetCount
                assetDataVersion &+= 1
                refreshArchiveCandidateCount()
                notifyIndexingStateChanged()
                return ArchiveSendOutcome(
                    exportedCount: exportedIdentifiers.count,
                    deletedCount: deletedIdentifiers.count,
                    failedCount: Array(Set(failures.map(\.identifier))).count,
                    notDeletedCount: notDeleted.count,
                    failures: failures
                )
            }

            if !failedIdentifiers.isEmpty {
                let message = "Exported \(exportedIdentifiers.count) item(s). \(failedIdentifiers.count) failed and remain in Set Aside."
                try await database.jobRepository.markFailed(job, error: message)
                indexedAssetCount = (try? database.assetRepository.count()) ?? indexedAssetCount
                assetDataVersion &+= 1
                refreshArchiveCandidateCount()
                notifyIndexingStateChanged()
                return ArchiveSendOutcome(
                    exportedCount: exportedIdentifiers.count,
                    deletedCount: deletedIdentifiers.count,
                    failedCount: failedIdentifiers.count,
                    notDeletedCount: 0,
                    failures: failures
                )
            }

            try await database.jobRepository.markCompleted(job)
            AppLog.shared.info("Archive send completed. Exported \(exportedIdentifiers.count) and deleted \(deletedIdentifiers.count) from Photos.")
            indexedAssetCount = (try? database.assetRepository.count()) ?? indexedAssetCount
            assetDataVersion &+= 1
            refreshArchiveCandidateCount()
            notifyIndexingStateChanged()
            return ArchiveSendOutcome(
                exportedCount: exportedIdentifiers.count,
                deletedCount: deletedIdentifiers.count,
                failedCount: 0,
                notDeletedCount: 0,
                failures: []
            )
        } catch {
            let exportingIdentifiers = (try? database.assetRepository.fetchArchiveCandidateIdentifiers(statuses: [.exporting])) ?? []
            let stillExporting = Array(Set(exportingIdentifiers).intersection(Set(identifiers)))
            if !stillExporting.isEmpty {
                try? database.assetRepository.markArchiveCandidatesFailed(identifiers: stillExporting, error: error.localizedDescription)
            }
            try? await database.jobRepository.markFailed(job, error: error.localizedDescription)
            refreshArchiveCandidateCount()
            AppLog.shared.error("Archive send failed: \(error.localizedDescription)")
            throw error
        }
    }

    var galleryColumnCount: Int {
        galleryGridLevel
    }

    var canIncreaseGalleryZoom: Bool {
        galleryGridLevel > Self.galleryColumnRange.lowerBound
    }

    var canDecreaseGalleryZoom: Bool {
        galleryGridLevel < Self.galleryColumnRange.upperBound
    }

    func increaseGalleryZoom() {
        galleryGridLevel = max(galleryGridLevel - 1, Self.galleryColumnRange.lowerBound)
    }

    func decreaseGalleryZoom() {
        galleryGridLevel = min(galleryGridLevel + 1, Self.galleryColumnRange.upperBound)
    }

    func adjustGalleryGridLevel(by delta: Int) {
        guard delta != 0 else { return }
        galleryGridLevel = min(
            max(galleryGridLevel + delta, Self.galleryColumnRange.lowerBound),
            Self.galleryColumnRange.upperBound
        )
    }

    deinit {
        pendingDeltaApplyTask?.cancel()
        pendingUnknownReconcileTask?.cancel()
        pendingLibraryIdentityCheckTask?.cancel()
    }

    var currentSystemPhotoLibraryURL: URL? {
        guard let path = currentSystemPhotoLibraryPath, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    func scheduleSystemPhotoLibraryRefresh(reason: String, debounceMilliseconds: UInt64 = 450) {
        pendingLibraryIdentityCheckTask?.cancel()
        pendingLibraryIdentityCheckTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if debounceMilliseconds > 0 {
                try? await Task.sleep(nanoseconds: debounceMilliseconds * 1_000_000)
            }
            guard !Task.isCancelled else { return }
            self.refreshSystemPhotoLibraryState(reason: reason)
        }
    }

    private func startSystemPhotoLibraryMonitoring() {
        guard libraryMonitorTimer == nil else { return }
        libraryMonitorTimer = Timer.scheduledTimer(withTimeInterval: 6.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleSystemPhotoLibraryRefresh(reason: "periodicPoll")
            }
        }
    }

    private func refreshSystemPhotoLibraryState(reason: String) {
        let fingerprint: PhotoLibraryFingerprint?
        do {
            fingerprint = try ArchiveSettings.currentPhotoLibraryFingerprint()
        } catch {
            AppLog.shared.info("System photo library fingerprint unavailable (\(reason)): \(error.localizedDescription)")
            fingerprint = nil
        }

        let previousPath = currentSystemPhotoLibraryPath
        let previousFingerprint = currentSystemPhotoLibraryFingerprint
        let nextPath = fingerprint?.pathHint
        let nextFingerprint = fingerprint?.fingerprint

        currentSystemPhotoLibraryPath = nextPath
        currentSystemPhotoLibraryFingerprint = nextFingerprint
        if previousPath != nextPath || previousFingerprint != nextFingerprint {
            NotificationCenter.default.post(name: .librarianSystemPhotoLibraryChanged, object: nil)
        }

        guard let archiveRoot = ArchiveSettings.restoreArchiveRootURL() else {
            latestArchiveLibraryBindingEvaluation = nil
            return
        }

        let evaluation = ArchiveSettings.evaluatePhotoLibraryBinding(for: archiveRoot, persistMatchTimestamp: false)
        let previousEvaluation = latestArchiveLibraryBindingEvaluation
        latestArchiveLibraryBindingEvaluation = evaluation
        if previousEvaluation != evaluation {
            NotificationCenter.default.post(name: .librarianArchiveLibraryBindingChanged, object: nil)
        }

        if evaluation.state == .match, let fingerprint = evaluation.currentFingerprint {
            ArchiveLibraryCouplingRegistry.upsert(
                libraryFingerprint: fingerprint,
                archiveRootURL: archiveRoot,
                archiveID: evaluation.archiveID,
                libraryPathHint: evaluation.currentLibraryPathHint
            )
        }
    }

    func evaluateArchiveWriteGate(
        for operation: ArchiveWriteOperation,
        preferredRootURL: URL? = nil
    ) -> ArchiveWriteGateDecision {
        guard let archiveRoot = preferredRootURL ?? ArchiveSettings.restoreArchiveRootURL() else {
            return ArchiveWriteGateDecision(
                status: .error,
                rootURL: nil,
                evaluation: nil,
                message: "No archive destination is configured."
            )
        }

        let availability = ArchiveSettings.archiveRootAvailability(for: archiveRoot)
        guard availability == .available else {
            return ArchiveWriteGateDecision(
                status: .error,
                rootURL: archiveRoot,
                evaluation: nil,
                message: availability.userVisibleDescription
            )
        }

        let evaluation = ArchiveSettings.evaluatePhotoLibraryBinding(for: archiveRoot, persistMatchTimestamp: false)
        let previousEvaluation = latestArchiveLibraryBindingEvaluation
        latestArchiveLibraryBindingEvaluation = evaluation
        if previousEvaluation != evaluation {
            NotificationCenter.default.post(name: .librarianArchiveLibraryBindingChanged, object: nil)
        }

        switch evaluation.state {
        case .match:
            if let fingerprint = evaluation.currentFingerprint {
                ArchiveLibraryCouplingRegistry.upsert(
                    libraryFingerprint: fingerprint,
                    archiveRootURL: archiveRoot,
                    archiveID: evaluation.archiveID,
                    libraryPathHint: evaluation.currentLibraryPathHint
                )
            }
            return ArchiveWriteGateDecision(
                status: .allowed,
                rootURL: archiveRoot,
                evaluation: evaluation,
                message: ""
            )
        case .mismatch:
            return ArchiveWriteGateDecision(
                status: .requiresResolution,
                rootURL: archiveRoot,
                evaluation: evaluation,
                message: "This archive is linked to a different photo library. Resolve the archive-library pairing in Settings before you can \(operation.displayName)."
            )
        case .unbound:
            if tryAutoBindArchiveToCurrentLibrary(rootURL: archiveRoot) {
                return evaluateArchiveWriteGate(for: operation, preferredRootURL: archiveRoot)
            }
            return ArchiveWriteGateDecision(
                status: .requiresResolution,
                rootURL: archiveRoot,
                evaluation: evaluation,
                message: "This archive is not linked to a photo library yet. Complete pairing in Settings before you can \(operation.displayName)."
            )
        case .unknown:
            return ArchiveWriteGateDecision(
                status: .requiresResolution,
                rootURL: archiveRoot,
                evaluation: evaluation,
                message: "Librarian couldn’t verify the active photo library. Resolve this in Settings before you can \(operation.displayName)."
            )
        }
    }

    private func tryAutoBindArchiveToCurrentLibrary(rootURL: URL) -> Bool {
        guard let library = try? ArchiveSettings.currentPhotoLibraryFingerprint() else { return false }
        let didUpdate = ArchiveSettings.updateControlConfig(at: rootURL) { config in
            guard config.photoLibraryBinding == nil else { return }
            config.photoLibraryBinding = ArchiveSettings.ArchiveControlConfig.PhotoLibraryBinding(
                libraryFingerprint: library.fingerprint,
                libraryIDSource: library.source,
                libraryPathHint: library.pathHint,
                boundAt: Date(),
                bindingMode: .strict,
                lastSeenMatchAt: Date()
            )
            if config.schemaVersion < ArchiveSettings.configSchemaVersion {
                config.schemaVersion = ArchiveSettings.configSchemaVersion
            }
        }
        if didUpdate {
            ArchiveLibraryCouplingRegistry.upsert(
                libraryFingerprint: library.fingerprint,
                archiveRootURL: rootURL,
                archiveID: ArchiveSettings.archiveID(for: rootURL),
                libraryPathHint: library.pathHint
            )
            scheduleSystemPhotoLibraryRefresh(reason: "autoBindCurrentLibrary", debounceMilliseconds: 0)
        }
        return didUpdate
    }

    func knownCouplingForCurrentSystemLibrary() -> ArchiveLibraryCouplingEntry? {
        guard let currentFingerprint = currentSystemPhotoLibraryFingerprint else { return nil }
        return ArchiveLibraryCouplingRegistry.coupling(for: currentFingerprint)
    }

    func knownCoupledArchiveRootURLForCurrentSystemLibrary() -> URL? {
        guard let currentFingerprint = currentSystemPhotoLibraryFingerprint else { return nil }
        return ArchiveLibraryCouplingRegistry.resolveArchiveRootURL(for: currentFingerprint)
    }

    private func registerChangeTracking() {
        guard changeTracker == nil else { return }
        let tracker = PhotosChangeTracker { [weak self] changeEvent in
            Task { @MainActor in
                self?.handlePhotoLibraryChangeEvent(changeEvent)
            }
        }
        tracker.register()
        changeTracker = tracker
        AppLog.shared.info("Registered Photos change tracker")
    }

    private func unregisterChangeTracking() {
        pendingDeltaApplyTask?.cancel()
        pendingDeltaApplyTask = nil
        pendingUnknownReconcileTask?.cancel()
        pendingUnknownReconcileTask = nil
        pendingUpsertsByIdentifier.removeAll()
        pendingDeletedIdentifiers.removeAll()
        changeTracker?.unregister()
        changeTracker = nil
    }

    private func handlePhotoLibraryChangeEvent(_ event: PhotosLibraryChangeEvent) {
        if Date() < suppressChangeSyncUntil {
            let reason = suppressChangeSyncReason ?? "unspecified"
            AppLog.shared.info("Ignoring photoLibraryDidChange (suppressed: \(reason))")
            return
        }

        switch event {
        case .unknown:
            AppLog.shared.info("Photo library changed (unknown delta); scheduling deleted-asset reconcile")
            scheduleUnknownReconcile()
        case .delta(let delta):
            accumulate(delta: delta)
            scheduleDeltaApply()
        }
    }

    private func accumulate(delta: PhotosLibraryDelta) {
        for identifier in delta.deletedLocalIdentifiers {
            pendingDeletedIdentifiers.insert(identifier)
            pendingUpsertsByIdentifier.removeValue(forKey: identifier)
        }
        for asset in delta.upsertedAssets {
            guard !pendingDeletedIdentifiers.contains(asset.localIdentifier) else { continue }
            pendingUpsertsByIdentifier[asset.localIdentifier] = asset
        }
    }

    private func scheduleDeltaApply() {
        pendingDeltaApplyTask?.cancel()
        pendingDeltaApplyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            await self?.applyPendingPhotoLibraryDelta()
        }
    }

    private func scheduleUnknownReconcile() {
        pendingUnknownReconcileTask?.cancel()
        pendingUnknownReconcileTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            await self?.reconcileRestoredDeletedAssets()
        }
    }

    private func suppressChangeSync(for seconds: TimeInterval, reason: String) {
        let until = Date().addingTimeInterval(seconds)
        if until > suppressChangeSyncUntil {
            suppressChangeSyncUntil = until
            suppressChangeSyncReason = reason
        }
    }

    private func applyPendingPhotoLibraryDelta() async {
        let upserts = Array(pendingUpsertsByIdentifier.values)
        let deleted = Array(pendingDeletedIdentifiers)
        pendingUpsertsByIdentifier.removeAll()
        pendingDeletedIdentifiers.removeAll()

        guard !upserts.isEmpty || !deleted.isEmpty else { return }

        do {
            if !upserts.isEmpty {
                try await database.assetRepository.upsert(upserts)
            }
            if !deleted.isEmpty {
                try database.assetRepository.markDeleted(identifiers: deleted, at: Date())
            }
            indexedAssetCount = (try? database.assetRepository.count()) ?? indexedAssetCount
            assetDataVersion &+= 1
            AppLog.shared.info("Applied photo delta: upserts=\(upserts.count), deleted=\(deleted.count)")
            notifyIndexingStateChanged()
        } catch {
            AppLog.shared.error("Failed applying photo delta: \(error.localizedDescription)")
        }
    }

    private func reconcileRestoredDeletedAssets() async {
        do {
            let deletedIdentifiers = try database.assetRepository.fetchDeletedAssetIdentifiers()
            guard !deletedIdentifiers.isEmpty else { return }

            let restoredAssets = photosService.fetchAssets(localIdentifiers: deletedIdentifiers)
            guard !restoredAssets.isEmpty else { return }

            let now = Date()
            let upserts = restoredAssets.map { IndexedAsset(from: $0, lastSeenAt: now) }
            try await database.assetRepository.upsert(upserts)
            indexedAssetCount = (try? database.assetRepository.count()) ?? indexedAssetCount
            assetDataVersion &+= 1
            AppLog.shared.info("Reconciled restored assets from Photos: \(upserts.count)")
            notifyIndexingStateChanged()
        } catch {
            AppLog.shared.error("Failed to reconcile restored deleted assets: \(error.localizedDescription)")
        }
    }

    private func refreshArchiveCandidateCount() {
        pendingArchiveCandidateCount = (try? database.assetRepository.countArchiveCandidates(statuses: [.pending, .exporting, .failed])) ?? 0
        failedArchiveCandidateCount = (try? database.assetRepository.countArchiveCandidates(statuses: [.failed])) ?? 0
        NotificationCenter.default.post(name: .librarianArchiveQueueChanged, object: nil)
    }
}

struct ArchiveExportOptions: Sendable {
    var keepOriginalsAlongsideEdits: Bool
    var keepLivePhotos: Bool

    static let `default` = ArchiveExportOptions(
        keepOriginalsAlongsideEdits: false,
        keepLivePhotos: false
    )
}

struct ArchiveExportFailure: Sendable {
    let identifier: String
    let message: String
}

struct ArchiveSendOutcome: Sendable {
    let exportedCount: Int
    let deletedCount: Int
    let failedCount: Int
    let notDeletedCount: Int
    let failures: [ArchiveExportFailure]
}

private struct OsxPhotosReportRow: Decodable {
    let uuid: String
    let exported: Bool?
    let new: Bool?
    let updated: Bool?
    let skipped: Bool?
    let missing: Bool?
    let error: String?
    let userError: String?
    let exiftoolError: String?
    let sidecarUserError: String?

    enum CodingKeys: String, CodingKey {
        case uuid
        case exported
        case new
        case updated
        case skipped
        case missing
        case error
        case userError = "user_error"
        case exiftoolError = "exiftool_error"
        case sidecarUserError = "sidecar_user_error"
    }
}

private struct ArchiveExportTarget {
    let destination: URL
    let localIdentifiers: [String]
}

private struct ArchiveExportGroupResult {
    let destinationPath: String
    let localIdentifiers: [String]
}

private struct ArchiveExportBatchResult {
    let exportedGroups: [ArchiveExportGroupResult]
    let failures: [ArchiveExportFailure]
}

nonisolated private func runOsxPhotosExportBatch(
    targets: [ArchiveExportTarget],
    options: ArchiveExportOptions
) throws -> ArchiveExportBatchResult {
    var exportedGroups: [ArchiveExportGroupResult] = []
    var failures: [ArchiveExportFailure] = []

    for target in targets {
        let destination = target.destination
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let identifierByUUID = Dictionary(grouping: target.localIdentifiers, by: { identifier in
            identifier.split(separator: "/").first.map(String.init) ?? identifier
        })
        let uuidList = Array(identifierByUUID.keys).sorted()
        guard !uuidList.isEmpty else { continue }

        let runToken = UUID().uuidString
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent("librarian-export-\(runToken)", isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let uuidFileURL = tempDir.appendingPathComponent("uuids.txt", isDirectory: false)
        let reportURL = tempDir.appendingPathComponent("report.json", isDirectory: false)
        let exportDBURL = destination.appendingPathComponent(".librarian_osxphotos_export.db", isDirectory: false)
        let uuidFileContents = uuidList.joined(separator: "\n")
        try uuidFileContents.write(to: uuidFileURL, atomically: true, encoding: .utf8)

        var args: [String] = [
            "export",
            destination.path,
            "--uuid-from-file", uuidFileURL.path,
            "--report", reportURL.path,
            "--exportdb", exportDBURL.path,
            "--export-by-date",
            "--jpeg-ext", "jpg",
            "--no-progress",
            "--update-errors",
            "--retry", "2",
            "--exiftool",
            "--update"
        ]
        if !options.keepOriginalsAlongsideEdits {
            args.append("--skip-original-if-edited")
        }
        if !options.keepLivePhotos {
            args.append("--skip-live")
        }
        logInfoAsync("osxphotos command: \(renderShellCommand(arguments: args))")

        var result = runOsxPhotos(arguments: args)
        logInfoAsync("osxphotos exit code: \(result.exitCode)")
        if !result.outputText.isEmpty {
            logInfoMultilineAsync(prefix: "osxphotos output", text: result.outputText)
        }
        if result.exitCode != 0, shouldRetryWithoutExifTool(outputText: result.outputText) {
            args = args.filter { $0 != "--exiftool" }
            logInfoAsync("Retrying osxphotos export without --exiftool")
            result = runOsxPhotos(arguments: args)
            logInfoAsync("osxphotos retry exit code: \(result.exitCode)")
            if !result.outputText.isEmpty {
                logInfoMultilineAsync(prefix: "osxphotos retry output", text: result.outputText)
            }
        }
        if result.exitCode != 0 {
            let message = result.outputText.isEmpty ? "osxphotos export failed (exit \(result.exitCode))" : result.outputText
            failures.append(contentsOf: target.localIdentifiers.map { ArchiveExportFailure(identifier: $0, message: message) })
            try? fileManager.removeItem(at: tempDir)
            continue
        }

        let reportRows: [OsxPhotosReportRow]
        let reportData: Data
        do {
            reportData = try Data(contentsOf: reportURL)
            reportRows = try JSONDecoder().decode([OsxPhotosReportRow].self, from: reportData)
        } catch {
            let message = "osxphotos report parsing failed: \(error.localizedDescription)"
            failures.append(contentsOf: target.localIdentifiers.map { ArchiveExportFailure(identifier: $0, message: message) })
            try? fileManager.removeItem(at: tempDir)
            continue
        }
        if let persistedReportURL = persistExportReportJSON(reportData: reportData, runToken: runToken) {
            logInfoAsync("osxphotos report saved: \(persistedReportURL.path)")
        }
        if let reportJSONString = String(data: reportData, encoding: .utf8), !reportJSONString.isEmpty {
            logInfoMultilineAsync(prefix: "osxphotos report json", text: reportJSONString)
        }

        let rowsByUUID = Dictionary(grouping: reportRows, by: \.uuid)
        var succeededIdentifiers: [String] = []

        for uuid in uuidList {
            let localIdentifiers = identifierByUUID[uuid] ?? []
            guard !localIdentifiers.isEmpty else { continue }
            guard let uuidRows = rowsByUUID[uuid], !uuidRows.isEmpty else {
                failures.append(contentsOf: localIdentifiers.map {
                    ArchiveExportFailure(identifier: $0, message: "osxphotos report did not include this UUID")
                })
                continue
            }

            let errorMessages = uuidRows.compactMap { row -> String? in
                let candidates = [row.error, row.userError, row.exiftoolError, row.sidecarUserError]
                return candidates.first { value in
                    if let value { return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    return false
                } ?? nil
            }

            if !errorMessages.isEmpty {
                let summary = Array(Set(errorMessages)).joined(separator: " | ")
                failures.append(contentsOf: localIdentifiers.map { ArchiveExportFailure(identifier: $0, message: summary) })
                continue
            }

            let missingOnly = uuidRows.allSatisfy { $0.missing == true }
            if missingOnly {
                failures.append(contentsOf: localIdentifiers.map {
                    ArchiveExportFailure(identifier: $0, message: "osxphotos reported item as missing")
                })
                continue
            }

            let hasOutcome = uuidRows.contains { row in
                row.exported == true || row.new == true || row.updated == true || row.skipped == true
            }
            if !hasOutcome {
                failures.append(contentsOf: localIdentifiers.map {
                    ArchiveExportFailure(identifier: $0, message: "osxphotos completed but no export outcome was reported")
                })
                continue
            }

            succeededIdentifiers.append(contentsOf: localIdentifiers)
        }

        try? fileManager.removeItem(at: tempDir)

        if succeededIdentifiers.isEmpty {
            continue
        }

        exportedGroups.append(
            ArchiveExportGroupResult(destinationPath: destination.path, localIdentifiers: Array(Set(succeededIdentifiers)))
        )
    }

    return ArchiveExportBatchResult(exportedGroups: exportedGroups, failures: failures)
}

nonisolated private func shouldRetryWithoutExifTool(outputText: String) -> Bool {
    let lower = outputText.lowercased()
    guard lower.contains("exiftool") else { return false }
    return lower.contains("not found")
        || lower.contains("no such file")
        || lower.contains("could not find")
}

nonisolated private func runOsxPhotos(arguments: [String]) -> (exitCode: Int32, outputText: String) {
    if let bundledExecutable = try? resolveBundledOsxPhotosExecutable() {
        let bundledResult = runProcess(executableURL: bundledExecutable, arguments: arguments)
        if bundledResult.exitCode != 0,
           isPyInstallerSemaphoreError(outputText: bundledResult.outputText),
           let externalExecutable = resolveExternalOsxPhotosExecutable() {
            logInfoAsync("Bundled osxphotos failed with sandboxed PyInstaller semaphore error. Retrying with external osxphotos at \(externalExecutable.path)")
            return runProcess(executableURL: externalExecutable, arguments: arguments)
        }
        return bundledResult
    }

    if let externalExecutable = resolveExternalOsxPhotosExecutable() {
        logInfoAsync("Bundled osxphotos executable not found. Using external osxphotos at \(externalExecutable.path)")
        return runProcess(executableURL: externalExecutable, arguments: arguments)
    }

    return (1, "Bundled osxphotos executable not found in app resources, and no external osxphotos executable was found.")
}

nonisolated private func runProcess(executableURL: URL, arguments: [String]) -> (exitCode: Int32, outputText: String) {
    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments
    let fileManager = FileManager.default
    let logURL = fileManager.temporaryDirectory
        .appendingPathComponent("librarian-osxphotos-\(UUID().uuidString).log", isDirectory: false)
    fileManager.createFile(atPath: logURL.path, contents: nil)
    let outputHandle: FileHandle
    do {
        outputHandle = try FileHandle(forWritingTo: logURL)
    } catch {
        return (1, "Failed to create osxphotos output capture file.")
    }
    process.standardError = outputHandle
    process.standardOutput = outputHandle

    do {
        try process.run()
    } catch {
        try? outputHandle.close()
        try? fileManager.removeItem(at: logURL)
        return (1, "Failed to launch bundled osxphotos executable.")
    }
    process.waitUntilExit()
    try? outputHandle.close()
    let outputData = (try? Data(contentsOf: logURL)) ?? Data()
    try? fileManager.removeItem(at: logURL)
    let outputText = String(data: outputData, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return (process.terminationStatus, outputText)
}

nonisolated private func isPyInstallerSemaphoreError(outputText: String) -> Bool {
    let lower = outputText.lowercased()
    return lower.contains("failed to initialize sync semaphore")
        || (lower.contains("pyi-") && lower.contains("semctl") && lower.contains("operation not permitted"))
}

nonisolated private func resolveBundledOsxPhotosExecutable() throws -> URL {
    let fm = FileManager.default
    let bundle = Bundle.main

    var candidates: [URL] = []
    if let auxiliary = bundle.url(forAuxiliaryExecutable: "osxphotos") {
        candidates.append(auxiliary)
    }
    if let resourceRoot = bundle.resourceURL {
        candidates.append(resourceRoot.appendingPathComponent("Tools/osxphotos", isDirectory: false))
        candidates.append(resourceRoot.appendingPathComponent("osxphotos", isDirectory: false))
    }

    for url in candidates {
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            continue
        }
        if fm.isExecutableFile(atPath: url.path) {
            return url
        }
    }

    throw NSError(domain: "\(AppBrand.identifierPrefix).archive", code: 5, userInfo: [
        NSLocalizedDescriptionKey: "Bundled osxphotos executable not found in app resources."
    ])
}

nonisolated private func resolveExternalOsxPhotosExecutable() -> URL? {
    let fm = FileManager.default
    var candidates = [
        "/opt/homebrew/bin/osxphotos",
        "/usr/local/bin/osxphotos",
        "/usr/bin/osxphotos",
        NSHomeDirectory() + "/.local/bin/osxphotos"
    ].map(URL.init(fileURLWithPath:))

    if let pathURL = resolveOsxPhotosFromPATH() {
        candidates.insert(pathURL, at: 0)
    }

    for url in candidates where fm.isExecutableFile(atPath: url.path) {
        return url
    }
    return nil
}

nonisolated private func resolveOsxPhotosFromPATH() -> URL? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
    process.arguments = ["osxphotos"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do {
        try process.run()
    } catch {
        return nil
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let path = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
        !path.isEmpty
    else {
        return nil
    }
    return URL(fileURLWithPath: path)
}

nonisolated private func archiveRootForExport(_ rootURL: URL) -> URL {
    rootURL.appendingPathComponent("Archive", isDirectory: true)
}

nonisolated private func withArchiveRootAccess<T>(root: URL, operation: () throws -> T) throws -> T {
    let didAccess = root.startAccessingSecurityScopedResource()
    defer {
        if didAccess {
            root.stopAccessingSecurityScopedResource()
        }
    }
    return try operation()
}

nonisolated private func persistExportReportJSON(reportData: Data, runToken: String) -> URL? {
    let fileManager = FileManager.default
    let dir = appSupportDirectory().appendingPathComponent("export_reports", isDirectory: true)
    do {
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let timestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent("osxphotos-report-\(timestamp)-\(runToken).json", isDirectory: false)
        try reportData.write(to: url, options: .atomic)
        return url
    } catch {
        logErrorAsync("Failed to persist osxphotos report: \(error.localizedDescription)")
        return nil
    }
}

nonisolated private func appSupportDirectory() -> URL {
    let appSupport = try? FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
    )
    return (appSupport ?? URL(fileURLWithPath: NSTemporaryDirectory()))
        .appendingPathComponent("com.chrislemarquand.Librarian", isDirectory: true)
}

nonisolated private func renderShellCommand(arguments: [String]) -> String {
    let escaped = arguments.map { arg -> String in
        if arg.contains(where: { $0 == " " || $0 == "\"" || $0 == "'" }) {
            return "\"\(arg.replacingOccurrences(of: "\"", with: "\\\""))\""
        }
        return arg
    }
    return "osxphotos \(escaped.joined(separator: " "))"
}

nonisolated private func logInfoAsync(_ message: String) {
    Task { @MainActor in
        AppLog.shared.info(message)
    }
}

nonisolated private func logErrorAsync(_ message: String) {
    Task { @MainActor in
        AppLog.shared.error(message)
    }
}

nonisolated private func logInfoMultilineAsync(prefix: String, text: String) {
    Task { @MainActor in
        AppLog.shared.infoMultiline(prefix: prefix, text: text)
    }
}

// MARK: - Supporting types

struct IndexingProgress: Equatable {
    enum State: Equatable {
        case idle
        case running(completed: Int, total: Int)
        case failed(String)
    }

    private let state: State

    static let idle = IndexingProgress(state: .idle)
    static func running(completed: Int, total: Int) -> IndexingProgress {
        IndexingProgress(state: .running(completed: completed, total: total))
    }
    static func failed(_ message: String) -> IndexingProgress {
        IndexingProgress(state: .failed(message))
    }

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    var statusText: String {
        switch state {
        case .idle:
            return "Idle"
        case .running(let completed, let total):
            if total > 0 {
                return "Running (\(completed.formatted()) / \(total.formatted()))"
            }
            return "Running"
        case .failed(let message):
            return "Failed: \(message)"
        }
    }

    var fractionComplete: Double? {
        guard case .running(let completed, let total) = state, total > 0 else { return nil }
        return min(max(Double(completed) / Double(total), 0), 1)
    }
}

final class AppLog: @unchecked Sendable {
    static let shared = AppLog()

    private let queue = DispatchQueue(label: "\(AppBrand.identifierPrefix).log")
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private init() {}

    func info(_ message: String) {
        append(level: "INFO", message: message)
    }

    func error(_ message: String) {
        append(level: "ERROR", message: message)
    }

    func infoMultiline(prefix: String, text: String) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.isEmpty {
            info("\(prefix):")
            return
        }
        for line in lines {
            info("\(prefix): \(line)")
        }
    }

    func readRecentLines(maxLines: Int) -> String {
        queue.sync {
            guard let data = try? Data(contentsOf: logURL()),
                  let text = String(data: data, encoding: .utf8) else {
                return ""
            }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.count <= maxLines {
                return text
            }
            return lines.suffix(maxLines).joined(separator: "\n")
        }
    }

    private func append(level: String, message: String) {
        queue.async {
            let line = "[\(self.formatter.string(from: Date()))] [\(level)] \(message)\n"
            let url = self.logURL()
            do {
                let handle: FileHandle
                if FileManager.default.fileExists(atPath: url.path) {
                    handle = try FileHandle(forWritingTo: url)
                    try handle.seekToEnd()
                } else {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                    handle = try FileHandle(forWritingTo: url)
                }
                if let data = line.data(using: .utf8) {
                    try handle.write(contentsOf: data)
                }
                try handle.close()
            } catch {
                // Best-effort logging; ignore write failures.
            }

            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .librarianLogUpdated, object: nil)
            }
        }
    }

    private func logURL() -> URL {
        let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = (appSupport ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("com.chrislemarquand.Librarian", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("librarian.log")
    }
}
