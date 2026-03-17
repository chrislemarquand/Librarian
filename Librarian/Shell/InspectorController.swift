import Cocoa

final class InspectorController: NSViewController {

    let model: AppModel

    private var scrollView: NSScrollView!
    private var stackView: NSStackView!
    private var emptyLabel: NSTextField!

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true

        emptyLabel = NSTextField(labelWithString: "No Selection")
        emptyLabel.font = NSFont.systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(emptyLabel)

        stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 12
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.isHidden = true

        scrollView = NSScrollView()
        scrollView.documentView = stackView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        showEmpty()
    }

    // MARK: - State

    func showEmpty() {
        emptyLabel.isHidden = false
        scrollView.isHidden = true
    }

    // Phase 2 will populate the stack with preview + metadata rows
    func showAsset(_ asset: IndexedAsset) {
        emptyLabel.isHidden = true
        scrollView.isHidden = false
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        // Populated in Phase 2
        _ = asset
    }
}
