import Cocoa
import Photos
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import SharedUI
import CryptoKit

private enum DisplayAsset {
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
}

final class ContentController: NSViewController {

    let model: AppModel

    private let galleryPageSize = 600
    private let loadMoreRemainingThreshold: CGFloat = 1800
    private var collectionView: SharedGalleryCollectionView!
    private let galleryLayout = SharedGalleryLayout(showsSupplementaryDetail: false)
    private var scrollView: NSScrollView!
    private let placeholderViewModel = GalleryPlaceholderViewModel()
    private var placeholderHostingView: NSView?
    private var screenshotActionBar: NSView!
    private var screenshotSelectionLabel: NSTextField!
    private var screenshotKeepButton: NSButton!
    private var screenshotArchiveButton: NSButton!
    private var screenshotActionBarHeightConstraint: NSLayoutConstraint!
    private var archivedNoticeBar: NSView!
    private var archivedNoticeLabel: NSTextField!
    private var archivedNoticeActionButton: NSButton!
    private var archivedNoticeDismissButton: NSButton!
    private var archivedNoticeBarHeightConstraint: NSLayoutConstraint!
    private var scrollTopToArchivedNoticeConstraint: NSLayoutConstraint!
    private var scrollTopToContainerConstraint: NSLayoutConstraint!
    private var logPane: NSView!
    private var logTextView: NSTextView!
    private let logPlaceholderViewModel = GalleryPlaceholderViewModel()
    private var logPlaceholderHostingView: NSView?
    private var displayAssets: [DisplayAsset] = []
    private var isLoadingAssets = false
    private var canLoadMoreAssets = true
    private var loadGeneration = 0
    private var lastLoadedIndexedCount = -1
    private var lastLoadedAssetDataVersion = -1
    private var lastLoadedSidebarKind: SidebarItem.Kind?
    private var zoomRestoreToken = 0
    private let pinchZoomAccumulator = PinchZoomAccumulator()
    private var selectionAnchorIndex: Int?
    private let archivedIndexer: ArchiveIndexer
    private let archiveOrganizer = ArchiveOrganizer()
    private let archivedThumbnailService = ArchivedThumbnailService()
    private var archivedUnorganizedCount = 0
    private var archivedBannerDismissedForLaunch = false
    private var isOrganizingArchivedFiles = false

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
            self.updateScreenshotActionBarState()
        }
        collectionView.onModifiedItemClick = { [weak self] indexPath, modifiers in
            self?.handleModifiedItemClick(indexPath: indexPath, modifiers: modifiers)
        }
        collectionView.onMoveSelection = { [weak self] (direction: SharedUI.MoveCommandDirection, extendingSelection: Bool) in
            self?.moveSelection(direction, extendingSelection: extendingSelection)
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

        screenshotActionBar = buildScreenshotActionBar()
        screenshotActionBar.translatesAutoresizingMaskIntoConstraints = false
        screenshotActionBar.isHidden = true
        container.addSubview(screenshotActionBar)

        archivedNoticeBar = buildArchivedNoticeBar()
        archivedNoticeBar.translatesAutoresizingMaskIntoConstraints = false
        archivedNoticeBar.isHidden = true
        container.addSubview(archivedNoticeBar)

        logPane = buildLogPane()
        logPane.translatesAutoresizingMaskIntoConstraints = false
        logPane.isHidden = true
        container.addSubview(logPane)

        scrollTopToArchivedNoticeConstraint = scrollView.topAnchor.constraint(equalTo: archivedNoticeBar.bottomAnchor)
        scrollTopToContainerConstraint = scrollView.topAnchor.constraint(equalTo: container.topAnchor)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: screenshotActionBar.topAnchor),

            archivedNoticeBar.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            archivedNoticeBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            archivedNoticeBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            phView.topAnchor.constraint(equalTo: container.topAnchor),
            phView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            phView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            phView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            screenshotActionBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            screenshotActionBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            screenshotActionBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            logPane.topAnchor.constraint(equalTo: container.topAnchor),
            logPane.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            logPane.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            logPane.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        screenshotActionBarHeightConstraint = screenshotActionBar.heightAnchor.constraint(equalToConstant: 0)
        screenshotActionBarHeightConstraint.isActive = true
        archivedNoticeBarHeightConstraint = archivedNoticeBar.heightAnchor.constraint(equalToConstant: 0)
        archivedNoticeBarHeightConstraint.isActive = true
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
            selector: #selector(logDidUpdate),
            name: .librarianLogUpdated,
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
        refreshTaskAndLogPanes()
        updateOverlay()
    }

    @objc private func sidebarSelectionChanged() {
        AppLog.shared.info("Sidebar selection: \(selectedSidebarKind().debugName)")
        loadAssetsIfNeeded(force: true)
        refreshTaskAndLogPanes()
        updateOverlay()
    }

    @objc private func logDidUpdate() {
        if selectedSidebarKind() == .log {
            refreshLogPane()
        }
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
        if selectedSidebarKind() == .archived {
            loadAssetsIfNeeded(force: true)
        }
        updateArchivedNoticeBarState()
    }

    private func loadAssetsIfNeeded(force: Bool) {
        guard model.photosAuthState == .authorized else { return }
        let sidebarKind = selectedSidebarKind()

        if sidebarKind == .indexing || sidebarKind == .log {
            loadGeneration &+= 1
            canLoadMoreAssets = false
            isLoadingAssets = false
            displayAssets = []
            model.photosService.stopAllThumbnailCaching()
            lastLoadedSidebarKind = sidebarKind
            collectionView.reloadData()
            updateScreenshotActionBarState()
            model.setSelectedAsset(nil)
            updateOverlay()
            return
        }

        guard !model.isIndexing else { return }
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
            case .indexing, .log:
                assets = []
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
                    }
                    self.model.photosService.stopAllThumbnailCaching()
                    self.collectionView.reloadData()
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
                self.updateScreenshotActionBarState()
                self.updateArchivedNoticeBarState()
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
        guard model.photosAuthState == .authorized else { return }
        guard !model.isIndexing else { return }
        guard !isLoadingAssets else { return }
        guard canLoadMoreAssets else { return }

        let sidebarKind = selectedSidebarKind()
        guard sidebarKind != .indexing, sidebarKind != .log else { return }
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
        switch model.photosAuthState {
        case .notDetermined:
            showPlaceholder(.loading(title: "Requesting Access", symbolName: "key.fill"))
            collectionView.isHidden = true
            logPane.isHidden = true
        case .denied, .restricted:
            showPlaceholder(.unavailable(
                title: "Access Required",
                symbolName: "lock.fill",
                description: "Open System Settings to grant Librarian access to your photo library."))
            collectionView.isHidden = true
            logPane.isHidden = true
        case .limited:
            showPlaceholder(.unavailable(
                title: "Full Access Required",
                symbolName: "lock.trianglebadge.exclamationmark.fill",
                description: "Librarian requires full access to your photo library. Please update your privacy settings."))
            collectionView.isHidden = true
            logPane.isHidden = true
        case .authorized:
            if sidebarKind == .log {
                hidePlaceholder()
                collectionView.isHidden = true
                logPane.isHidden = false
                refreshLogPane()
            } else if sidebarKind == .indexing {
                showPlaceholder(.loading(title: "Indexing", symbolName: "arrow.triangle.2.circlepath"))
                collectionView.isHidden = true
                logPane.isHidden = true
            } else if model.isIndexing, displayAssets.isEmpty {
                showPlaceholder(.loading(title: "Indexing", symbolName: "arrow.triangle.2.circlepath"))
                collectionView.isHidden = true
                logPane.isHidden = true
            } else if isLoadingAssets, displayAssets.isEmpty {
                showPlaceholder(.loading(title: "Loading", symbolName: symbolName(for: sidebarKind)))
                collectionView.isHidden = true
                logPane.isHidden = true
            } else if !displayAssets.isEmpty {
                hidePlaceholder()
                collectionView.isHidden = false
                logPane.isHidden = true
            } else {
                showPlaceholder(emptyContent(for: sidebarKind))
                collectionView.isHidden = true
                logPane.isHidden = true
            }
            updateScreenshotActionBarState()
        @unknown default:
            hidePlaceholder()
            logPane.isHidden = true
            updateScreenshotActionBarState()
        }
        updateArchivedNoticeBarState()
    }

    private func showPlaceholder(_ content: GalleryPlaceholderContent) {
        placeholderViewModel.content = content
        placeholderHostingView?.isHidden = false
    }

    private func hidePlaceholder() {
        placeholderViewModel.content = nil
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
        case .duplicates: return "doc.on.doc"
        case .lowQuality: return "wand.and.stars.inverse"
        case .receiptsAndDocuments: return "doc.text"
        case .log: return "list.bullet.rectangle"
        case .indexing: return "arrow.triangle.2.circlepath"
        }
    }

    private func emptyContent(for kind: SidebarItem.Kind) -> GalleryPlaceholderContent {
        switch kind {
        case .allPhotos:
            let description = model.indexedAssetCount > 0
                ? "No photos match the current filters."
                : "Your photo library appears to be empty."
            return .unavailable(title: "No Photos", symbolName: "photo.on.rectangle.angled", description: description)
        case .recents:
            return .unavailable(title: "No Recent Photos", symbolName: "clock", description: "No photos from the past 30 days.")
        case .favourites:
            return .unavailable(title: "No Favourites", symbolName: "heart", description: "Mark photos as favourites in Photos to see them here.")
        case .screenshots:
            return .unavailable(title: "No Screenshots", symbolName: "camera.viewfinder", description: "All screenshots have been reviewed.")
        case .setAsideForArchive:
            return .unavailable(title: "Nothing Set Aside", symbolName: "tray.full", description: "Photos you set aside for archiving will appear here.")
        case .archived:
            let availability = model.refreshArchiveRootAvailability()
            switch availability {
            case .notConfigured:
                return .unavailable(
                    title: "No Archive Destination",
                    symbolName: "externaldrive.badge.questionmark",
                    description: "Set an archive destination in Settings to view archived photos."
                )
            case .unavailable, .readOnly, .permissionDenied:
                return .unavailable(
                    title: "Archive Unavailable",
                    symbolName: "externaldrive.badge.exclamationmark",
                    description: "\(availability.userVisibleDescription) Update the destination in Settings or reconnect the drive."
                )
            case .available:
                break
            }
            return .unavailable(title: "No Archive Photos", symbolName: "archivebox", description: "Archive photos will appear here after export.")
        case .duplicates:
            return .unavailable(title: "No Duplicates", symbolName: "doc.on.doc", description: "No duplicate or near-duplicate photos found.")
        case .lowQuality:
            return .unavailable(title: "No Low Quality Photos", symbolName: "wand.and.stars.inverse", description: "No photos with a low quality score found.")
        case .receiptsAndDocuments:
            return .unavailable(title: "No Documents", symbolName: "doc.text", description: "No document-focused photos found.")
        case .log, .indexing:
            return .unavailable(title: "No Log Entries", symbolName: "list.bullet.rectangle", description: "Activity will appear here.")
        }
    }

    private func thumbnailTargetSize() -> CGSize {
        let size = NSSize(width: galleryLayout.tileSide, height: galleryLayout.tileSide)
        let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    private func thumbnailTileSide() -> CGFloat {
        galleryLayout.tileSide
    }

    private func applyColumnCount(_ targetColumnCount: Int, animated: Bool) {
        guard targetColumnCount > 0 else { return }
        guard galleryLayout.columnCount != targetColumnCount else { return }

        zoomRestoreToken += 1
        let restoreToken = zoomRestoreToken
        let anchor = captureZoomTransitionAnchor()
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
        restoreZoomTransitionAnchor(anchor, token: restoreToken)
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

    private struct ZoomTransitionAnchor {
        let itemIndex: Int
    }

    private func captureZoomTransitionAnchor() -> ZoomTransitionAnchor? {
        if let selectedIdentifier = model.selectedAsset?.localIdentifier,
           let index = displayAssets.firstIndex(where: { $0.photoIdentifier == selectedIdentifier }) {
            return ZoomTransitionAnchor(itemIndex: index)
        }

        let visible = collectionView.indexPathsForVisibleItems()
        guard !visible.isEmpty else { return nil }
        let visibleRect = collectionView.visibleRect
        let center = CGPoint(x: visibleRect.midX, y: visibleRect.midY)
        guard let currentLayout = collectionView.collectionViewLayout else { return nil }

        let best = visible.min { lhs, rhs in
            let lhsFrame = currentLayout.layoutAttributesForItem(at: lhs)?.frame ?? .zero
            let rhsFrame = currentLayout.layoutAttributesForItem(at: rhs)?.frame ?? .zero
            let lhsCenter = CGPoint(x: lhsFrame.midX, y: lhsFrame.midY)
            let rhsCenter = CGPoint(x: rhsFrame.midX, y: rhsFrame.midY)
            let lhsDistance = hypot(lhsCenter.x - center.x, lhsCenter.y - center.y)
            let rhsDistance = hypot(rhsCenter.x - center.x, rhsCenter.y - center.y)
            return lhsDistance < rhsDistance
        }

        guard let index = best?.item else { return nil }
        return ZoomTransitionAnchor(itemIndex: index)
    }

    private func restoreZoomTransitionAnchor(_ anchor: ZoomTransitionAnchor?, token: Int) {
        guard let anchor else { return }
        guard anchor.itemIndex >= 0, anchor.itemIndex < displayAssets.count else { return }
        guard collectionView.numberOfSections > 0 else { return }
        let currentCount = collectionView.numberOfItems(inSection: 0)
        guard anchor.itemIndex < currentCount else { return }

        let indexPath = IndexPath(item: anchor.itemIndex, section: 0)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard token == self.zoomRestoreToken else { return }
            guard self.collectionView.numberOfSections > 0 else { return }
            let liveCount = self.collectionView.numberOfItems(inSection: 0)
            guard anchor.itemIndex < liveCount else { return }
            self.collectionView.scrollToItems(at: [indexPath], scrollPosition: .nearestVerticalEdge)
        }
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


    private func buildScreenshotActionBar() -> NSView {
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(divider)

        screenshotSelectionLabel = NSTextField(labelWithString: "")
        screenshotSelectionLabel.font = NSFont.systemFont(ofSize: 12)
        screenshotSelectionLabel.textColor = .secondaryLabelColor
        screenshotSelectionLabel.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(screenshotSelectionLabel)

        screenshotArchiveButton = NSButton(title: "Set Aside", target: self, action: #selector(markScreenshotsArchiveCandidate))
        screenshotArchiveButton.bezelStyle = .rounded
        screenshotArchiveButton.bezelColor = AppTheme.accentNSColor
        screenshotArchiveButton.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(screenshotArchiveButton)

        screenshotKeepButton = NSButton(title: "Keep", target: self, action: #selector(markScreenshotsKeep))
        screenshotKeepButton.bezelStyle = .rounded
        screenshotKeepButton.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(screenshotKeepButton)

        NSLayoutConstraint.activate([
            divider.topAnchor.constraint(equalTo: bar.topAnchor),
            divider.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),

            screenshotSelectionLabel.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            screenshotSelectionLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            screenshotArchiveButton.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            screenshotArchiveButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            screenshotKeepButton.trailingAnchor.constraint(equalTo: screenshotArchiveButton.leadingAnchor, constant: -8),
            screenshotKeepButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])

        return bar
    }

    private func buildArchivedNoticeBar() -> NSView {
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(divider)

        archivedNoticeLabel = NSTextField(labelWithString: "")
        archivedNoticeLabel.font = NSFont.systemFont(ofSize: 12)
        archivedNoticeLabel.textColor = .secondaryLabelColor
        archivedNoticeLabel.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(archivedNoticeLabel)

        archivedNoticeActionButton = NSButton(title: "Organize Now", target: self, action: #selector(organizeArchivedFilesNow))
        archivedNoticeActionButton.bezelStyle = .rounded
        archivedNoticeActionButton.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(archivedNoticeActionButton)

        archivedNoticeDismissButton = NSButton(title: "Not Now", target: self, action: #selector(dismissArchivedNoticeForLaunch))
        archivedNoticeDismissButton.bezelStyle = .rounded
        archivedNoticeDismissButton.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(archivedNoticeDismissButton)

        NSLayoutConstraint.activate([
            divider.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),

            archivedNoticeLabel.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            archivedNoticeLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            archivedNoticeDismissButton.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            archivedNoticeDismissButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            archivedNoticeActionButton.trailingAnchor.constraint(equalTo: archivedNoticeDismissButton.leadingAnchor, constant: -8),
            archivedNoticeActionButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])

        return bar
    }

    @objc
    private func organizeArchivedFilesNow() {
        guard !isOrganizingArchivedFiles else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let archiveTreeRoot = ArchiveSettings.currentArchiveTreeRootURL() else { return }
            self.isOrganizingArchivedFiles = true
            self.updateArchivedNoticeBarState()
            do {
                let organizer = self.archiveOrganizer
                let summary = try await Task.detached(priority: .utility) {
                    try organizer.organizeArchiveTree(in: archiveTreeRoot)
                }.value
                AppLog.shared.info("Archive view organization completed. moved=\(summary.movedCount), alreadyOrganized=\(summary.alreadyOrganizedCount), scanned=\(summary.scannedCount)")
                self.archivedBannerDismissedForLaunch = false
                NotificationCenter.default.post(name: .librarianArchiveQueueChanged, object: nil)
            } catch {
                AppLog.shared.error("Archive view organization failed: \(error.localizedDescription)")
            }
            self.isOrganizingArchivedFiles = false
            self.updateArchivedNoticeBarState()
        }
    }

    @objc
    private func dismissArchivedNoticeForLaunch() {
        archivedBannerDismissedForLaunch = true
        updateArchivedNoticeBarState()
    }

    private func updateArchivedNoticeBarState() {
        let shouldShow = selectedSidebarKind() == .archived
            && archivedUnorganizedCount > 0
            && !archivedBannerDismissedForLaunch
        archivedNoticeBar.isHidden = !shouldShow
        archivedNoticeBarHeightConstraint.constant = shouldShow ? 40 : 0
        scrollTopToArchivedNoticeConstraint.isActive = shouldShow
        scrollTopToContainerConstraint.isActive = !shouldShow

        guard shouldShow else { return }
        archivedNoticeLabel.stringValue = "\(archivedUnorganizedCount.formatted()) file(s) are outside YYYY/MM/DD. Organize archive now?"
        archivedNoticeActionButton.isEnabled = !isOrganizingArchivedFiles
        archivedNoticeActionButton.title = isOrganizingArchivedFiles ? "Organizing…" : "Organize Now"
        archivedNoticeDismissButton.isEnabled = !isOrganizingArchivedFiles
    }

    private func buildLogPane() -> NSView {
        let pane = NSView()

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        logTextView = NSTextView()
        logTextView.isEditable = false
        logTextView.isRichText = false
        logTextView.isVerticallyResizable = true
        logTextView.isHorizontallyResizable = false
        logTextView.autoresizingMask = [.width]
        logTextView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        logTextView.backgroundColor = .clear
        logTextView.textColor = .labelColor
        logTextView.textContainer?.widthTracksTextView = true
        scroll.documentView = logTextView
        pane.addSubview(scroll)

        let logPlaceholderHost = NSHostingController(rootView: GalleryPlaceholderView(viewModel: logPlaceholderViewModel))
        logPlaceholderHost.sizingOptions = []
        addChild(logPlaceholderHost)
        let lpView = logPlaceholderHost.view
        lpView.translatesAutoresizingMaskIntoConstraints = false
        lpView.isHidden = true
        pane.addSubview(lpView)
        logPlaceholderHostingView = lpView

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: pane.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: pane.bottomAnchor),

            lpView.topAnchor.constraint(equalTo: pane.topAnchor),
            lpView.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            lpView.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            lpView.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
        ])

        return pane
    }

    private func refreshTaskAndLogPanes() {
        if selectedSidebarKind() == .log {
            refreshLogPane()
        }
    }

    private func refreshLogPane() {
        let text = AppLog.shared.readRecentLines(maxLines: 800)
        logTextView.string = text
        logTextView.sizeToFit()
        let isEmpty = text.isEmpty
        logTextView.enclosingScrollView?.isHidden = isEmpty
        logPlaceholderHostingView?.isHidden = !isEmpty
        logPlaceholderViewModel.content = isEmpty ? .unavailable(
            title: "No Log Entries",
            symbolName: "list.bullet.rectangle",
            description: "Activity will appear here.") : nil
    }

    func openSelectionInPhotos() {
        guard let selectedIndex = collectionView.selectionIndexPaths.first?.item,
              selectedIndex >= 0,
              selectedIndex < displayAssets.count else { return }
        guard let localIdentifier = displayAssets[selectedIndex].photoIdentifier else { return }
        model.photosService.openInPhotos(localIdentifier: localIdentifier)
    }

    @objc private func markScreenshotsKeep() {
        let kind = selectedSidebarKind()
        let identifiers = selectedAssetIdentifiers()
        guard !identifiers.isEmpty else { return }
        do {
            try model.database.assetRepository.keepAssetsInQueue(identifiers, queueKind: kind.debugName)
            AppLog.shared.info("Kept \(identifiers.count) item(s) in queue '\(kind.debugName)'")
            collectionView.deselectAll(nil)
            model.setSelectedAsset(nil)
            loadAssetsIfNeeded(force: true)
        } catch {
            AppLog.shared.error("Failed to keep assets in queue: \(error.localizedDescription)")
        }
        updateScreenshotActionBarState()
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
            collectionView.deselectAll(nil)
            model.setSelectedAsset(nil)
            loadAssetsIfNeeded(force: true)
        } catch {
            AppLog.shared.error("Failed to set screenshot decision: \(error.localizedDescription)")
        }
        updateScreenshotActionBarState()
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

    func queueSelectedAssetsForArchive() {
        let identifiers = selectedAssetIdentifiers()
        guard !identifiers.isEmpty else { return }
        do {
            try model.queueAssetsForArchive(localIdentifiers: identifiers)
            AppLog.shared.info("Set aside \(identifiers.count) selected photo(s) for archive")
            collectionView.deselectAll(nil)
            model.setSelectedAsset(nil)
            loadAssetsIfNeeded(force: true)
        } catch {
            AppLog.shared.error("Failed to set aside photos for archive: \(error.localizedDescription)")
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
            AppLog.shared.info("Put back \(identifiers.count) item(s) from archive set-aside queue")
        } catch {
            AppLog.shared.error("Failed to put back selected archive items: \(error.localizedDescription)")
        }
    }

    func refreshDisplayedAssets() {
        loadAssetsIfNeeded(force: true)
    }

    private func updateScreenshotActionBarState() {
        let kind = selectedSidebarKind()
        let isQueueView = kind == .screenshots || kind == .duplicates || kind == .lowQuality || kind == .receiptsAndDocuments
        let shouldShow = isQueueView && !collectionView.isHidden && !displayAssets.isEmpty
        screenshotActionBar.isHidden = !shouldShow
        screenshotActionBarHeightConstraint.constant = shouldShow ? 44 : 0

        guard shouldShow else { return }
        let selectionCount = selectedAssetIdentifiers().count
        let emptyLabel = kind == .screenshots ? "Select screenshots to review" : "Select photos to review"
        screenshotSelectionLabel.stringValue = selectionCount > 0 ? "\(selectionCount) selected" : emptyLabel
        screenshotKeepButton.isEnabled = selectionCount > 0
        screenshotArchiveButton.isEnabled = selectionCount > 0
    }
}

// MARK: - NSCollectionViewDataSource

extension ContentController: NSCollectionViewDataSource {
    func numberOfSections(in collectionView: NSCollectionView) -> Int {
        1
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        displayAssets.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        guard let item = collectionView.makeItem(withIdentifier: .assetGridItem, for: indexPath) as? AssetGridItem else {
            return NSCollectionViewItem()
        }

        let asset = displayAssets[indexPath.item]
        let preferredAspectRatio: CGFloat? = {
            guard asset.pixelWidth > 0, asset.pixelHeight > 0 else { return nil }
            return CGFloat(asset.pixelWidth) / CGFloat(asset.pixelHeight)
        }()
        item.prepare(
            localIdentifier: asset.id,
            preferredAspectRatio: preferredAspectRatio,
            tileSide: thumbnailTileSide()
        )

        switch asset {
        case .photos(let photoAsset):
            guard let phAsset = model.photosService.fetchAsset(localIdentifier: photoAsset.localIdentifier) else {
                item.applyImage(nil, forLocalIdentifier: asset.id)
                return item
            }

            let targetSize = thumbnailTargetSize()
            _ = model.photosService.requestThumbnail(for: phAsset, targetSize: targetSize) { [weak item] image in
                guard let item else { return }
                item.applyImage(image, forLocalIdentifier: asset.id)
            }
        case .archived(let archivedItem):
            let targetSize = thumbnailTargetSize()
            archivedThumbnailService.requestThumbnail(for: archivedItem, targetSize: targetSize) { [weak item] image in
                guard let item else { return }
                Task { @MainActor in
                    item.applyImage(image, forLocalIdentifier: asset.id)
                }
            }
        }

        return item
    }
}

// MARK: - NSCollectionViewDelegate

extension ContentController: NSCollectionViewDelegate {}
extension ContentController: NSCollectionViewPrefetching {
    func collectionView(_ collectionView: NSCollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        let assets = indexPaths.compactMap { indexPath -> PHAsset? in
            guard indexPath.item >= 0, indexPath.item < displayAssets.count else { return nil }
            guard let localIdentifier = displayAssets[indexPath.item].photoIdentifier else { return nil }
            return model.photosService.fetchAsset(localIdentifier: localIdentifier)
        }
        model.photosService.startCachingThumbnails(for: assets, targetSize: thumbnailTargetSize())
    }

    func collectionView(_ collectionView: NSCollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        let assets = indexPaths.compactMap { indexPath -> PHAsset? in
            guard indexPath.item >= 0, indexPath.item < displayAssets.count else { return nil }
            guard let localIdentifier = displayAssets[indexPath.item].photoIdentifier else { return nil }
            return model.photosService.fetchAsset(localIdentifier: localIdentifier)
        }
        model.photosService.stopCachingThumbnails(for: assets, targetSize: thumbnailTargetSize())
    }
}

extension ContentController {
    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        syncModelSelectionFromCollection()
        updateScreenshotActionBarState()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        syncModelSelectionFromCollection()
        updateScreenshotActionBarState()
    }

    private func syncModelSelectionFromCollection() {
        let count = collectionView.selectionIndexPaths.count
        guard let selectedIndex = collectionView.selectionIndexPaths.first?.item,
              selectedIndex >= 0,
              selectedIndex < displayAssets.count else {
            model.setSelectedAsset(nil, count: 0)
            return
        }
        if let selectedAsset = displayAssets[selectedIndex].photoAsset {
            model.setSelectedAsset(selectedAsset, count: count)
        } else {
            model.setSelectedAsset(nil, count: 0)
        }
    }

    private func handleModifiedItemClick(indexPath: IndexPath, modifiers: NSEvent.ModifierFlags) {
        guard indexPath.item >= 0, indexPath.item < displayAssets.count else { return }
        let hasCommand = modifiers.contains(.command)
        let hasShift = modifiers.contains(.shift)
        let clicked = indexPath.item

        var nextSelection = collectionView.selectionIndexPaths
        if hasShift {
            let anchor = selectionAnchorIndex ?? collectionView.selectionIndexPaths.first?.item ?? clicked
            let range = min(anchor, clicked)...max(anchor, clicked)
            let rangeSelection = Set(range.map { IndexPath(item: $0, section: 0) })
            if hasCommand {
                nextSelection.formUnion(rangeSelection)
            } else {
                nextSelection = rangeSelection
            }
            selectionAnchorIndex = anchor
        } else if hasCommand {
            let clickedPath = IndexPath(item: clicked, section: 0)
            if nextSelection.contains(clickedPath) {
                nextSelection.remove(clickedPath)
            } else {
                nextSelection.insert(clickedPath)
            }
            selectionAnchorIndex = clicked
        }

        collectionView.selectionIndexPaths = nextSelection
        collectionView.scrollToItems(at: [IndexPath(item: clicked, section: 0)], scrollPosition: .nearestVerticalEdge)
        syncModelSelectionFromCollection()
        updateScreenshotActionBarState()
    }

    private func moveSelection(_ direction: SharedUI.MoveCommandDirection, extendingSelection: Bool) {
        guard !displayAssets.isEmpty else { return }
        let current = collectionView.selectionIndexPaths.map(\.item).sorted()
        let focus = current.last ?? 0
        let columns = max(model.galleryColumnCount, 1)

        let candidate: Int
        switch direction {
        case .left:
            candidate = focus - 1
        case .right:
            candidate = focus + 1
        case .up:
            candidate = focus - columns
        case .down:
            candidate = focus + columns
        }
        let next = max(0, min(displayAssets.count - 1, candidate))
        guard next != focus || current.isEmpty else { return }

        if extendingSelection {
            let anchor = selectionAnchorIndex ?? focus
            selectionAnchorIndex = anchor
            let range = min(anchor, next)...max(anchor, next)
            let nextSelection = Set(range.map { IndexPath(item: $0, section: 0) })
            collectionView.selectionIndexPaths = nextSelection
        } else {
            selectionAnchorIndex = next
            collectionView.selectionIndexPaths = [IndexPath(item: next, section: 0)]
        }

        collectionView.scrollToItems(at: [IndexPath(item: next, section: 0)], scrollPosition: .nearestVerticalEdge)
        syncModelSelectionFromCollection()
        updateScreenshotActionBarState()
    }
}

// MARK: - Item identifier

private extension NSUserInterfaceItemIdentifier {
    static let assetGridItem = NSUserInterfaceItemIdentifier("AssetGridItem")
}

// MARK: - Asset grid item

private final class AssetGridItem: NSCollectionViewItem {

    private let fallback = NSImageView()
    private let selectionBackgroundView = NSView()
    private let thumbnailCornerRadius: CGFloat = GalleryMetrics.default.thumbnailCornerRadius
    private let imageInset: CGFloat = GalleryMetrics.default.imageInset
    private var representedLocalIdentifier: String?
    private var preferredAspectRatio: CGFloat?
    private var currentTileSide: CGFloat = 160
    private var imageWidthConstraint: NSLayoutConstraint?
    private var imageHeightConstraint: NSLayoutConstraint?

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor

        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.animates = true
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = thumbnailCornerRadius
        imageView.layer?.masksToBounds = true
        self.imageView = imageView
        
        selectionBackgroundView.translatesAutoresizingMaskIntoConstraints = false
        selectionBackgroundView.wantsLayer = true
        selectionBackgroundView.layer?.cornerRadius = thumbnailCornerRadius
        selectionBackgroundView.layer?.masksToBounds = true
        selectionBackgroundView.layer?.backgroundColor = NSColor.clear.cgColor
        view.addSubview(selectionBackgroundView)
        view.addSubview(imageView)

        fallback.translatesAutoresizingMaskIntoConstraints = false
        fallback.image = NSImage(systemSymbolName: "photo", accessibilityDescription: "Photo")
        fallback.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        fallback.contentTintColor = .tertiaryLabelColor
        view.addSubview(fallback)

        NSLayoutConstraint.activate([
            selectionBackgroundView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            selectionBackgroundView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            selectionBackgroundView.topAnchor.constraint(equalTo: view.topAnchor),
            selectionBackgroundView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            imageView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            fallback.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            fallback.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        imageWidthConstraint = imageView.widthAnchor.constraint(equalToConstant: 20)
        imageHeightConstraint = imageView.heightAnchor.constraint(equalToConstant: 20)
        imageWidthConstraint?.isActive = true
        imageHeightConstraint?.isActive = true
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let side = max(1, floor(min(view.bounds.width, view.bounds.height)))
        updateTileSide(side)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        representedLocalIdentifier = nil
        preferredAspectRatio = nil
        imageView?.image = nil
        fallback.isHidden = false
        isSelected = false
    }

    func prepare(localIdentifier: String, preferredAspectRatio: CGFloat?, tileSide: CGFloat) {
        representedLocalIdentifier = localIdentifier
        self.preferredAspectRatio = preferredAspectRatio
        imageView?.image = nil
        fallback.isHidden = false
        updateTileSide(tileSide)
    }

    func applyImage(_ image: NSImage?, forLocalIdentifier identifier: String) {
        guard representedLocalIdentifier == identifier else { return }
        imageView?.image = image
        fallback.isHidden = image != nil
        updateGeometry()
    }

    override var isSelected: Bool {
        didSet {
            selectionBackgroundView.layer?.backgroundColor = isSelected
                ? AppTheme.accentNSColor.withAlphaComponent(0.22).cgColor
                : NSColor.clear.cgColor
        }
    }

    private func updateTileSide(_ tileSide: CGFloat) {
        currentTileSide = tileSide
        updateGeometry()
    }

    func updateTileSide(_ tileSide: CGFloat, animated: Bool) {
        currentTileSide = tileSide
        updateGeometry(animated: animated)
    }

    private func updateGeometry() {
        updateGeometry(animated: false)
    }

    private func updateGeometry(animated: Bool) {
        let fitted = fittedImageSize(in: currentTileSide)
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            imageWidthConstraint?.constant = fitted.width
            imageHeightConstraint?.constant = fitted.height
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            imageWidthConstraint?.animator().constant = fitted.width
            imageHeightConstraint?.animator().constant = fitted.height
        }
    }

    private func fittedImageSize(in tileSide: CGFloat) -> CGSize {
        let availableSide = max(1, floor(tileSide - imageInset * 2))
        let aspect: CGFloat
        if let size = resolvedImageSize(imageView?.image), size.width > 0, size.height > 0 {
            aspect = size.width / size.height
        } else if let preferredAspectRatio, preferredAspectRatio > 0 {
            aspect = preferredAspectRatio
        } else {
            aspect = 1
        }

        if aspect >= 1 {
            return CGSize(width: availableSide, height: max(1, floor(availableSide / aspect)))
        } else {
            return CGSize(width: max(1, floor(availableSide * aspect)), height: availableSide)
        }
    }

    private func resolvedImageSize(_ image: NSImage?) -> CGSize? {
        guard let image else { return nil }
        if image.size.width > 0, image.size.height > 0 {
            return image.size
        }
        if let bitmap = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first,
           bitmap.pixelsWide > 0,
           bitmap.pixelsHigh > 0 {
            return CGSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
        }
        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
           cgImage.width > 0,
           cgImage.height > 0 {
            return CGSize(width: cgImage.width, height: cgImage.height)
        }
        return nil
    }
}

struct ArchiveIndexRefreshSummary {
    let unorganizedCount: Int

    static let empty = ArchiveIndexRefreshSummary(unorganizedCount: 0)
}

struct ArchiveOrganizationResult {
    let scannedCount: Int
    let movedCount: Int
    let alreadyOrganizedCount: Int
    let collisionCount: Int
}

enum ArchiveOrganizationLayout: String {
    case rootDateBuckets
}

final class ArchiveOrganizer: @unchecked Sendable {
    private let fileManager = FileManager.default
    private let imageExtensions: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "tif", "tiff"]
    private let layout: ArchiveOrganizationLayout

    init(layout: ArchiveOrganizationLayout = .rootDateBuckets) {
        self.layout = layout
    }

    func scanUnorganizedCount(in archiveTreeRoot: URL) throws -> Int {
        try withArchiveAccess(root: archiveTreeRoot) { root in
            guard try archiveTreeExists(root) else { return 0 }
            var count = 0
            try enumerateRegularFiles(in: root) { fileURL, relativeComponents, _ in
                let parentComponents = Array(relativeComponents.dropLast())
                if !isOrganizedPath(parentComponents) {
                    count += 1
                }
            }
            return count
        }
    }

    func organizeArchiveTree(in archiveTreeRoot: URL) throws -> ArchiveOrganizationResult {
        try withArchiveAccess(root: archiveTreeRoot) { root in
            guard try archiveTreeExists(root) else {
                return ArchiveOrganizationResult(scannedCount: 0, movedCount: 0, alreadyOrganizedCount: 0, collisionCount: 0)
            }

            var scannedCount = 0
            var candidates: [(url: URL, fallbackDate: Date)] = []
            try enumerateRegularFiles(in: root) { fileURL, relativeComponents, resourceValues in
                scannedCount += 1
                let parentComponents = Array(relativeComponents.dropLast())
                guard !isOrganizedPath(parentComponents) else { return }
                let fallbackDate = resourceValues.contentModificationDate ?? Date()
                candidates.append((fileURL, fallbackDate))
            }

            var movedCount = 0
            var collisionCount = 0

            for candidate in candidates {
                let sourceURL = candidate.url
                let targetDate = readCaptureDateIfAvailable(from: sourceURL) ?? candidate.fallbackDate
                let datePath = datePathComponents(for: targetDate)

                var destinationDirectory = root
                for component in destinationPathComponents(for: datePath) {
                    destinationDirectory.appendPathComponent(component, isDirectory: true)
                }
                try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

                let destinationURL = uniqueDestinationURL(in: destinationDirectory, fileName: sourceURL.lastPathComponent)
                if destinationURL.lastPathComponent != sourceURL.lastPathComponent {
                    collisionCount += 1
                }

                if sourceURL.standardizedFileURL == destinationURL.standardizedFileURL {
                    continue
                }
                try fileManager.moveItem(at: sourceURL, to: destinationURL)
                movedCount += 1
            }
            removeEmptyDirectories(in: root)

            return ArchiveOrganizationResult(
                scannedCount: scannedCount,
                movedCount: movedCount,
                alreadyOrganizedCount: scannedCount - candidates.count,
                collisionCount: collisionCount
            )
        }
    }

    private func withArchiveAccess<T>(root: URL, operation: (URL) throws -> T) throws -> T {
        let didAccess = root.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                root.stopAccessingSecurityScopedResource()
            }
        }
        return try operation(root)
    }

    private func archiveTreeExists(_ root: URL) throws -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func enumerateRegularFiles(
        in root: URL,
        visitor: (URL, [String], URLResourceValues) throws -> Void
    ) throws {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants, .skipsHiddenFiles]
        ) else {
            return
        }

        let rootComponents = root.standardizedFileURL.pathComponents
        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent.hasPrefix(".") {
                continue
            }
            let standardized = fileURL.standardizedFileURL
            let fileComponents = standardized.pathComponents
            guard fileComponents.count > rootComponents.count else { continue }
            guard Array(fileComponents.prefix(rootComponents.count)) == rootComponents else { continue }

            let relativeComponents = Array(fileComponents.dropFirst(rootComponents.count))
            guard !relativeComponents.isEmpty else { continue }
            guard relativeComponents.first != ".librarian-thumbnails" else { continue }

            let values = try fileURL.resourceValues(forKeys: keys)
            guard values.isRegularFile == true else { continue }
            try visitor(fileURL, relativeComponents, values)
        }
    }

    private func isOrganizedDatePath(_ components: [String]) -> Bool {
        guard components.count >= 3 else { return false }
        let year = components[components.count - 3]
        let month = components[components.count - 2]
        let day = components[components.count - 1]
        return isYear(year) && isMonth(month) && isDay(day)
    }

    private func isOrganizedPath(_ components: [String]) -> Bool {
        switch layout {
        case .rootDateBuckets:
            return components.count == 3 && isOrganizedDatePath(components)
        }
    }

    private func destinationPathComponents(for datePath: [String]) -> [String] {
        switch layout {
        case .rootDateBuckets:
            return datePath
        }
    }

    private func isYear(_ value: String) -> Bool {
        guard value.count == 4, let intValue = Int(value) else { return false }
        return intValue >= 1900 && intValue <= 3000
    }

    private func isMonth(_ value: String) -> Bool {
        guard value.count == 2, let intValue = Int(value) else { return false }
        return intValue >= 1 && intValue <= 12
    }

    private func isDay(_ value: String) -> Bool {
        guard value.count == 2, let intValue = Int(value) else { return false }
        return intValue >= 1 && intValue <= 31
    }

    private func datePathComponents(for date: Date) -> [String] {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = String(format: "%04d", components.year ?? 1970)
        let month = String(format: "%02d", components.month ?? 1)
        let day = String(format: "%02d", components.day ?? 1)
        return [year, month, day]
    }

    private func uniqueDestinationURL(in directory: URL, fileName: String) -> URL {
        var candidate = directory.appendingPathComponent(fileName, isDirectory: false)
        guard fileManager.fileExists(atPath: candidate.path) else { return candidate }

        let ext = (fileName as NSString).pathExtension
        let baseName = (fileName as NSString).deletingPathExtension
        var counter = 2
        while true {
            let suffix = "-\(counter)"
            let nextName = ext.isEmpty ? "\(baseName)\(suffix)" : "\(baseName)\(suffix).\(ext)"
            candidate = directory.appendingPathComponent(nextName, isDirectory: false)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            counter += 1
        }
    }

    private func removeEmptyDirectories(in root: URL) {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants, .skipsHiddenFiles]
        ) else {
            return
        }

        var directories: [URL] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent != ".librarian-thumbnails" else { continue }
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                directories.append(url)
            }
        }

        directories.sort { $0.pathComponents.count > $1.pathComponents.count }
        for directory in directories {
            if directory.standardizedFileURL == root.standardizedFileURL {
                continue
            }
            if isDirectoryEmpty(directory) {
                try? fileManager.removeItem(at: directory)
            }
        }
    }

    private func isDirectoryEmpty(_ url: URL) -> Bool {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }
        return contents.isEmpty
    }

    private func readCaptureDateIfAvailable(from fileURL: URL) -> Date? {
        let lowerExtension = fileURL.pathExtension.lowercased()
        guard imageExtensions.contains(lowerExtension) else { return nil }
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }

        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            if let date = parseExifDate(exif[kCGImagePropertyExifDateTimeOriginal] as? String) {
                return date
            }
            if let date = parseExifDate(exif[kCGImagePropertyExifDateTimeDigitized] as? String) {
                return date
            }
        }
        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            return parseExifDate(tiff[kCGImagePropertyTIFFDateTime] as? String)
        }
        return nil
    }

    private func parseExifDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: value)
    }
}

final class ArchiveIndexer: @unchecked Sendable {
    private let database: DatabaseManager
    private let fileManager = FileManager.default
    private let organizer = ArchiveOrganizer()
    private let supportedExtensions: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "tif", "tiff"]
    private let exifDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()

    init(database: DatabaseManager) {
        self.database = database
    }

    func refreshIndex() throws -> ArchiveIndexRefreshSummary {
        guard database.assetRepository != nil else { return .empty }

        guard let archiveTreeRoot = ArchiveSettings.currentArchiveTreeRootURL() else {
            let existing = try database.assetRepository.fetchArchivedSignatures()
            if !existing.isEmpty {
                try database.assetRepository.deleteArchivedItems(relativePaths: Array(existing.keys))
            }
            return .empty
        }

        let didAccess = archiveTreeRoot.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                archiveTreeRoot.stopAccessingSecurityScopedResource()
            }
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: archiveTreeRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            let existing = try database.assetRepository.fetchArchivedSignatures()
            if !existing.isEmpty {
                try database.assetRepository.deleteArchivedItems(relativePaths: Array(existing.keys))
            }
            return .empty
        }

        let existing = try database.assetRepository.fetchArchivedSignatures()
        var seenRelativePaths = Set<String>()
        var upserts: [ArchivedItem] = []
        let now = Date()

        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]
        guard let enumerator = fileManager.enumerator(
            at: archiveTreeRoot,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants, .skipsHiddenFiles]
        ) else {
            return .empty
        }

        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent.hasPrefix(".") {
                continue
            }
            let lowerExtension = fileURL.pathExtension.lowercased()
            guard supportedExtensions.contains(lowerExtension) else { continue }

            let resourceValues = try? fileURL.resourceValues(forKeys: Set(keys))
            guard resourceValues?.isRegularFile == true else { continue }

            let relativePath = fileURL.path.replacingOccurrences(of: archiveTreeRoot.path + "/", with: "")
            guard !relativePath.hasPrefix(".librarian-thumbnails/") else { continue }
            seenRelativePaths.insert(relativePath)

            let fileSize = Int64(resourceValues?.fileSize ?? 0)
            let fileModificationDate = resourceValues?.contentModificationDate ?? now
            if let signature = existing[relativePath],
               signature.fileSizeBytes == fileSize,
               signature.fileModificationDate == fileModificationDate {
                continue
            }

            let metadata = readMetadata(from: fileURL)
            let thumbnailRelativePath = ".librarian-thumbnails/\(sha256Hex(relativePath)).jpg"
            upserts.append(
                ArchivedItem(
                    relativePath: relativePath,
                    absolutePath: fileURL.path,
                    filename: fileURL.lastPathComponent,
                    fileExtension: lowerExtension,
                    fileSizeBytes: fileSize,
                    fileModificationDate: fileModificationDate,
                    captureDate: metadata.captureDate,
                    sortDate: metadata.captureDate ?? fileModificationDate,
                    pixelWidth: metadata.pixelWidth,
                    pixelHeight: metadata.pixelHeight,
                    thumbnailRelativePath: thumbnailRelativePath,
                    lastIndexedAt: now
                )
            )
        }

        let deletedRelativePaths = existing.keys.filter { !seenRelativePaths.contains($0) }
        if !deletedRelativePaths.isEmpty {
            try database.assetRepository.deleteArchivedItems(relativePaths: deletedRelativePaths)
        }
        if !upserts.isEmpty {
            try database.assetRepository.upsertArchivedItems(upserts)
        }
        let unorganizedCount = (try? organizer.scanUnorganizedCount(in: archiveTreeRoot)) ?? 0
        return ArchiveIndexRefreshSummary(unorganizedCount: unorganizedCount)
    }

    private func readMetadata(from fileURL: URL) -> (captureDate: Date?, pixelWidth: Int, pixelHeight: Int) {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return (nil, 0, 0)
        }

        let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int ?? 0

        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            if let date = parseDate(exif[kCGImagePropertyExifDateTimeOriginal] as? String) {
                return (date, pixelWidth, pixelHeight)
            }
            if let date = parseDate(exif[kCGImagePropertyExifDateTimeDigitized] as? String) {
                return (date, pixelWidth, pixelHeight)
            }
        }
        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let date = parseDate(tiff[kCGImagePropertyTIFFDateTime] as? String) {
            return (date, pixelWidth, pixelHeight)
        }

        return (nil, pixelWidth, pixelHeight)
    }

    private func parseDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        return exifDateFormatter.date(from: value)
    }

    private func sha256Hex(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

final class ArchivedThumbnailService: @unchecked Sendable {
    private let queue = DispatchQueue(label: "\(AppBrand.identifierPrefix).archived-thumbnails", qos: .utility)
    private let cache = NSCache<NSString, NSImage>()
    private let fileManager = FileManager.default

    func requestThumbnail(for item: ArchivedItem, targetSize: CGSize, completion: @escaping @Sendable (NSImage?) -> Void) {
        let cacheKey = "\(item.relativePath)#\(Int(max(targetSize.width, targetSize.height)))"
        if let cached = cache.object(forKey: cacheKey as NSString) {
            completion(cached)
            return
        }

        queue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            let image = self.loadOrGenerateThumbnail(for: item, maxPixelSize: Int(max(targetSize.width, targetSize.height)))
            if let image {
                self.cache.setObject(image, forKey: cacheKey as NSString)
            }
            DispatchQueue.main.async {
                completion(image)
            }
        }
    }

    private func loadOrGenerateThumbnail(for item: ArchivedItem, maxPixelSize: Int) -> NSImage? {
        guard let archiveTreeRoot = ArchiveSettings.currentArchiveTreeRootURL() else {
            return nil
        }
        let didAccess = archiveTreeRoot.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                archiveTreeRoot.stopAccessingSecurityScopedResource()
            }
        }

        let sourceURL = URL(fileURLWithPath: item.absolutePath)
        let thumbnailURL = archiveTreeRoot.appendingPathComponent(item.thumbnailRelativePath, isDirectory: false)

        if fileManager.fileExists(atPath: thumbnailURL.path), let cachedImage = NSImage(contentsOf: thumbnailURL) {
            return cachedImage
        }

        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maxPixelSize, 64)
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let directoryURL = thumbnailURL.deletingLastPathComponent()
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        if let destination = CGImageDestinationCreateWithURL(thumbnailURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
            _ = CGImageDestinationFinalize(destination)
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
