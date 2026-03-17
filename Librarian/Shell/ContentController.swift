import Cocoa
import Photos

final class ContentController: NSViewController {

    let model: AppModel

    private let maxGridAssets = 3000
    private var collectionView: NSCollectionView!
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
    private var lastLoadedIndexedCount = -1
    private var lastLoadedSidebarKind: SidebarItem.Kind?

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = NSView()

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 160, height: 160)
        layout.minimumInteritemSpacing = 2
        layout.minimumLineSpacing = 2
        layout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        collectionView = NSCollectionView()
        collectionView.collectionViewLayout = layout
        collectionView.backgroundColors = [.clear]
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.register(AssetGridItem.self, forItemWithIdentifier: .assetGridItem)

        scrollView = NSScrollView()
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
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
        loadAssetsIfNeeded(force: true)
        updateOverlay()
        observeModel()
    }

    deinit {
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
    }

    @objc private func modelStateChanged() {
        if model.photosAuthState == .authorized {
            let shouldForceReload = model.indexedAssetCount != lastLoadedIndexedCount
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

    private func loadAssetsIfNeeded(force: Bool) {
        guard model.photosAuthState == .authorized else { return }
        let sidebarKind = selectedSidebarKind()
        guard force || displayAssets.isEmpty else { return }
        guard !isLoadingAssets else { return }

        if sidebarKind == .indexing || sidebarKind == .log {
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

        isLoadingAssets = true
        updateOverlay()

        let database = model.database
        let maxGridAssets = self.maxGridAssets
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let recentCutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? .distantPast
            let assets: [IndexedAsset]
            switch sidebarKind {
            case .allPhotos:
                assets = (try? database.assetRepository.fetchForGrid(limit: maxGridAssets)) ?? []
            case .recents:
                assets = (try? database.assetRepository.fetchRecentsForGrid(since: recentCutoff, limit: maxGridAssets)) ?? []
            case .favourites:
                assets = (try? database.assetRepository.fetchFavouritesForGrid(limit: maxGridAssets)) ?? []
            case .screenshots:
                assets = (try? database.assetRepository.fetchScreenshotsForReview(limit: maxGridAssets)) ?? []
            case .indexing, .log:
                assets = []
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.displayAssets = assets
                self.lastLoadedIndexedCount = self.model.indexedAssetCount
                self.lastLoadedSidebarKind = sidebarKind
                self.isLoadingAssets = false
                self.model.photosService.stopAllThumbnailCaching()
                self.collectionView.reloadData()
                self.syncModelSelectionFromCollection()
                self.updateOverlay()
                self.updateScreenshotActionBarState()
            }
        }
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
            } else if isLoadingAssets {
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
        let size = (collectionView.collectionViewLayout as? NSCollectionViewFlowLayout)?.itemSize ?? NSSize(width: 160, height: 160)
        let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        return CGSize(width: size.width * scale, height: size.height * scale)
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

        screenshotArchiveButton = NSButton(title: "Archive Candidate", target: self, action: #selector(markScreenshotsArchiveCandidate))
        screenshotArchiveButton.bezelStyle = .rounded
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
        if sidebarKind == .allPhotos, displayAssets.isEmpty, (model.isIndexing || isLoadingAssets || model.indexedAssetCount == 0) {
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
        applyScreenshotDecision(.keep)
    }

    @objc private func markScreenshotsArchiveCandidate() {
        applyScreenshotDecision(.archiveCandidate)
    }

    private func applyScreenshotDecision(_ decision: ScreenshotReviewDecision) {
        guard selectedSidebarKind() == .screenshots else { return }
        let selectedAssets = selectedAssetIdentifiers()
        guard !selectedAssets.isEmpty else { return }
        do {
            try model.database.assetRepository.setScreenshotDecision(identifiers: selectedAssets, decision: decision)
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

    private func updateScreenshotActionBarState() {
        let isScreenshots = selectedSidebarKind() == .screenshots
        let hasGridVisible = !collectionView.isHidden
        let shouldShow = isScreenshots && hasGridVisible && !displayAssets.isEmpty
        screenshotActionBar.isHidden = !shouldShow
        screenshotActionBarHeightConstraint.constant = shouldShow ? 44 : 0

        guard shouldShow else { return }
        let selectionCount = selectedAssetIdentifiers().count
        screenshotSelectionLabel.stringValue = selectionCount > 0
            ? "\(selectionCount) selected"
            : "Select screenshots to review"
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
        item.prepare(localIdentifier: asset.localIdentifier)

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
}

// MARK: - Item identifier

private extension NSUserInterfaceItemIdentifier {
    static let assetGridItem = NSUserInterfaceItemIdentifier("AssetGridItem")
}

// MARK: - Asset grid item

private final class AssetGridItem: NSCollectionViewItem {

    private let fallback = NSImageView()
    private var representedLocalIdentifier: String?

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 4
        view.layer?.masksToBounds = true
        view.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.15).cgColor
        view.layer?.borderWidth = 0
        view.layer?.borderColor = NSColor.controlAccentColor.cgColor

        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleAxesIndependently
        imageView.animates = true
        self.imageView = imageView
        view.addSubview(imageView)

        fallback.translatesAutoresizingMaskIntoConstraints = false
        fallback.image = NSImage(systemSymbolName: "photo", accessibilityDescription: "Photo")
        fallback.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        fallback.contentTintColor = .tertiaryLabelColor
        view.addSubview(fallback)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: view.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            fallback.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            fallback.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        representedLocalIdentifier = nil
        imageView?.image = nil
        fallback.isHidden = false
        isSelected = false
    }

    func prepare(localIdentifier: String) {
        representedLocalIdentifier = localIdentifier
        imageView?.image = nil
        fallback.isHidden = false
    }

    func applyImage(_ image: NSImage?, forLocalIdentifier identifier: String) {
        guard representedLocalIdentifier == identifier else { return }
        imageView?.image = image
        fallback.isHidden = image != nil
    }

    override var isSelected: Bool {
        didSet {
            view.layer?.borderWidth = isSelected ? 3 : 0
        }
    }
}
