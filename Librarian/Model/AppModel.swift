import Cocoa
import Photos
import Combine

@MainActor
final class AppModel: ObservableObject {

    // MARK: - Services (owned here, accessed by coordinators)

    let photosService: PhotosLibraryService
    let database: DatabaseManager

    // MARK: - Published state

    @Published var photosAuthState: PHAuthorizationStatus = .notDetermined
    @Published var selectedSidebarItem: SidebarItem? = SidebarItem.allItems.first
    @Published var isInspectorCollapsed = false
    @Published var isIndexing = false
    @Published var indexedAssetCount = 0
    @Published var selectedAsset: IndexedAsset?
    @Published var indexingProgress: IndexingProgress = .idle
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
    private var pendingChangeSyncTask: Task<Void, Never>?

    static let galleryColumnRange = 2 ... 9
    private static let galleryGridLevelKey = "ui.gallery.grid.level"

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

        // Load persisted count before requesting Photos access so UI isn't blank
        indexedAssetCount = (try? database.assetRepository.count()) ?? 0
        AppLog.shared.info("Loaded persisted index count: \(indexedAssetCount)")

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

    func setSelectedAsset(_ asset: IndexedAsset?) {
        if selectedAsset?.localIdentifier == asset?.localIdentifier {
            return
        }
        selectedAsset = asset
        NotificationCenter.default.post(name: .librarianSelectionChanged, object: nil)
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
        pendingChangeSyncTask?.cancel()
    }

    private func registerChangeTracking() {
        guard changeTracker == nil else { return }
        let tracker = PhotosChangeTracker { [weak self] in
            Task { @MainActor in
                self?.scheduleChangeSync()
            }
        }
        tracker.register()
        changeTracker = tracker
        AppLog.shared.info("Registered Photos change tracker")
    }

    private func unregisterChangeTracking() {
        pendingChangeSyncTask?.cancel()
        pendingChangeSyncTask = nil
        changeTracker?.unregister()
        changeTracker = nil
    }

    private func scheduleChangeSync() {
        pendingChangeSyncTask?.cancel()
        pendingChangeSyncTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.startBackgroundSync(reason: "photoLibraryDidChange")
        }
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

final class AppLog {
    static let shared = AppLog()

    private let queue = DispatchQueue(label: "com.librarian.app.log")
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
            .appendingPathComponent("com.librarian.app", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("librarian.log")
    }
}
