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

    // MARK: - Init

    init() {
        self.photosService = PhotosLibraryService()
        self.database = DatabaseManager()
    }

    // MARK: - Setup

    func setup() async {
        do {
            try database.open()
        } catch {
            // Database open failure is unrecoverable — surface via overlay
            indexingProgress = .failed(error.localizedDescription)
            return
        }

        // Load persisted count before requesting Photos access so UI isn't blank
        indexedAssetCount = (try? database.assetRepository.count()) ?? 0

        await requestPhotosAccess()
    }

    // MARK: - Photos access

    private func requestPhotosAccess() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        photosAuthState = status

        switch status {
        case .authorized:
            await startInitialIndex()
        case .limited:
            // Limited access: show locked state — full access required
            break
        default:
            break
        }
    }

    func retryPhotosAccess() async {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        photosAuthState = status
        if status == .authorized {
            await startInitialIndex()
        }
    }

    // MARK: - Indexing

    private func startInitialIndex() async {
        guard !isIndexing else { return }
        isIndexing = true
        indexingProgress = .running(completed: 0, total: 0)
        notifyIndexingStateChanged()

        let indexer = AssetIndexer(database: database)
        do {
            for try await progress in indexer.run() {
                indexingProgress = .running(completed: progress.completed, total: progress.total)
                indexedAssetCount = progress.completed
                notifyIndexingStateChanged()
            }
            indexingProgress = .idle
        } catch {
            indexingProgress = .failed(error.localizedDescription)
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
}
