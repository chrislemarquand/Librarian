import Cocoa

extension NSToolbarItem.Identifier {
    static let librarianSidebarSeparator  = NSToolbarItem.Identifier("com.librarian.app.toolbar.sidebarSeparator")
    static let librarianInspectorSeparator = NSToolbarItem.Identifier("com.librarian.app.toolbar.inspectorSeparator")
    static let librarianIndexingProgress  = NSToolbarItem.Identifier("com.librarian.app.toolbar.indexingProgress")
    static let librarianZoomOut           = NSToolbarItem.Identifier("com.librarian.app.toolbar.zoomOut")
    static let librarianZoomIn            = NSToolbarItem.Identifier("com.librarian.app.toolbar.zoomIn")
    static let librarianToggleInspector   = NSToolbarItem.Identifier("com.librarian.app.toolbar.toggleInspector")
}

final class ToolbarDelegate: NSObject, NSToolbarDelegate {

    private weak var splitVC: MainSplitViewController?
    private weak var progressSpinner: NSProgressIndicator?
    private weak var zoomOutItem: NSToolbarItem?
    private weak var zoomInItem: NSToolbarItem?
    private weak var inspectorToggleItem: NSToolbarItem?

    func configure(splitVC: MainSplitViewController) {
        self.splitVC = splitVC
    }

    func resetCachedToolbarReferences() {
        progressSpinner = nil
        zoomOutItem = nil
        zoomInItem = nil
        inspectorToggleItem = nil
    }

    func refresh(model: AppModel) {
        updateProgressSpinner(model: model)
        updateZoomItems(model: model)
        updateInspectorToggle(model: model)
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .toggleSidebar,
            .librarianSidebarSeparator,
            .librarianIndexingProgress,
            .librarianZoomOut,
            .librarianZoomIn,
            .flexibleSpace,
            .librarianInspectorSeparator,
            .librarianToggleInspector,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {

        case .librarianSidebarSeparator:
            guard let splitVC else { return nil }
            return NSTrackingSeparatorToolbarItem(
                identifier: .librarianSidebarSeparator,
                splitView: splitVC.splitView,
                dividerIndex: 0
            )

        case .librarianInspectorSeparator:
            guard let splitVC else { return nil }
            return NSTrackingSeparatorToolbarItem(
                identifier: .librarianInspectorSeparator,
                splitView: splitVC.innerSplit.splitView,
                dividerIndex: 0
            )

        case .librarianIndexingProgress:
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.isDisplayedWhenStopped = false
            spinner.translatesAutoresizingMaskIntoConstraints = false

            let container = NSView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
            container.addSubview(spinner)
            NSLayoutConstraint.activate([
                spinner.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                spinner.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            ])

            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = container
            item.visibilityPriority = .low
            item.label = "Activity"
            progressSpinner = spinner

            if let model = splitVC?.model {
                updateProgressSpinner(model: model)
            }
            return item

        case .librarianToggleInspector:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Inspector"
            item.image = NSImage(systemSymbolName: "sidebar.trailing", accessibilityDescription: "Toggle Inspector")
            item.target = splitVC
            item.action = #selector(MainSplitViewController.toggleInspector(_:))
            item.isBordered = true
            inspectorToggleItem = item

            if let model = splitVC?.model {
                updateInspectorToggle(model: model)
            }
            return item

        case .librarianZoomOut:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Zoom Out"
            item.paletteLabel = "Zoom Out"
            item.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "Zoom Out")
            item.autovalidates = false
            item.target = splitVC
            item.action = #selector(MainSplitViewController.zoomOutAction(_:))
            item.toolTip = "Zoom out"
            zoomOutItem = item
            if let model = splitVC?.model {
                updateZoomItems(model: model)
            }
            return item

        case .librarianZoomIn:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Zoom In"
            item.paletteLabel = "Zoom In"
            item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Zoom In")
            item.autovalidates = false
            item.target = splitVC
            item.action = #selector(MainSplitViewController.zoomInAction(_:))
            item.toolTip = "Zoom in"
            zoomInItem = item
            if let model = splitVC?.model {
                updateZoomItems(model: model)
            }
            return item

        default:
            return nil
        }
    }

    // MARK: - State updates

    private func updateProgressSpinner(model: AppModel) {
        guard let spinner = progressSpinner else { return }
        if model.isIndexing {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
    }

    private func updateInspectorToggle(model: AppModel) {
        guard let item = inspectorToggleItem else { return }
        item.label = model.isInspectorCollapsed ? "Show Inspector" : "Hide Inspector"
    }

    private func updateZoomItems(model: AppModel) {
        let isGalleryContext: Bool
        switch model.selectedSidebarItem?.kind ?? .allPhotos {
        case .allPhotos, .recents, .favourites, .screenshots:
            isGalleryContext = true
        case .indexing, .log:
            isGalleryContext = false
        }
        zoomOutItem?.isEnabled = isGalleryContext && model.canDecreaseGalleryZoom
        zoomInItem?.isEnabled = isGalleryContext && model.canIncreaseGalleryZoom
    }
}
