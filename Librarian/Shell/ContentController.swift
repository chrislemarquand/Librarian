import Cocoa
import Photos

final class ContentController: NSViewController {

    let model: AppModel

    private let maxGridAssets = 3000
    private var collectionView: NSCollectionView!
    private var scrollView: NSScrollView!
    private var overlayLabel: NSTextField!
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

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            overlayLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            overlayLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        loadAssetsIfNeeded(force: true)
        updateOverlay()
        observeModel()
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
    }

    @objc private func modelStateChanged() {
        if model.photosAuthState == .authorized {
            let shouldForceReload = model.indexedAssetCount != lastLoadedIndexedCount
                || selectedSidebarKind() != lastLoadedSidebarKind
            loadAssetsIfNeeded(force: shouldForceReload)
        }
        updateOverlay()
    }

    @objc private func sidebarSelectionChanged() {
        loadAssetsIfNeeded(force: true)
        updateOverlay()
    }

    private func loadAssetsIfNeeded(force: Bool) {
        guard model.photosAuthState == .authorized else { return }
        let sidebarKind = selectedSidebarKind()
        guard force || displayAssets.isEmpty else { return }
        guard !isLoadingAssets else { return }

        if sidebarKind == .indexing || sidebarKind == .log {
            displayAssets = []
            lastLoadedSidebarKind = sidebarKind
            collectionView.reloadData()
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
            case .indexing, .log:
                assets = []
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.displayAssets = assets
                self.lastLoadedIndexedCount = self.model.indexedAssetCount
                self.lastLoadedSidebarKind = sidebarKind
                self.isLoadingAssets = false
                self.collectionView.reloadData()
                self.syncModelSelectionFromCollection()
                self.updateOverlay()
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
        case .denied, .restricted:
            overlayLabel.stringValue = "Photos access required. Open System Settings to grant access."
            overlayLabel.isHidden = false
            collectionView.isHidden = true
        case .limited:
            overlayLabel.stringValue = "Full Photos access is required. Please update your privacy settings."
            overlayLabel.isHidden = false
            collectionView.isHidden = true
        case .authorized:
            if sidebarKind == .indexing {
                overlayLabel.stringValue = model.isIndexing ? "Indexing your library…" : "Indexing is idle."
                overlayLabel.isHidden = false
                collectionView.isHidden = true
            } else if sidebarKind == .log {
                overlayLabel.stringValue = "Log view is not implemented yet."
                overlayLabel.isHidden = false
                collectionView.isHidden = true
            } else if model.isIndexing {
                overlayLabel.stringValue = "Indexing your library…"
                overlayLabel.isHidden = false
                collectionView.isHidden = true
            } else if isLoadingAssets {
                overlayLabel.stringValue = "Loading indexed assets…"
                overlayLabel.isHidden = false
                collectionView.isHidden = true
            } else if !displayAssets.isEmpty {
                overlayLabel.isHidden = true
                collectionView.isHidden = false
            } else {
                overlayLabel.stringValue = model.indexedAssetCount > 0
                    ? "No assets available to display."
                    : "No indexed assets yet."
                overlayLabel.isHidden = false
                collectionView.isHidden = true
            }
        @unknown default:
            overlayLabel.stringValue = ""
            overlayLabel.isHidden = true
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
extension ContentController {
    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        syncModelSelectionFromCollection()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        syncModelSelectionFromCollection()
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
