import Cocoa
import Photos
import SwiftUI
import UniformTypeIdentifiers
import SharedUI
import Quartz

enum DisplayAsset {
    case photos(IndexedAsset)
    case archived(ArchivedItem)

    var id: String {
        switch self {
        case .photos(let asset):
            return asset.localIdentifier
        case .archived(let item):
            return "archived:\(item.relativePath)"
        }
    }

    var pixelWidth: Int {
        switch self {
        case .photos(let asset): return asset.pixelWidth
        case .archived(let item): return item.pixelWidth
        }
    }

    var pixelHeight: Int {
        switch self {
        case .photos(let asset): return asset.pixelHeight
        case .archived(let item): return item.pixelHeight
        }
    }

    var photoIdentifier: String? {
        if case .photos(let asset) = self {
            return asset.localIdentifier
        }
        return nil
    }

    var photoAsset: IndexedAsset? {
        if case .photos(let asset) = self {
            return asset
        }
        return nil
    }

    var archivedItem: ArchivedItem? {
        if case .archived(let item) = self {
            return item
        }
        return nil
    }
}

final class ContentController: NSViewController {

    let model: AppModel

    let galleryPageSize = 600
    let loadMoreRemainingThreshold: CGFloat = 1800
    var collectionView: SharedGalleryCollectionView!
    let galleryLayout = SharedGalleryLayout(showsSupplementaryDetail: false)
    var scrollView: NSScrollView!
    let placeholderViewModel = GalleryPlaceholderViewModel()
    var placeholderHostingView: NSView?
    var noticeBar: NoticeBar!
    var scrollTopToNoticeBarConstraint: NSLayoutConstraint!
    var scrollTopToContainerConstraint: NSLayoutConstraint!
    var contextMenuTargetIndices: [Int] = []
    let quickLookCoordinator = QuickLookPanelCoordinator<String>()
    var quickLookSourceFrames: [String: NSRect] = [:]
    var quickLookTempDirectoryURL: URL?
    var quickLookDisplayURLByID: [String: URL] = [:]
    var quickLookUnavailableIDs: Set<String> = []
    var displayAssets: [DisplayAsset] = []
    var isLoadingAssets = false
    var canLoadMoreAssets = true
    var loadGeneration = 0
    var lastLoadedIndexedCount = -1
    var lastLoadedAssetDataVersion = -1
    var lastLoadedSidebarKind: SidebarItem.Kind?
    var zoomRestoreToken = 0
    let pinchZoomAccumulator = PinchZoomAccumulator()
    var selectionAnchorIndex: Int?
    /// Set before a forced reload to restore focus to the next item after the
    /// reloaded data source drops the previously selected items (e.g. Set Aside).
    var pendingPostReloadIndex: Int?
    let archivedIndexer: ArchiveIndexer
    let archiveOrganizer = ArchiveOrganizer()
    let archivedThumbnailService = ArchivedThumbnailService()
    var archivedUnorganizedCount = 0
    var archivedNeedsReviewCount = 0
    var archivedBannerDismissedForLaunch = false
    var isOrganizingArchivedFiles = false

    init(model: AppModel) {
        self.model = model
        self.archivedIndexer = ArchiveIndexer(database: model.database)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = NSView()

        collectionView = SharedGalleryCollectionView()
        galleryLayout.columnCount = model.galleryColumnCount
        collectionView.collectionViewLayout = galleryLayout
        collectionView.backgroundColors = [.clear]
        collectionView.wantsLayer = true
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.register(AssetGridItem.self, forItemWithIdentifier: .assetGridItem)
        collectionView.addGestureRecognizer(
            NSMagnificationGestureRecognizer(target: self, action: #selector(handleMagnification(_:)))
        )
        collectionView.onBackgroundClick = { [weak self] in
            guard let self else { return }
            self.selectionAnchorIndex = nil
            self.model.setSelectedAsset(nil)
        }
        collectionView.onModifiedItemClick = { [weak self] indexPath, modifiers in
            self?.handleModifiedItemClick(indexPath: indexPath, modifiers: modifiers)
        }
        collectionView.onMoveSelection = { [weak self] (direction: SharedUI.MoveCommandDirection, extendingSelection: Bool) in
            self?.moveSelection(direction, extendingSelection: extendingSelection)
        }
        collectionView.contextMenuProvider = { [weak self] indexPath in
            self?.menuForItem(at: indexPath)
        }
        collectionView.allowsShiftExtendedMovement = true
        collectionView.handlesActivateOnReturn = false

        scrollView = NSScrollView()
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        let placeholderHost = NSHostingController(rootView: GalleryPlaceholderView(viewModel: placeholderViewModel))
        placeholderHost.sizingOptions = []
        addChild(placeholderHost)
        let phView = placeholderHost.view
        phView.translatesAutoresizingMaskIntoConstraints = false
        phView.isHidden = true
        container.addSubview(phView)
        placeholderHostingView = phView

        noticeBar = NoticeBar()
        noticeBar.translatesAutoresizingMaskIntoConstraints = false
        noticeBar.isHidden = true
        container.addSubview(noticeBar)

        scrollTopToNoticeBarConstraint = scrollView.topAnchor.constraint(equalTo: noticeBar.bottomAnchor)
        scrollTopToContainerConstraint = scrollView.topAnchor.constraint(equalTo: container.topAnchor)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            noticeBar.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            noticeBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            noticeBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            phView.topAnchor.constraint(equalTo: container.topAnchor),
            phView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            phView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            phView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        scrollTopToContainerConstraint.isActive = true

        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observeScroll()
        loadAssetsIfNeeded(force: true)
        updateOverlay()
        observeModel()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        model.photosService.stopAllThumbnailCaching()
        cleanupQuickLookSession()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func observeModel() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(modelStateChanged),
            name: .librarianIndexingStateChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sidebarSelectionChanged),
            name: .librarianSidebarSelectionChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(galleryZoomChanged),
            name: .librarianGalleryZoomChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(archiveQueueChanged),
            name: .librarianArchiveQueueChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(archiveRootChanged),
            name: .librarianArchiveRootChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(analysisStateChanged),
            name: .librarianAnalysisStateChanged,
            object: nil
        )
    }

    @objc private func analysisStateChanged() {
        if !model.isAnalysing {
            loadAssetsIfNeeded(force: true)
            updateOverlay()
        }
    }

    @objc private func modelStateChanged() {
        if model.photosAuthState == .authorized {
            let shouldForceReload = model.indexedAssetCount != lastLoadedIndexedCount
                || model.assetDataVersion != lastLoadedAssetDataVersion
                || selectedSidebarKind() != lastLoadedSidebarKind
            loadAssetsIfNeeded(force: shouldForceReload)
        }
        updateOverlay()
    }

    @objc private func sidebarSelectionChanged() {
        AppLog.shared.info("Sidebar selection: \(selectedSidebarKind().debugName)")
        loadAssetsIfNeeded(force: true)
        updateOverlay()
    }

    @objc private func galleryZoomChanged() {
        applyColumnCount(model.galleryColumnCount, animated: true)
    }

    @objc private func archiveQueueChanged() {
        if selectedSidebarKind() == .setAsideForArchive || selectedSidebarKind() == .archived {
            loadAssetsIfNeeded(force: true)
        }
    }

    @objc private func archiveRootChanged() {
        archivedBannerDismissedForLaunch = false
        archivedUnorganizedCount = 0
        archivedNeedsReviewCount = 0
        if selectedSidebarKind() == .archived {
            loadAssetsIfNeeded(force: true)
        }
        updateNoticeBar()
    }

    private func loadAssetsIfNeeded(force: Bool) {
        let sidebarKind = selectedSidebarKind()
        // Archive view reads from the local database and filesystem — Photos authorization is not required.
        if sidebarKind != .archived {
            guard model.photosAuthState == .authorized else { return }
        }


        // Archive content is independent of Photos indexing; don't block it.
        if sidebarKind != .archived {
            guard !model.isIndexing else { return }
        }
        let shouldReload = force || displayAssets.isEmpty || lastLoadedSidebarKind != sidebarKind
        if shouldReload {
            resetPagedLoadState(for: sidebarKind)
            fetchPage(sidebarKind: sidebarKind, offset: 0, replaceExisting: true)
        } else {
            loadNextPageIfNeeded()
        }
    }

    private func resetPagedLoadState(for sidebarKind: SidebarItem.Kind) {
        loadGeneration &+= 1
        canLoadMoreAssets = true
        isLoadingAssets = false
        lastLoadedSidebarKind = sidebarKind
    }

    private func fetchPage(sidebarKind: SidebarItem.Kind, offset: Int, replaceExisting: Bool) {
        guard !isLoadingAssets else { return }
        if !replaceExisting && !canLoadMoreAssets {
            return
        }
        guard sidebarKind == selectedSidebarKind() else { return }

        isLoadingAssets = true
        updateOverlay()

        let database = model.database
        let pageSize = self.galleryPageSize
        let generation = loadGeneration
        let archivedIndexer = self.archivedIndexer
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let recentCutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? .distantPast
            let assets: [DisplayAsset]
            var archivedRefreshSummary: ArchiveIndexRefreshSummary?
            switch sidebarKind {
            case .allPhotos:
                let rows = (try? database.assetRepository.fetchForGrid(limit: pageSize, offset: offset)) ?? []
                assets = rows.map { .photos($0) }
            case .recents:
                let rows = (try? database.assetRepository.fetchRecentsForGrid(since: recentCutoff, limit: pageSize, offset: offset)) ?? []
                assets = rows.map { .photos($0) }
            case .favourites:
                let rows = (try? database.assetRepository.fetchFavouritesForGrid(limit: pageSize, offset: offset)) ?? []
                assets = rows.map { .photos($0) }
            case .screenshots:
                let rows = (try? database.assetRepository.fetchScreenshotsForReview(limit: pageSize, offset: offset)) ?? []
                assets = rows.map { .photos($0) }
            case .setAsideForArchive:
                let rows = (try? database.assetRepository.fetchArchiveCandidatesForGrid(limit: pageSize, offset: offset)) ?? []
                assets = rows.map { .photos($0) }
            case .archived:
                if replaceExisting, offset == 0 {
                    archivedRefreshSummary = try? archivedIndexer.refreshIndex()
                }
                let rows = (try? database.assetRepository.fetchArchivedForGrid(limit: pageSize, offset: offset)) ?? []
                assets = rows.map { .archived($0) }
            case .duplicates:
                let rows = (try? database.assetRepository.fetchDuplicatesForGrid(limit: pageSize, offset: offset)) ?? []
                assets = rows.map { .photos($0) }
            case .lowQuality:
                let rows = (try? database.assetRepository.fetchLowQualityForGrid(limit: pageSize, offset: offset)) ?? []
                assets = rows.map { .photos($0) }
            case .receiptsAndDocuments:
                let rows = (try? database.assetRepository.fetchReceiptsAndDocumentsForGrid(limit: pageSize, offset: offset)) ?? []
                assets = rows.map { .photos($0) }
            case .whatsapp:
                let rows = (try? database.assetRepository.fetchWhatsAppForGrid(limit: pageSize, offset: offset)) ?? []
                assets = rows.map { .photos($0) }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                guard generation == self.loadGeneration else {
                    self.isLoadingAssets = false
                    return
                }
                guard sidebarKind == self.selectedSidebarKind() else {
                    self.isLoadingAssets = false
                    return
                }

                if replaceExisting {
                    self.displayAssets = assets
                    if let archivedRefreshSummary {
                        self.archivedUnorganizedCount = archivedRefreshSummary.unorganizedCount
                        self.archivedNeedsReviewCount = archivedRefreshSummary.needsReviewCount
                    }
                    self.model.photosService.stopAllThumbnailCaching()
                    self.collectionView.reloadData()
                    if let index = self.pendingPostReloadIndex {
                        self.pendingPostReloadIndex = nil
                        let count = self.displayAssets.count
                        if count > 0 {
                            let clamped = IndexPath(item: min(index, count - 1), section: 0)
                            self.collectionView.selectItems(at: [clamped], scrollPosition: .nearestHorizontalEdge)
                        }
                    }
                    self.syncModelSelectionFromCollection()
                    if self.collectionView.selectionIndexPaths.isEmpty {
                        self.selectionAnchorIndex = nil
                    }
                } else if !assets.isEmpty {
                    let start = self.displayAssets.count
                    // Guard against a race where the collection view got ahead of displayAssets
                    // (e.g. a force reload fired but reloadData hasn't run yet). Fall back to
                    // a full reload rather than crashing on a bad batch insert.
                    guard self.collectionView.numberOfItems(inSection: 0) == start else {
                        self.displayAssets.append(contentsOf: assets)
                        self.collectionView.reloadData()
                        self.isLoadingAssets = false
                        return
                    }
                    self.displayAssets.append(contentsOf: assets)
                    let indexPaths = Set((start ..< self.displayAssets.count).map { IndexPath(item: $0, section: 0) })
                    self.collectionView.performBatchUpdates({
                        self.collectionView.insertItems(at: indexPaths)
                    })
                }

                self.canLoadMoreAssets = assets.count == pageSize
                self.lastLoadedIndexedCount = self.model.indexedAssetCount
                self.lastLoadedAssetDataVersion = self.model.assetDataVersion
                self.lastLoadedSidebarKind = sidebarKind
                self.isLoadingAssets = false
                if sidebarKind == .archived, replaceExisting {
                    NotificationCenter.default.post(name: .librarianContentDataChanged, object: nil)
                }
                self.updateOverlay()
                self.updateNoticeBar()
                if !replaceExisting, !assets.isEmpty {
                    self.syncModelSelectionFromCollection()
                }
                if self.shouldLoadNextPageForCurrentScrollPosition() {
                    self.loadNextPageIfNeeded()
                }
            }
        }
    }

    private func observeScroll() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollBoundsDidChange),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    @objc private func scrollBoundsDidChange() {
        loadNextPageIfNeeded()
    }

    private func loadNextPageIfNeeded() {
        let sidebarKindForAuth = selectedSidebarKind()
        if sidebarKindForAuth != .archived {
            guard model.photosAuthState == .authorized else { return }
        }
        guard !model.isIndexing else { return }
        guard !isLoadingAssets else { return }
        guard canLoadMoreAssets else { return }

        let sidebarKind = selectedSidebarKind()
        guard shouldLoadNextPageForCurrentScrollPosition() else { return }

        fetchPage(sidebarKind: sidebarKind, offset: displayAssets.count, replaceExisting: false)
    }

    private func shouldLoadNextPageForCurrentScrollPosition() -> Bool {
        guard !displayAssets.isEmpty else { return true }
        guard let documentView = scrollView.documentView else { return false }
        let visibleRect = scrollView.contentView.bounds
        let remaining = documentView.bounds.maxY - visibleRect.maxY
        return remaining <= loadMoreRemainingThreshold
    }

    private func updateOverlay() {
        let sidebarKind = selectedSidebarKind()

        // The archive view reads from the local database — it does not depend on Photos authorization.
        // Show its real state immediately, bypassing the auth-pending placeholder.
        if sidebarKind == .archived {
            if isLoadingAssets, displayAssets.isEmpty {
                showPlaceholder(.loading(title: "Loading", symbolName: symbolName(for: sidebarKind)))
                collectionView.isHidden = true
            } else if !displayAssets.isEmpty {
                hidePlaceholder()
                collectionView.isHidden = false
            } else {
                let empty = emptyContent(for: sidebarKind)
                showPlaceholder(empty.content, actionHandler: empty.actionHandler)
                collectionView.isHidden = true
            }
            updateNoticeBar()
            return
        }

        switch model.photosAuthState {
        case .notDetermined:
            showPlaceholder(.loading(title: "Requesting Access", symbolName: "key.fill"))
            collectionView.isHidden = true
        case .denied, .restricted:
            showPlaceholder(.unavailable(
                title: "Access Required",
                symbolName: "lock.fill",
                description: "Open System Settings to grant Librarian access to your Photos Library."))
            collectionView.isHidden = true
        case .limited:
            showPlaceholder(.unavailable(
                title: "Full Access Required",
                symbolName: "lock.trianglebadge.exclamationmark.fill",
                description: "Librarian needs full access to your Photos Library. Update your privacy settings."))
            collectionView.isHidden = true
        case .authorized:
            if model.isIndexing {
                showPlaceholder(.loading(title: "Updating Catalogue", symbolName: "arrow.triangle.2.circlepath"))
                collectionView.isHidden = true
            } else if isLoadingAssets, displayAssets.isEmpty {
                showPlaceholder(.loading(title: "Loading", symbolName: symbolName(for: sidebarKind)))
                collectionView.isHidden = true
            } else if !displayAssets.isEmpty {
                hidePlaceholder()
                collectionView.isHidden = false
            } else {
                let empty = emptyContent(for: sidebarKind)
                showPlaceholder(empty.content, actionHandler: empty.actionHandler)
                collectionView.isHidden = true
            }
        @unknown default:
            hidePlaceholder()
        }
        updateNoticeBar()
    }

    private func showPlaceholder(_ content: GalleryPlaceholderContent, actionHandler: (() -> Void)? = nil) {
        placeholderViewModel.content = content
        placeholderViewModel.actionHandler = actionHandler
        placeholderHostingView?.isHidden = false
    }

    private func hidePlaceholder() {
        placeholderViewModel.content = nil
        placeholderViewModel.actionHandler = nil
        placeholderHostingView?.isHidden = true
    }

    private func symbolName(for kind: SidebarItem.Kind) -> String {
        switch kind {
        case .allPhotos: return "photo.on.rectangle.angled"
        case .recents: return "clock"
        case .favourites: return "heart"
        case .screenshots: return "camera.viewfinder"
        case .setAsideForArchive: return "tray.full"
        case .archived: return "archivebox"
        case .duplicates: return "photo.on.rectangle"
        case .lowQuality: return "wand.and.stars.inverse"
        case .receiptsAndDocuments: return "doc.text"
        case .whatsapp: return "message"
        }
    }

    private struct EmptyContentResult {
        let content: GalleryPlaceholderContent
        let actionHandler: (() -> Void)?

        init(_ content: GalleryPlaceholderContent, actionHandler: (() -> Void)? = nil) {
            self.content = content
            self.actionHandler = actionHandler
        }
    }

    private func emptyContent(for kind: SidebarItem.Kind) -> EmptyContentResult {
        switch kind {
        case .allPhotos:
            let description = model.indexedAssetCount > 0
                ? "No photos match the current filters."
                : "Your Photos Library appears to be empty."
            return EmptyContentResult(.unavailable(title: "No Photos", symbolName: "photo.on.rectangle.angled", description: description))
        case .recents:
            return EmptyContentResult(.unavailable(title: "No Recent Photos", symbolName: "clock", description: "No photos from the past 30 days."))
        case .favourites:
            return EmptyContentResult(.unavailable(title: "No Favourites", symbolName: "heart", description: "Mark photos as favourites in Photos to see them here."))
        case .screenshots:
            return EmptyContentResult(.unavailable(title: "No Screenshots", symbolName: "camera.viewfinder", description: "All screenshots have been reviewed."))
        case .setAsideForArchive:
            return EmptyContentResult(.unavailable(title: "Nothing Set Aside", symbolName: "tray.full", description: "Photos you set aside for archiving will appear here."))
        case .archived:
            let availability = model.refreshArchiveRootAvailability()
            switch availability {
            case .notConfigured:
                return EmptyContentResult(.unavailable(
                    title: "No Archive Destination",
                    symbolName: "externaldrive.badge.questionmark",
                    description: "Set an Archive destination in Settings to view archived photos."
                ))
            case .unavailable:
                return EmptyContentResult(.unavailable(
                    title: "Archive Missing",
                    symbolName: "externaldrive.badge.exclamationmark",
                    description: "Your Archive can’t be found — it may have been moved or renamed. Use Settings to locate it."
                ))
            case .readOnly, .permissionDenied:
                return EmptyContentResult(.unavailable(
                    title: "Archive Unavailable",
                    symbolName: "externaldrive.badge.exclamationmark",
                    description: "\(availability.userVisibleDescription) Update the destination in Settings or reconnect the drive."
                ))
            case .available:
                break
            }
            return EmptyContentResult(.unavailable(title: "No Archive Photos", symbolName: "archivebox", description: "Archive photos will appear here after export."))
        case .duplicates:
            if model.isAnalysing {
                return EmptyContentResult(.unavailable(title: "No Duplicates", symbolName: "photo.on.rectangle", description: "Items will appear here when analysis is complete."))
            } else if !model.analysisHasRunBefore {
                return EmptyContentResult(
                    .action(title: "No Duplicates", symbolName: "photo.on.rectangle", description: "Analyse your Photos Library to find items for this box.", actionTitle: "Analyse Now"),
                    actionHandler: { [weak self] in Task { await self?.model.runLibraryAnalysis() } }
                )
            }
            return EmptyContentResult(.unavailable(title: "No Duplicates", symbolName: "photo.on.rectangle", description: "No duplicate or near-duplicate photos found."))
        case .lowQuality:
            if model.isAnalysing {
                return EmptyContentResult(.unavailable(title: "No Low Quality Photos", symbolName: "wand.and.stars.inverse", description: "Items will appear here when analysis is complete."))
            } else if !model.analysisHasRunBefore {
                return EmptyContentResult(
                    .action(title: "No Low Quality Photos", symbolName: "wand.and.stars.inverse", description: "Analyse your Photos Library to find items for this box.", actionTitle: "Analyse Now"),
                    actionHandler: { [weak self] in Task { await self?.model.runLibraryAnalysis() } }
                )
            }
            return EmptyContentResult(.unavailable(title: "No Low Quality Photos", symbolName: "wand.and.stars.inverse", description: "No photos with a low quality score found."))
        case .receiptsAndDocuments:
            if model.isAnalysing {
                return EmptyContentResult(.unavailable(title: "No Documents", symbolName: "doc.text", description: "Items will appear here when analysis is complete."))
            } else if !model.analysisHasRunBefore {
                return EmptyContentResult(
                    .action(title: "No Documents", symbolName: "doc.text", description: "Analyse your Photos Library to find items for this box.", actionTitle: "Analyse Now"),
                    actionHandler: { [weak self] in Task { await self?.model.runLibraryAnalysis() } }
                )
            }
            return EmptyContentResult(.unavailable(title: "No Documents", symbolName: "doc.text", description: "No document-focused photos found."))
        case .whatsapp:
            return EmptyContentResult(.unavailable(title: "No WhatsApp Media", symbolName: "message", description: "No WhatsApp media found."))
        }
    }

    func thumbnailTargetSize() -> CGSize {
        let size = NSSize(width: galleryLayout.tileSide, height: galleryLayout.tileSide)
        let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    func thumbnailTileSide() -> CGFloat {
        galleryLayout.tileSide
    }

    private func applyColumnCount(_ targetColumnCount: Int, animated: Bool) {
        guard targetColumnCount > 0 else { return }
        guard galleryLayout.columnCount != targetColumnCount else { return }

        zoomRestoreToken += 1
        let restoreToken = zoomRestoreToken
        let selectedItemIndex: Int? = {
            guard let selectedIdentifier = model.selectedAsset?.localIdentifier else { return nil }
            return displayAssets.firstIndex(where: { $0.photoIdentifier == selectedIdentifier })
        }()
        let anchor = GalleryZoomTransitionSupport.captureAnchor(
            selectedItemIndex: selectedItemIndex,
            collectionView: collectionView
        )
        let canAnimate = animated
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            && view.window != nil
            && collectionView.numberOfItems(inSection: 0) > 0

        if canAnimate {
            applyFadeTransition(to: collectionView)
        }

        galleryLayout.columnCount = targetColumnCount
        galleryLayout.invalidateLayout()
        view.layoutSubtreeIfNeeded()
        collectionView.visibleItems().forEach { item in
            (item as? AssetGridItem)?.updateTileSide(galleryLayout.tileSide, animated: canAnimate)
        }
        GalleryZoomTransitionSupport.restoreAnchor(
            anchor,
            token: restoreToken,
            currentToken: { [weak self] in self?.zoomRestoreToken ?? -1 },
            collectionView: collectionView
        )
    }

    private func applyFadeTransition(to view: NSView) {
        guard let layer = view.layer else { return }
        layer.removeAnimation(forKey: "galleryZoomFade")
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let transition = CATransition()
        transition.type = .fade
        transition.duration = 0.16
        transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(transition, forKey: "galleryZoomFade")
    }

    @objc
    private func handleMagnification(_ gesture: NSMagnificationGestureRecognizer) {
        pinchZoomAccumulator.handle(gesture) { [weak self] step in
            guard let self else { return }
            switch step {
            case .zoomIn:
                self.model.adjustGalleryGridLevel(by: -1)
            case .zoomOut:
                self.model.adjustGalleryGridLevel(by: 1)
            }
        }
    }

    private func selectedSidebarKind() -> SidebarItem.Kind {
        model.selectedSidebarItem?.kind ?? .allPhotos
    }


    private func updateNoticeBar() {
        let state = noticeBar.state
        let sidebarKind = selectedSidebarKind()

        // Determine what the notice bar should show.
        if sidebarKind == .archived && (archivedUnorganizedCount > 0 || archivedNeedsReviewCount > 0) && !archivedBannerDismissedForLaunch {
            if archivedUnorganizedCount > 0 && archivedNeedsReviewCount > 0 {
                state.message = "\(archivedUnorganizedCount.formatted()) items to organise. \(archivedNeedsReviewCount.formatted()) in Needs Review."
            } else if archivedUnorganizedCount > 0 {
                state.message = "\(archivedUnorganizedCount.formatted()) items to organise in your Archive."
            } else {
                state.message = "\(archivedNeedsReviewCount.formatted()) items are in Needs Review."
            }
            state.primaryAction = isOrganizingArchivedFiles ? nil : NoticeBarAction(title: "Review Import…") { [weak self] in
                guard let self else { return }
                guard let archiveTreeRoot = ArchiveSettings.currentArchiveTreeRootURL() else { return }
                guard let splitVC = self.resolveMainSplitViewController() else { return }
                splitVC.presentArchiveImportSheet(mode: .pathBDetected(candidates: [archiveTreeRoot]))
                self.archivedBannerDismissedForLaunch = true
                self.updateNoticeBar()
            }
            state.secondaryAction = isOrganizingArchivedFiles ? nil : NoticeBarAction(title: "Not Now") { [weak self] in
                self?.archivedBannerDismissedForLaunch = true
                self?.updateNoticeBar()
            }
            state.isVisible = true
        } else if [.lowQuality, .duplicates, .receiptsAndDocuments].contains(sidebarKind)
                    && model.isAnalysing
                    && !displayAssets.isEmpty {
            state.message = "Analysing your Photos Library — more items may appear."
            state.primaryAction = nil
            state.secondaryAction = nil
            state.isVisible = true
        } else {
            state.isVisible = false
            state.primaryAction = nil
            state.secondaryAction = nil
        }

        noticeBar.syncVisibility()

        // Switch scroll-top constraints atomically.
        NSLayoutConstraint.deactivate([
            scrollTopToNoticeBarConstraint,
            scrollTopToContainerConstraint,
        ])
        NSLayoutConstraint.activate([
            state.isVisible ? scrollTopToNoticeBarConstraint : scrollTopToContainerConstraint
        ])
    }

    func openSelectionInPhotos() {
        guard let selectedIndex = collectionView.selectionIndexPaths.first?.item,
              selectedIndex >= 0,
              selectedIndex < displayAssets.count else { return }
        guard let localIdentifier = displayAssets[selectedIndex].photoIdentifier else { return }
        model.photosService.openInPhotos(localIdentifier: localIdentifier)
    }

    func quickLookSelection() {
        let selectedIndices = collectionView.selectionIndexPaths
            .map(\.item)
            .filter { $0 >= 0 && $0 < displayAssets.count }
            .sorted()
        guard !selectedIndices.isEmpty else { return }

        let selectedAssets = selectedIndices.map { displayAssets[$0] }
        let sourceIDs = selectedAssets.map(\.id)
        let focusedID = selectedAssets.first?.id
        updateQuickLookArtifacts()

        // Pre-materialize Quick Look URLs: archived items resolve instantly,
        // photo assets need image data which we do off the main thread.
        let photosToMaterialize = selectedAssets.compactMap { asset -> String? in
            if quickLookDisplayURLByID[asset.id] != nil { return nil }
            if quickLookUnavailableIDs.contains(asset.id) { return nil }
            guard let photoID = asset.photoIdentifier else {
                // Archived asset — resolve synchronously (just a file path check)
                _ = quickLookDisplayURL(for: asset)
                return nil
            }
            return photoID
        }

        if photosToMaterialize.isEmpty {
            presentQuickLookPanel(sourceIDs: sourceIDs, focusedID: focusedID, selectedAssets: selectedAssets)
        } else {
            Task {
                await materializePhotoAssetsForQuickLook(localIdentifiers: photosToMaterialize)
                presentQuickLookPanel(sourceIDs: sourceIDs, focusedID: focusedID, selectedAssets: selectedAssets)
            }
        }
    }

    private func presentQuickLookPanel(sourceIDs: [String], focusedID: String?, selectedAssets: [DisplayAsset]) {
        var availableCount = 0
        for asset in selectedAssets {
            if quickLookDisplayURL(for: asset) != nil {
                availableCount += 1
            }
        }
        guard availableCount > 0 else {
            showQuickLookUnavailableAlert()
            return
        }

        quickLookCoordinator.present(
            sourceItems: sourceIDs,
            focusedItem: focusedID,
            displayURLForSource: { [weak self] sourceID in
                guard let self,
                      let index = self.displayAssets.firstIndex(where: { $0.id == sourceID })
                else { return nil }
                return self.quickLookDisplayURL(for: self.displayAssets[index])
            },
            sourceFrameForSource: { [weak self] sourceID in
                self?.quickLookSourceFrames[sourceID]
            },
            onWillClose: { [weak self] in
                self?.cleanupQuickLookSession()
            },
            itemTitle: ""
        )
    }

    private func quickLookDisplayURL(for asset: DisplayAsset) -> URL? {
        if let cached = quickLookDisplayURLByID[asset.id], FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
        let resolved: URL?
        switch asset {
        case .archived(let item):
            let url = URL(fileURLWithPath: item.absolutePath)
            resolved = FileManager.default.fileExists(atPath: url.path) ? url : nil
        case .photos(let indexed):
            if quickLookUnavailableIDs.contains(indexed.localIdentifier) {
                resolved = nil
            } else {
                resolved = materializePhotoAssetForQuickLook(localIdentifier: indexed.localIdentifier)
                if resolved == nil {
                    quickLookUnavailableIDs.insert(indexed.localIdentifier)
                }
            }
        }
        if let resolved {
            quickLookDisplayURLByID[asset.id] = resolved
        }
        return resolved
    }

    /// Pre-materializes photo assets for Quick Look off the main thread.
    private func materializePhotoAssetsForQuickLook(localIdentifiers: [String]) async {
        let directoryURL = ensureQuickLookTempDirectory()
        guard let directoryURL else { return }

        let assets = model.photosService.fetchAssetsKeyed(localIdentifiers: localIdentifiers)
        await withTaskGroup(of: (String, URL?).self) { group in
            for (identifier, asset) in assets {
                guard asset.mediaType == .image else { continue }
                group.addTask {
                    let url = await self.materializeSinglePhotoAsset(asset: asset, directoryURL: directoryURL)
                    return (identifier, url)
                }
            }
            for await (identifier, url) in group {
                if let url {
                    // Build the DisplayAsset ID the same way quickLookDisplayURL does
                    let displayID = identifier
                    quickLookDisplayURLByID[displayID] = url
                } else {
                    quickLookUnavailableIDs.insert(identifier)
                }
            }
        }
    }

    private nonisolated func materializeSinglePhotoAsset(asset: PHAsset, directoryURL: URL) async -> URL? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isSynchronous = false
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .none
            options.isNetworkAccessAllowed = false

            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, dataUTI, _, info in
                if let isInCloud = info?[PHImageResultIsInCloudKey] as? Bool, isInCloud, data == nil {
                    continuation.resume(returning: nil)
                    return
                }
                guard let data, !data.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }

                let ext: String = {
                    if let uti = dataUTI, let type = UTType(uti), let preferred = type.preferredFilenameExtension {
                        return preferred
                    }
                    return "jpg"
                }()
                let outputURL = directoryURL.appendingPathComponent("\(UUID().uuidString).\(ext)", isDirectory: false)
                do {
                    try data.write(to: outputURL, options: .atomic)
                    continuation.resume(returning: outputURL)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Legacy synchronous path used only by the QL coordinator's displayURLForSource callback.
    private func materializePhotoAssetForQuickLook(localIdentifier: String) -> URL? {
        guard let asset = model.photosService.fetchAsset(localIdentifier: localIdentifier) else { return nil }
        if asset.mediaType != .image { return nil }
        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .none
        options.isNetworkAccessAllowed = false

        var resultData: Data?
        var resultUTI: String?
        PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, dataUTI, _, info in
            if let isInCloud = info?[PHImageResultIsInCloudKey] as? Bool, isInCloud, data == nil {
                resultData = nil
                return
            }
            resultData = data
            resultUTI = dataUTI
        }

        guard let data = resultData, !data.isEmpty else { return nil }
        let directoryURL = ensureQuickLookTempDirectory()
        guard let directoryURL else { return nil }

        let ext: String = {
            if let uti = resultUTI, let type = UTType(uti), let preferred = type.preferredFilenameExtension {
                return preferred
            }
            return "jpg"
        }()
        let outputURL = directoryURL.appendingPathComponent("\(UUID().uuidString).\(ext)", isDirectory: false)
        do {
            try data.write(to: outputURL, options: .atomic)
            return outputURL
        } catch {
            AppLog.shared.error("Failed to materialize Quick Look file: \(error.localizedDescription)")
            return nil
        }
    }

    private func ensureQuickLookTempDirectory() -> URL? {
        if let existing = quickLookTempDirectoryURL { return existing }
        let created = FileManager.default.temporaryDirectory
            .appendingPathComponent("librarian-quicklook", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: created, withIntermediateDirectories: true)
        quickLookTempDirectoryURL = created
        return created
    }

    private func cleanupQuickLookSession() {
        quickLookDisplayURLByID.removeAll()
        quickLookUnavailableIDs.removeAll()
        if let dir = quickLookTempDirectoryURL {
            try? FileManager.default.removeItem(at: dir)
        }
        quickLookTempDirectoryURL = nil
    }

    private func showQuickLookUnavailableAlert() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Quick Look Unavailable"
        alert.informativeText = "Selected photos aren’t available locally. Download iCloud-only photos first."
        alert.addButton(withTitle: "OK")
        alert.runSheetOrModal(for: view.window) { _ in }
    }

    var hasSelectedArchiveItems: Bool {
        !selectedArchiveURLs().isEmpty
    }

    func revealArchiveSelectionInFinder() {
        let urls = selectedArchiveURLs()
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    private func selectedArchiveURLs() -> [URL] {
        collectionView.selectionIndexPaths
            .map(\.item)
            .filter { $0 >= 0 && $0 < displayAssets.count }
            .compactMap { displayAssets[$0].archivedItem }
            .map { URL(fileURLWithPath: $0.absolutePath) }
    }

    @objc private func markScreenshotsArchiveCandidate() {
        if selectedSidebarKind() == .screenshots {
            applyScreenshotDecision(.archiveCandidate)
        } else {
            queueSelectedAssetsForArchive()
        }
    }

    private func applyScreenshotDecision(_ decision: ScreenshotReviewDecision) {
        guard selectedSidebarKind() == .screenshots else { return }
        let selectedAssets = selectedAssetIdentifiers()
        guard !selectedAssets.isEmpty else { return }
        do {
            try model.database.assetRepository.setScreenshotDecision(identifiers: selectedAssets, decision: decision)
            if decision == .archiveCandidate {
                try model.queueAssetsForArchive(localIdentifiers: selectedAssets)
            }
            AppLog.shared.info("Marked \(selectedAssets.count) screenshot(s) as \(decision.rawValue)")
            let action = decision == .archiveCandidate ? "Set Aside" : "Keep"
            model.setStatusMessage("\(action): \(selectedAssets.count) screenshots.", autoClearAfterSuccess: true)
            collectionView.deselectAll(nil)
            model.setSelectedAsset(nil)
            loadAssetsIfNeeded(force: true)
        } catch {
            AppLog.shared.error("Failed to set screenshot decision: \(error.localizedDescription)")
            model.setStatusMessage("Couldn’t update screenshot decisions. \(error.localizedDescription)")
        }
    }

    private func selectedAssetIdentifiers() -> [String] {
        collectionView.selectionIndexPaths
            .map(\.item)
            .filter { $0 >= 0 && $0 < displayAssets.count }
            .sorted()
            .compactMap { displayAssets[$0].photoIdentifier }
    }

    var hasSelectedAssets: Bool {
        !selectedAssetIdentifiers().isEmpty
    }

    func selectAllVisibleAssets() {
        guard !displayAssets.isEmpty else {
            collectionView.deselectAll(nil)
            model.setSelectedAsset(nil)
            return
        }
        let all = Set(displayAssets.indices.map { IndexPath(item: $0, section: 0) })
        guard collectionView.selectionIndexPaths != all else { return }
        collectionView.selectionIndexPaths = all
        syncModelSelectionFromCollection()
    }

    func focusContentPane() {
        guard let window = view.window else { return }
        window.makeFirstResponder(collectionView)
    }

    func queueSelectedAssetsForArchive() {
        let identifiers = selectedAssetIdentifiers()
        guard !identifiers.isEmpty else { return }
        let lowestSelectedIndex = collectionView.selectionIndexPaths.map(\.item).min()
        do {
            try model.queueAssetsForArchive(localIdentifiers: identifiers)
            AppLog.shared.info("Set aside \(identifiers.count) selected photos for archive")
            model.setStatusMessage("Set aside \(identifiers.count) photos.", autoClearAfterSuccess: true)
            collectionView.deselectAll(nil)
            model.setSelectedAsset(nil)
            pendingPostReloadIndex = lowestSelectedIndex
            loadAssetsIfNeeded(force: true)
        } catch {
            AppLog.shared.error("Failed to set aside photos for archive: \(error.localizedDescription)")
            model.setStatusMessage("Couldn’t set aside photos. \(error.localizedDescription)")
        }
    }

    var canPutBackFromArchiveQueue: Bool {
        selectedSidebarKind() == .setAsideForArchive && hasSelectedAssets
    }

    func putBackSelectedArchiveAssets() {
        guard selectedSidebarKind() == .setAsideForArchive else { return }
        let identifiers = selectedAssetIdentifiers()
        guard !identifiers.isEmpty else { return }
        do {
            try model.unqueueAssetsForArchive(localIdentifiers: identifiers)
            collectionView.deselectAll(nil)
            model.setSelectedAsset(nil)
            loadAssetsIfNeeded(force: true)
            AppLog.shared.info("Put back \(identifiers.count) items from archive set-aside queue")
            model.setStatusMessage("Put back \(identifiers.count) photos.", autoClearAfterSuccess: true)
        } catch {
            AppLog.shared.error("Failed to put back selected archive items: \(error.localizedDescription)")
            model.setStatusMessage("Couldn’t put back selected photos. \(error.localizedDescription)")
        }
    }

    private func menuForItem(at indexPath: IndexPath) -> NSMenu? {
        let clickedIndex = indexPath.item
        guard clickedIndex >= 0, clickedIndex < displayAssets.count else { return nil }

        var selectedIndices = Set(collectionView.selectionIndexPaths.map(\.item).filter { $0 >= 0 && $0 < displayAssets.count })
        let orderedIndices = Array(displayAssets.indices)

        if !selectedIndices.contains(clickedIndex) {
            collectionView.selectionIndexPaths = [IndexPath(item: clickedIndex, section: 0)]
            syncModelSelectionFromCollection()
            selectedIndices = [clickedIndex]
        }

        contextMenuTargetIndices = ContextMenuSupport.targetSelection(
            clicked: clickedIndex,
            selected: selectedIndices,
            orderedItems: orderedIndices
        )

        let targetAssets = contextMenuTargetIndices
            .filter { $0 >= 0 && $0 < displayAssets.count }
            .map { displayAssets[$0] }
        guard !targetAssets.isEmpty else { return nil }

        let hasPhotoTargets = targetAssets.contains { $0.photoIdentifier != nil }
        let hasArchiveTargets = targetAssets.contains { $0.archivedItem != nil }
        let kind = selectedSidebarKind()

        let menu = NSMenu()
        menu.autoenablesItems = false

        switch kind {
        case .setAsideForArchive:
            menu.addItem(ContextMenuSupport.makeMenuItem(
                title: "Send to Archive…",
                action: #selector(sendSelectedToArchiveFromContextMenu(_:)),
                target: self,
                symbolName: "archivebox",
                isEnabled: hasPhotoTargets && !model.isSendingArchive
            ))
            menu.addItem(ContextMenuSupport.makeMenuItem(
                title: "Put Back",
                action: #selector(putBackFromContextMenu(_:)),
                target: self,
                symbolName: "arrow.uturn.left.circle",
                isEnabled: hasPhotoTargets
            ))
            menu.addItem(.separator())
            menu.addItem(ContextMenuSupport.makeMenuItem(
                title: "Open in Photos",
                action: #selector(openInPhotosFromContextMenu(_:)),
                target: self,
                symbolName: "photo",
                isEnabled: hasPhotoTargets
            ))
            menu.addItem(ContextMenuSupport.makeMenuItem(
                title: "Quick Look",
                action: #selector(quickLookFromContextMenu(_:)),
                target: self,
                symbolName: "eye",
                isEnabled: hasPhotoTargets
            ))

        case .archived:
            menu.addItem(ContextMenuSupport.makeMenuItem(
                title: "Reveal in Finder",
                action: #selector(revealInFinderFromContextMenu(_:)),
                target: self,
                symbolName: "folder",
                isEnabled: hasArchiveTargets
            ))
            menu.addItem(.separator())
            menu.addItem(ContextMenuSupport.makeMenuItem(
                title: "Open in Photos",
                action: #selector(openInPhotosFromContextMenu(_:)),
                target: self,
                symbolName: "photo",
                isEnabled: false
            ))
            menu.addItem(ContextMenuSupport.makeMenuItem(
                title: "Quick Look",
                action: #selector(quickLookFromContextMenu(_:)),
                target: self,
                symbolName: "eye",
                isEnabled: hasArchiveTargets
            ))

        case .allPhotos, .recents, .favourites:
            menu.addItem(ContextMenuSupport.makeMenuItem(
                title: "Set Aside",
                action: #selector(setAsideFromContextMenu(_:)),
                target: self,
                symbolName: "tray.and.arrow.down",
                isEnabled: hasPhotoTargets && !model.isSendingArchive
            ))
            menu.addItem(.separator())
            menu.addItem(ContextMenuSupport.makeMenuItem(
                title: "Open in Photos",
                action: #selector(openInPhotosFromContextMenu(_:)),
                target: self,
                symbolName: "photo",
                isEnabled: hasPhotoTargets
            ))
            menu.addItem(ContextMenuSupport.makeMenuItem(
                title: "Quick Look",
                action: #selector(quickLookFromContextMenu(_:)),
                target: self,
                symbolName: "eye",
                isEnabled: hasPhotoTargets
            ))

        case .screenshots, .duplicates, .lowQuality, .receiptsAndDocuments, .whatsapp:
            menu.addItem(ContextMenuSupport.makeMenuItem(
                title: "Set Aside",
                action: #selector(setAsideFromContextMenu(_:)),
                target: self,
                symbolName: "tray.and.arrow.down",
                isEnabled: hasPhotoTargets && !model.isSendingArchive
            ))
            menu.addItem(.separator())
            menu.addItem(ContextMenuSupport.makeMenuItem(
                title: "Open in Photos",
                action: #selector(openInPhotosFromContextMenu(_:)),
                target: self,
                symbolName: "photo",
                isEnabled: hasPhotoTargets
            ))
            menu.addItem(ContextMenuSupport.makeMenuItem(
                title: "Quick Look",
                action: #selector(quickLookFromContextMenu(_:)),
                target: self,
                symbolName: "eye",
                isEnabled: hasPhotoTargets
            ))

        }

        return menu.items.isEmpty ? nil : menu
    }

    private func contextMenuPhotoIdentifiers() -> [String] {
        contextMenuTargetIndices
            .filter { $0 >= 0 && $0 < displayAssets.count }
            .compactMap { displayAssets[$0].photoIdentifier }
    }

    private func contextMenuArchiveURLs() -> [URL] {
        contextMenuTargetIndices
            .filter { $0 >= 0 && $0 < displayAssets.count }
            .compactMap { displayAssets[$0].archivedItem }
            .map { URL(fileURLWithPath: $0.absolutePath) }
    }

    @objc
    private func setAsideFromContextMenu(_: Any?) {
        let identifiers = contextMenuPhotoIdentifiers()
        guard !identifiers.isEmpty else { return }
        do {
            try model.queueAssetsForArchive(localIdentifiers: identifiers)
            AppLog.shared.info("Set aside \(identifiers.count) selected photos for archive")
            model.setStatusMessage("Set aside \(identifiers.count) photos.", autoClearAfterSuccess: true)
            collectionView.deselectAll(nil)
            model.setSelectedAsset(nil)
            loadAssetsIfNeeded(force: true)
        } catch {
            AppLog.shared.error("Failed to set aside photos for archive: \(error.localizedDescription)")
            model.setStatusMessage("Couldn’t set aside photos. \(error.localizedDescription)")
        }
    }

    @objc
    private func putBackFromContextMenu(_: Any?) {
        guard selectedSidebarKind() == .setAsideForArchive else { return }
        let identifiers = contextMenuPhotoIdentifiers()
        guard !identifiers.isEmpty else { return }
        do {
            try model.unqueueAssetsForArchive(localIdentifiers: identifiers)
            collectionView.deselectAll(nil)
            model.setSelectedAsset(nil)
            loadAssetsIfNeeded(force: true)
            AppLog.shared.info("Put back \(identifiers.count) items from archive set-aside queue")
            model.setStatusMessage("Put back \(identifiers.count) photos.", autoClearAfterSuccess: true)
        } catch {
            AppLog.shared.error("Failed to put back selected archive items: \(error.localizedDescription)")
            model.setStatusMessage("Couldn’t put back selected photos. \(error.localizedDescription)")
        }
    }

    @objc
    private func openInPhotosFromContextMenu(_: Any?) {
        guard let firstIdentifier = contextMenuPhotoIdentifiers().first else { return }
        model.photosService.openInPhotos(localIdentifier: firstIdentifier)
    }

    @objc
    private func revealInFinderFromContextMenu(_: Any?) {
        let urls = contextMenuArchiveURLs()
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @objc
    private func quickLookFromContextMenu(_: Any?) {
        quickLookSelection()
    }

    @objc
    private func sendSelectedToArchiveFromContextMenu(_: Any?) {
        guard selectedSidebarKind() == .setAsideForArchive else { return }
        let identifiers = contextMenuPhotoIdentifiers()
        guard !identifiers.isEmpty else { return }
        guard let splitVC = resolveMainSplitViewController() else { return }
        splitVC.sendSelectedToArchive(localIdentifiers: identifiers)
    }

    private func resolveMainSplitViewController() -> MainSplitViewController? {
        var node: NSViewController? = self
        while let current = node {
            if let split = current as? MainSplitViewController {
                return split
            }
            node = current.parent
        }
        return view.window?.contentViewController as? MainSplitViewController
    }

    func refreshDisplayedAssets() {
        loadAssetsIfNeeded(force: true)
    }

}
