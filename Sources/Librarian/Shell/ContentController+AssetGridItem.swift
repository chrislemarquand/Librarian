import Cocoa
import SharedUI

// MARK: - Item identifier

extension NSUserInterfaceItemIdentifier {
    static let assetGridItem = NSUserInterfaceItemIdentifier("AssetGridItem")
}

// MARK: - Asset grid item

final class AssetGridItem: NSCollectionViewItem {

    private let fallback = NSImageView()
    private let selectionBackgroundView = NSView()
    private let thumbnailCornerRadius: CGFloat = GalleryMetrics.default.thumbnailCornerRadius
    private let imageInset: CGFloat = GalleryMetrics.default.imageInset
    private var representedLocalIdentifier: String?
    private var preferredAspectRatio: CGFloat?
    private var currentTileSide: CGFloat = 160
    private var imageWidthConstraint: NSLayoutConstraint?
    private var imageHeightConstraint: NSLayoutConstraint?
    private var sharedLibraryBadgeView: NSImageView?

    var thumbnailImageView: NSView {
        imageView ?? view
    }

    override func loadView() {
        let rootView = AppearanceAwareView()
        rootView.onEffectiveAppearanceChange = { [weak self] in
            self?.applySelectionState()
        }
        view = rootView
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

        let sharedBadge = NSImageView()
        sharedBadge.translatesAutoresizingMaskIntoConstraints = false
        sharedBadge.image = NSImage(systemSymbolName: "person.2.fill", accessibilityDescription: "Shared library")
        sharedBadge.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        sharedBadge.contentTintColor = .white
        sharedBadge.wantsLayer = true
        sharedBadge.layer?.shadowColor = NSColor.black.cgColor
        sharedBadge.layer?.shadowOpacity = 0.35
        sharedBadge.layer?.shadowRadius = 1.0
        sharedBadge.layer?.shadowOffset = CGSize(width: 0, height: -0.5)
        sharedBadge.isHidden = true
        imageView.addSubview(sharedBadge)
        sharedLibraryBadgeView = sharedBadge

        NSLayoutConstraint.activate([
            selectionBackgroundView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            selectionBackgroundView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            selectionBackgroundView.topAnchor.constraint(equalTo: view.topAnchor),
            selectionBackgroundView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            imageView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            fallback.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            fallback.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            sharedBadge.topAnchor.constraint(equalTo: imageView.topAnchor, constant: 6),
            sharedBadge.trailingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: -6),
            sharedBadge.widthAnchor.constraint(equalToConstant: 15),
            sharedBadge.heightAnchor.constraint(equalToConstant: 10),
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
        sharedLibraryBadgeView?.isHidden = true
        isSelected = false
    }

    func prepare(localIdentifier: String, preferredAspectRatio: CGFloat?, tileSide: CGFloat, showsSharedLibraryBadge: Bool) {
        representedLocalIdentifier = localIdentifier
        self.preferredAspectRatio = preferredAspectRatio
        imageView?.image = nil
        fallback.isHidden = false
        sharedLibraryBadgeView?.isHidden = !showsSharedLibraryBadge
        updateTileSide(tileSide)
    }

    func applyImage(_ image: NSImage?, forLocalIdentifier identifier: String) {
        guard representedLocalIdentifier == identifier else { return }
        imageView?.image = image
        fallback.isHidden = image != nil
        updateGeometry()
    }

    override var isSelected: Bool {
        didSet { applySelectionState() }
    }

    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet { applySelectionState() }
    }

    func refreshSelectionAppearance() {
        applySelectionState()
    }

    private func applySelectionState() {
        let selectionCGColor = GallerySelectionStyling.resolvedTileSelectionBackgroundCGColor(for: view)
        let active = isSelected || highlightState == .forSelection
        selectionBackgroundView.layer?.backgroundColor = active
            ? selectionCGColor
            : NSColor.clear.cgColor
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
