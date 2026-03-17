import Cocoa
import Photos

final class InspectorController: NSViewController {

    let model: AppModel

    private var scrollView: NSScrollView!
    private var documentView: NSView!
    private var stackView: NSStackView!
    private var emptyLabel: NSTextField!
    private var previewImageView: NSImageView!
    private var representedPreviewIdentifier: String?

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

        previewImageView = NSImageView()
        previewImageView.imageScaling = .scaleProportionallyUpOrDown
        previewImageView.wantsLayer = true
        previewImageView.layer?.cornerRadius = 8
        previewImageView.layer?.masksToBounds = true
        previewImageView.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.15).cgColor
        previewImageView.translatesAutoresizingMaskIntoConstraints = false
        previewImageView.heightAnchor.constraint(equalToConstant: 180).isActive = true
        previewImageView.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true

        documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stackView)

        scrollView = NSScrollView()
        scrollView.documentView = documentView
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

            stackView.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 16),
            stackView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 16),
            stackView.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -16),
            stackView.bottomAnchor.constraint(lessThanOrEqualTo: documentView.bottomAnchor, constant: -16),
            stackView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor, constant: -32),
        ])

        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observeModel()
        refreshForSelection()
    }

    // MARK: - State

    func showEmpty() {
        emptyLabel.isHidden = false
        scrollView.isHidden = true
        stackView.isHidden = true
        representedPreviewIdentifier = nil
        previewImageView.image = nil
    }

    // Phase 2 will populate the stack with preview + metadata rows
    func showAsset(_ asset: IndexedAsset) {
        emptyLabel.isHidden = true
        scrollView.isHidden = false
        stackView.isHidden = false
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        stackView.addArrangedSubview(previewImageView)
        previewImageView.image = nil
        representedPreviewIdentifier = asset.localIdentifier
        requestPreviewImage(for: asset.localIdentifier)
        stackView.addArrangedSubview(makeTitleLabel("Asset Details"))
        stackView.addArrangedSubview(makeRow(title: "Local Identifier", value: asset.localIdentifier))
        stackView.addArrangedSubview(makeRow(title: "Type", value: mediaTypeLabel(for: asset.mediaType)))
        stackView.addArrangedSubview(makeRow(title: "Captured", value: formattedDate(asset.creationDate)))
        stackView.addArrangedSubview(makeRow(title: "Modified", value: formattedDate(asset.modificationDate)))
        stackView.addArrangedSubview(makeRow(title: "Dimensions", value: dimensionsText(width: asset.pixelWidth, height: asset.pixelHeight)))
        stackView.addArrangedSubview(makeRow(title: "Favorite", value: yesNo(asset.isFavorite)))
        stackView.addArrangedSubview(makeRow(title: "Hidden", value: yesNo(asset.isHidden)))
        stackView.addArrangedSubview(makeRow(title: "Cloud State", value: asset.iCloudDownloadState))
        stackView.addArrangedSubview(makeRow(title: "Local Thumbnail", value: yesNo(asset.hasLocalThumbnail)))
        stackView.addArrangedSubview(makeRow(title: "Local Original", value: yesNo(asset.hasLocalOriginal)))
        stackView.addArrangedSubview(makeRow(title: "Deleted In Photos", value: yesNo(asset.isDeletedFromPhotos)))
    }

    // MARK: - Model observation

    private func observeModel() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(selectionChanged),
            name: .librarianSelectionChanged,
            object: nil
        )
    }

    @objc private func selectionChanged() {
        refreshForSelection()
    }

    private func refreshForSelection() {
        if let asset = model.selectedAsset {
            showAsset(asset)
        } else {
            showEmpty()
        }
    }

    private func makeTitleLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .labelColor
        return label
    }

    private func makeRow(title: String, value: String) -> NSView {
        let titleLabel = NSTextField(labelWithString: title.uppercased())
        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor

        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        valueLabel.textColor = .labelColor
        valueLabel.lineBreakMode = .byTruncatingMiddle
        valueLabel.maximumNumberOfLines = 2

        let row = NSStackView(views: [titleLabel, valueLabel])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 2
        return row
    }

    private func formattedDate(_ date: Date?) -> String {
        guard let date else { return "Unknown" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func dimensionsText(width: Int, height: Int) -> String {
        guard width > 0, height > 0 else { return "Unknown" }
        return "\(width) × \(height)"
    }

    private func yesNo(_ value: Bool) -> String {
        value ? "Yes" : "No"
    }

    private func mediaTypeLabel(for value: Int) -> String {
        switch value {
        case 1: return "Image"
        case 2: return "Video"
        case 3: return "Audio"
        default: return "Unknown (\(value))"
        }
    }

    private func requestPreviewImage(for localIdentifier: String) {
        guard let asset = model.photosService.fetchAsset(localIdentifier: localIdentifier) else { return }
        _ = model.photosService.requestThumbnail(
            for: asset,
            targetSize: CGSize(width: 520, height: 520),
            deliveryMode: .highQualityFormat
        ) { [weak self] image in
            guard let self, self.representedPreviewIdentifier == localIdentifier else { return }
            self.previewImageView.image = image
        }
    }
}
