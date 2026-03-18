import Cocoa
import Photos

final class ContentController: NSViewController {

    let model: AppModel

    private let galleryPageSize = 600
    private let loadMoreRemainingThreshold: CGFloat = 1800
    private var collectionView: AppKitGalleryCollectionView!
    private let galleryLayout = AppKitGalleryLayout()
    private var scrollView: NSScrollView!
    private var overlayLabel: NSTextField!
    private var screenshotActionBar: NSView!
    private var screenshotSelectionLabel: NSTextField!
    private var screenshotKeepButton: NSButton!
    private var screenshotArchiveButton: NSButton!
    private var screenshotActionBarHeightConstraint: NSLayoutConstraint!
    private var indexingPane: NSView!
    private var indexingStatusLabel: NSTextField!
    private var indexingDetailLabel: NSTextField!
    private var indexingProgressBar: NSProgressIndicator!
    private var logPane: NSView!
    private var logTextView: NSTextView!
    private var logEmptyLabel: NSTextField!
    private var displayAssets: [IndexedAsset] = []
    private var isLoadingAssets = false
    private var canLoadMoreAssets = true
    private var loadGeneration = 0
    private var lastLoadedIndexedCount = -1
    private var lastLoadedAssetDataVersion = -1
    private var lastLoadedSidebarKind: SidebarItem.Kind?
    private var zoomRestoreToken = 0
    private var pinchAccumulator: CGFloat = 0
    private var lastMagnification: CGFloat = 0
    private let pinchThreshold: CGFloat = 0.14
    private var selectionAnchorIndex: Int?

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = NSView()

        collectionView = AppKitGalleryCollectionView()
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
        collectionView.onMoveSelection = { [weak self] direction, extendingSelection in
            self?.moveSelection(direction, extendingSelection: extendingSelection)
        }

        scrollView = NSScrollView()
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        overlayLabel = NSTextField(labelWithString: "")
        overlayLabel.font = NSFont.systemFont(ofSize: 14)
        overlayLabel.textColor = .secondaryLabelColor
        overlayLabel.alignment = .center
        overlayLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(overlayLabel)

        screenshotActionBar = buildScreenshotActionBar()
        screenshotActionBar.translatesAutoresizingMaskIntoConstraints = false
        screenshotActionBar.isHidden = true
        container.addSubview(screenshotActionBar)

        indexingPane = buildIndexingPane()
        indexingPane.translatesAutoresizingMaskIntoConstraints = false
        indexingPane.isHidden = true
        container.addSubview(indexingPane)

        logPane = buildLogPane()
        logPane.translatesAutoresizingMaskIntoConstraints = false
        logPane.isHidden = true
        container.addSubview(logPane)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: screenshotActionBar.topAnchor),

            overlayLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            overlayLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            screenshotActionBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            screenshotActionBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            screenshotActionBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            indexingPane.topAnchor.constraint(equalTo: container.topAnchor),
            indexingPane.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            indexingPane.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            indexingPane.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            logPane.topAnchor.constraint(equalTo: container.topAnchor),
            logPane.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            logPane.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            logPane.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        screenshotActionBarHeightConstraint = screenshotActionBar.heightAnchor.constraint(equalToConstant: 0)
        screenshotActionBarHeightConstraint.isActive = true

        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observeScroll()
        loadAssetsIfNeeded(force: true)
        updateOverlay()
        observeModel()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        model.photosService.stopAllThumbnailCaching()
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
        if selectedSidebarKind() == .setAsideForArchive {
            loadAssetsIfNeeded(force: true)
        }
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
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let recentCutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? .distantPast
            let assets: [IndexedAsset]
            switch sidebarKind {
            case .allPhotos:
                assets = (try? database.assetRepository.fetchForGrid(limit: pageSize, offset: offset)) ?? []
            case .recents:
                assets = (try? database.assetRepository.fetchRecentsForGrid(since: recentCutoff, limit: pageSize, offset: offset)) ?? []
            case .favourites:
                assets = (try? database.assetRepository.fetchFavouritesForGrid(limit: pageSize, offset: offset)) ?? []
            case .screenshots:
                assets = (try? database.assetRepository.fetchScreenshotsForReview(limit: pageSize, offset: offset)) ?? []
            case .setAsideForArchive:
                assets = (try? database.assetRepository.fetchArchiveCandidatesForGrid(limit: pageSize, offset: offset)) ?? []
            case .duplicates:
                assets = (try? database.assetRepository.fetchDuplicatesForGrid(limit: pageSize, offset: offset)) ?? []
            case .lowQuality:
                assets = (try? database.assetRepository.fetchLowQualityForGrid(limit: pageSize, offset: offset)) ?? []
            case .receiptsAndDocuments:
                assets = (try? database.assetRepository.fetchReceiptsAndDocumentsForGrid(limit: pageSize, offset: offset)) ?? []
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
                self.updateOverlay()
                self.updateScreenshotActionBarState()
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
            overlayLabel.stringValue = "Requesting access to Photos…"
            overlayLabel.isHidden = false
            collectionView.isHidden = true
            indexingPane.isHidden = true
            logPane.isHidden = true
        case .denied, .restricted:
            overlayLabel.stringValue = "Photos access required. Open System Settings to grant access."
            overlayLabel.isHidden = false
            collectionView.isHidden = true
            indexingPane.isHidden = true
            logPane.isHidden = true
        case .limited:
            overlayLabel.stringValue = "Full Photos access is required. Please update your privacy settings."
            overlayLabel.isHidden = false
            collectionView.isHidden = true
            indexingPane.isHidden = true
            logPane.isHidden = true
        case .authorized:
            if shouldShowIndexingPane(for: sidebarKind) {
                overlayLabel.isHidden = true
                collectionView.isHidden = true
                indexingPane.isHidden = false
                logPane.isHidden = true
                refreshIndexingPane()
            } else if sidebarKind == .log {
                overlayLabel.isHidden = true
                collectionView.isHidden = true
                indexingPane.isHidden = true
                logPane.isHidden = false
                refreshLogPane()
            } else if model.isIndexing, displayAssets.isEmpty {
                overlayLabel.stringValue = "Indexing your library…"
                overlayLabel.isHidden = false
                collectionView.isHidden = true
                indexingPane.isHidden = true
                logPane.isHidden = true
            } else if isLoadingAssets, displayAssets.isEmpty {
                overlayLabel.stringValue = loadingMessage(for: sidebarKind)
                overlayLabel.isHidden = false
                collectionView.isHidden = true
                indexingPane.isHidden = true
                logPane.isHidden = true
            } else if !displayAssets.isEmpty {
                overlayLabel.isHidden = true
                collectionView.isHidden = false
                indexingPane.isHidden = true
                logPane.isHidden = true
            } else {
                overlayLabel.stringValue = emptyMessage(for: sidebarKind)
                overlayLabel.isHidden = false
                collectionView.isHidden = true
                indexingPane.isHidden = true
                logPane.isHidden = true
            }
            updateScreenshotActionBarState()
        @unknown default:
            overlayLabel.stringValue = ""
            overlayLabel.isHidden = true
            indexingPane.isHidden = true
            logPane.isHidden = true
            updateScreenshotActionBarState()
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
           let index = displayAssets.firstIndex(where: { $0.localIdentifier == selectedIdentifier }) {
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
        switch gesture.state {
        case .began:
            pinchAccumulator = 0
            lastMagnification = 0
        case .changed:
            let delta = gesture.magnification - lastMagnification
            lastMagnification = gesture.magnification
            pinchAccumulator += delta

            while pinchAccumulator >= pinchThreshold {
                model.adjustGalleryGridLevel(by: -1)
                pinchAccumulator -= pinchThreshold
            }
            while pinchAccumulator <= -pinchThreshold {
                model.adjustGalleryGridLevel(by: 1)
                pinchAccumulator += pinchThreshold
            }
        default:
            pinchAccumulator = 0
            lastMagnification = 0
        }
    }

    private func selectedSidebarKind() -> SidebarItem.Kind {
        model.selectedSidebarItem?.kind ?? .allPhotos
    }

    private func loadingMessage(for sidebarKind: SidebarItem.Kind) -> String {
        switch sidebarKind {
        case .allPhotos: return "Loading indexed assets…"
        case .recents: return "Loading photos from the past 30 days…"
        case .favourites: return "Loading favourites…"
        case .screenshots: return "Loading screenshots queue…"
        case .setAsideForArchive: return "Loading archive set-aside queue…"
        case .duplicates: return "Loading duplicates…"
        case .lowQuality: return "Loading low quality photos…"
        case .receiptsAndDocuments: return "Loading receipts and documents…"
        case .indexing: return "Indexing your library…"
        case .log: return "Loading log…"
        }
    }

    private func emptyMessage(for sidebarKind: SidebarItem.Kind) -> String {
        switch sidebarKind {
        case .allPhotos:
            return model.indexedAssetCount > 0 ? "No assets available to display." : "No indexed assets yet."
        case .recents:
            return "No photos from the past 30 days."
        case .favourites:
            return "No favourites found."
        case .screenshots:
            return "No screenshots pending review."
        case .setAsideForArchive:
            return "No photos set aside for archive."
        case .duplicates:
            return "No duplicates found."
        case .lowQuality:
            return "No low quality photos found."
        case .receiptsAndDocuments:
            return "No receipts or documents found."
        case .indexing:
            return "Indexing is idle."
        case .log:
            return "No log entries yet."
        }
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

    private func buildIndexingPane() -> NSView {
        let pane = NSView()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Indexing")
        title.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
        title.textColor = .labelColor

        indexingStatusLabel = NSTextField(labelWithString: "")
        indexingStatusLabel.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        indexingStatusLabel.textColor = .labelColor

        indexingDetailLabel = NSTextField(labelWithString: "")
        indexingDetailLabel.font = NSFont.systemFont(ofSize: 12)
        indexingDetailLabel.textColor = .secondaryLabelColor
        indexingDetailLabel.alignment = .center

        indexingProgressBar = NSProgressIndicator()
        indexingProgressBar.style = .bar
        indexingProgressBar.isIndeterminate = false
        indexingProgressBar.minValue = 0
        indexingProgressBar.maxValue = 1
        indexingProgressBar.doubleValue = 0
        indexingProgressBar.controlSize = .regular
        indexingProgressBar.translatesAutoresizingMaskIntoConstraints = false
        indexingProgressBar.widthAnchor.constraint(equalToConstant: 320).isActive = true

        [title, indexingStatusLabel, indexingProgressBar, indexingDetailLabel].forEach { stack.addArrangedSubview($0) }
        pane.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: pane.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: pane.centerYAnchor),
        ])

        return pane
    }

    private func buildLogPane() -> NSView {
        let pane = NSView()

        let reloadButton = NSButton(title: "Reload", target: self, action: #selector(reloadLogTapped))
        reloadButton.bezelStyle = .rounded
        reloadButton.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(reloadButton)

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

        logEmptyLabel = NSTextField(labelWithString: "No log entries yet.")
        logEmptyLabel.font = NSFont.systemFont(ofSize: 13)
        logEmptyLabel.textColor = .secondaryLabelColor
        logEmptyLabel.alignment = .center
        logEmptyLabel.translatesAutoresizingMaskIntoConstraints = false
        logEmptyLabel.isHidden = true
        pane.addSubview(logEmptyLabel)

        NSLayoutConstraint.activate([
            reloadButton.topAnchor.constraint(equalTo: pane.topAnchor, constant: 14),
            reloadButton.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -20),

            scroll.topAnchor.constraint(equalTo: reloadButton.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: pane.bottomAnchor, constant: -16),

            logEmptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            logEmptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])

        return pane
    }

    private func refreshTaskAndLogPanes() {
        refreshIndexingPane()
        if selectedSidebarKind() == .log {
            refreshLogPane()
        }
    }

    private func refreshIndexingPane() {
        indexingStatusLabel.stringValue = model.indexingProgress.statusText
        indexingDetailLabel.stringValue = "Indexed assets: \(model.indexedAssetCount.formatted())"
        if let fraction = model.indexingProgress.fractionComplete {
            indexingProgressBar.doubleValue = fraction
        } else {
            indexingProgressBar.doubleValue = model.isIndexing ? 0 : 1
        }
    }

    private func refreshLogPane() {
        let text = AppLog.shared.readRecentLines(maxLines: 800)
        logTextView.string = text
        logTextView.sizeToFit()
        logEmptyLabel.isHidden = !text.isEmpty
    }

    @objc private func reloadLogTapped() {
        refreshLogPane()
    }

    private func shouldShowIndexingPane(for sidebarKind: SidebarItem.Kind) -> Bool {
        if sidebarKind == .indexing {
            return true
        }
        if sidebarKind == .allPhotos, model.isIndexing {
            return true
        }
        if sidebarKind == .allPhotos, displayAssets.isEmpty, (isLoadingAssets || model.indexedAssetCount == 0) {
            return true
        }
        return false
    }

    func openSelectionInPhotos() {
        guard let selectedIndex = collectionView.selectionIndexPaths.first?.item,
              selectedIndex >= 0,
              selectedIndex < displayAssets.count else { return }
        let asset = displayAssets[selectedIndex]
        model.photosService.openInPhotos(localIdentifier: asset.localIdentifier)
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
            .map { displayAssets[$0].localIdentifier }
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
            localIdentifier: asset.localIdentifier,
            preferredAspectRatio: preferredAspectRatio,
            tileSide: thumbnailTileSide()
        )

        guard let phAsset = model.photosService.fetchAsset(localIdentifier: asset.localIdentifier) else {
            item.applyImage(nil, forLocalIdentifier: asset.localIdentifier)
            return item
        }

        let targetSize = thumbnailTargetSize()
        _ = model.photosService.requestThumbnail(for: phAsset, targetSize: targetSize) { [weak item] image in
            guard let item else { return }
            item.applyImage(image, forLocalIdentifier: asset.localIdentifier)
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
            let localIdentifier = displayAssets[indexPath.item].localIdentifier
            return model.photosService.fetchAsset(localIdentifier: localIdentifier)
        }
        model.photosService.startCachingThumbnails(for: assets, targetSize: thumbnailTargetSize())
    }

    func collectionView(_ collectionView: NSCollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        let assets = indexPaths.compactMap { indexPath -> PHAsset? in
            guard indexPath.item >= 0, indexPath.item < displayAssets.count else { return nil }
            let localIdentifier = displayAssets[indexPath.item].localIdentifier
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
        guard let selectedIndex = collectionView.selectionIndexPaths.first?.item,
              selectedIndex >= 0,
              selectedIndex < displayAssets.count else {
            model.setSelectedAsset(nil)
            return
        }
        model.setSelectedAsset(displayAssets[selectedIndex])
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

    private func moveSelection(_ direction: MoveCommandDirection, extendingSelection: Bool) {
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

private final class AppKitGalleryLayout: NSCollectionViewFlowLayout {
    var columnCount: Int = 4 {
        didSet {
            if oldValue != columnCount {
                invalidateLayout()
            }
        }
    }

    private let defaultInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
    private let horizontalSpacing: CGFloat = 14
    private let verticalSpacing: CGFloat = 16

    var tileSide: CGFloat {
        max(40, floor(itemSize.width))
    }

    override init() {
        super.init()
        sectionInset = defaultInsets
        minimumInteritemSpacing = horizontalSpacing
        minimumLineSpacing = verticalSpacing
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }

        let columns = max(columnCount, 1)
        let usableWidth = max(
            collectionView.bounds.width - sectionInset.left - sectionInset.right - CGFloat(columns - 1) * minimumInteritemSpacing,
            1
        )
        let side = max(1, floor(usableWidth / CGFloat(columns)))
        itemSize = NSSize(width: side, height: side)
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        true
    }
}

private enum MoveCommandDirection {
    case left
    case right
    case up
    case down
}

private final class AppKitGalleryCollectionView: NSCollectionView {
    var onBackgroundClick: (() -> Void)?
    var onMoveSelection: ((MoveCommandDirection, Bool) -> Void)?
    var onModifiedItemClick: ((IndexPath, NSEvent.ModifierFlags) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let indexPath = indexPathForItem(at: point) else {
            deselectAll(nil)
            onBackgroundClick?()
            return
        }

        let selectionModifiers = event.modifierFlags.intersection([.command, .shift])
        if !selectionModifiers.isEmpty {
            onModifiedItemClick?(indexPath, selectionModifiers)
            return
        }

        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .control, .option, .function]).isEmpty,
           event.keyCode == 53 { // Escape
            deselectAll(nil)
            onBackgroundClick?()
            return
        }

        let movementModifiers = event.modifierFlags.intersection([.shift, .command, .control, .option, .function])
        if movementModifiers.subtracting([.shift]).isEmpty {
            let extendingSelection = movementModifiers.contains(.shift)
            let direction: MoveCommandDirection?
            switch event.keyCode {
            case 123: direction = .left
            case 124: direction = .right
            case 125: direction = .down
            case 126: direction = .up
            default: direction = nil
            }
            if let direction {
                onMoveSelection?(direction, extendingSelection)
                return
            }
        }

        super.keyDown(with: event)
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
    private let thumbnailCornerRadius: CGFloat = 8
    private let imageInset: CGFloat = 4
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
