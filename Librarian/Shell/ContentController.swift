import Cocoa
import Photos

final class ContentController: NSViewController {

    let model: AppModel

    private var collectionView: NSCollectionView!
    private var scrollView: NSScrollView!
    private var overlayLabel: NSTextField!

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
    }

    @objc private func modelStateChanged() {
        updateOverlay()
    }

    private func updateOverlay() {
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
            if model.isIndexing {
                overlayLabel.stringValue = "Indexing your library…"
                overlayLabel.isHidden = false
                collectionView.isHidden = true
            } else {
                if model.indexedAssetCount > 0 {
                    overlayLabel.stringValue = "Indexed \(model.indexedAssetCount.formatted()) assets. Grid view wiring is next."
                } else {
                    overlayLabel.stringValue = "No indexed assets yet."
                }
                overlayLabel.isHidden = false
                collectionView.isHidden = true
            }
        @unknown default:
            overlayLabel.stringValue = ""
            overlayLabel.isHidden = true
        }
    }
}
