import Cocoa

extension NSToolbarItem.Identifier {
    static let librarianSidebarSeparator  = NSToolbarItem.Identifier("com.librarian.app.toolbar.sidebarSeparator")
    static let librarianInspectorSeparator = NSToolbarItem.Identifier("com.librarian.app.toolbar.inspectorSeparator")
    static let librarianIndexingProgress  = NSToolbarItem.Identifier("com.librarian.app.toolbar.indexingProgress")
    static let librarianToggleInspector   = NSToolbarItem.Identifier("com.librarian.app.toolbar.toggleInspector")
}

final class ToolbarDelegate: NSObject, NSToolbarDelegate {

    private weak var splitVC: MainSplitViewController?
    private weak var progressSpinner: NSProgressIndicator?
    private weak var inspectorToggleItem: NSToolbarItem?

    func configure(splitVC: MainSplitViewController) {
        self.splitVC = splitVC
    }

    func refresh(model: AppModel) {
        updateProgressSpinner(model: model)
        updateInspectorToggle(model: model)
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .toggleSidebar,
            .librarianSidebarSeparator,
            .librarianIndexingProgress,
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
}
