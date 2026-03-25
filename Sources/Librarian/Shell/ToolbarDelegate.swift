import Cocoa
import SharedUI

extension NSToolbarItem.Identifier {
    private static var prefix: String { "\(AppBrand.identifierPrefix).toolbar" }
    static let librarianSidebarSeparator  = NSToolbarItem.Identifier("\(prefix).sidebarSeparator")
    static let librarianInspectorSeparator = NSToolbarItem.Identifier("\(prefix).inspectorSeparator")
    static let librarianIndexingProgress  = NSToolbarItem.Identifier("\(prefix).indexingProgress")
    static let librarianZoomOut           = NSToolbarItem.Identifier("\(prefix).zoomOut")
    static let librarianZoomIn            = NSToolbarItem.Identifier("\(prefix).zoomIn")
    static let librarianSetAside          = NSToolbarItem.Identifier("\(prefix).setAside")
    static let librarianPutBack           = NSToolbarItem.Identifier("\(prefix).putBack")
    static let librarianSendToArchive     = NSToolbarItem.Identifier("\(prefix).sendToArchive")
    static let librarianToggleInspector   = NSToolbarItem.Identifier("\(prefix).toggleInspector")
}

@MainActor
final class ToolbarDelegate: NSObject, ToolbarShellContent {

    private weak var splitVC: MainSplitViewController?
    private weak var progressSpinner: NSProgressIndicator?
    private weak var zoomOutItem: NSToolbarItem?
    private weak var zoomInItem: NSToolbarItem?
    private weak var setAsideItem: NSToolbarItem?
    private weak var putBackItem: NSToolbarItem?
    private weak var sendToArchiveItem: NSToolbarItem?
    private weak var inspectorToggleItem: NSToolbarItem?

    func configure(splitVC: MainSplitViewController) {
        self.splitVC = splitVC
    }

    func resetCachedToolbarReferences() {
        progressSpinner = nil
        zoomOutItem = nil
        zoomInItem = nil
        setAsideItem = nil
        putBackItem = nil
        sendToArchiveItem = nil
        inspectorToggleItem = nil
    }

    func refresh(model: AppModel) {
        updateProgressSpinner(model: model)
        updateZoomItems(model: model)
        updateArchiveItems(model: model)
        updateInspectorToggle(model: model)
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .flexibleSpace,
            .toggleSidebar,
            .librarianSidebarSeparator,
            .librarianIndexingProgress,
            .librarianZoomOut,
            .librarianZoomIn,
            .space,
            .librarianSetAside,
            .space,
            .librarianSendToArchive,
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
                splitView: splitVC.innerSplitView,
                dividerIndex: 0
            )

        case .librarianIndexingProgress:
            let spinnerItem = ToolbarItemFactory.makeSpinnerItem(
                identifier: itemIdentifier,
                label: "Activity",
                paletteLabel: "Activity"
            )
            let item = spinnerItem.item
            progressSpinner = spinnerItem.spinner

            if let model = splitVC?.model {
                updateProgressSpinner(model: model)
            }
            return item

        case .librarianToggleInspector:
            let label = splitVC?.model.isInspectorCollapsed == true ? "Show Inspector" : "Hide Inspector"
            let item = ToolbarItemFactory.makeInspectorToggleItem(
                identifier: itemIdentifier,
                label: label,
                action: #selector(MainSplitViewController.toggleInspector(_:)),
                toolTip: label
            )
            inspectorToggleItem = item
            return item

        case .librarianZoomOut:
            let item = ToolbarItemFactory.makeZoomItem(
                identifier: itemIdentifier,
                direction: .zoomOut,
                target: splitVC,
                action: #selector(MainSplitViewController.zoomOutAction(_:)),
                accessibilityDescription: "Zoom Out"
            )
            zoomOutItem = item
            if let model = splitVC?.model {
                updateZoomItems(model: model)
            }
            return item

        case .librarianZoomIn:
            let item = ToolbarItemFactory.makeZoomItem(
                identifier: itemIdentifier,
                direction: .zoomIn,
                target: splitVC,
                action: #selector(MainSplitViewController.zoomInAction(_:)),
                accessibilityDescription: "Zoom In"
            )
            zoomInItem = item
            if let model = splitVC?.model {
                updateZoomItems(model: model)
            }
            return item

        case .librarianSetAside:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Set Aside"
            item.paletteLabel = "Set Aside"
            item.image = NSImage(systemSymbolName: "tray.and.arrow.down", accessibilityDescription: "Set Aside for Archive")
            item.autovalidates = false
            item.target = splitVC
            item.action = #selector(MainSplitViewController.setAsideSelectionAction(_:))
            item.toolTip = "Set selected photos aside for Archive"
            setAsideItem = item
            if let model = splitVC?.model {
                updateArchiveItems(model: model)
            }
            return item

        case .librarianSendToArchive:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Send to Archive"
            item.paletteLabel = "Send to Archive"
            item.image = NSImage(systemSymbolName: "archivebox", accessibilityDescription: "Send to Archive")
            item.autovalidates = false
            item.target = splitVC
            item.action = #selector(MainSplitViewController.sendToArchiveAction(_:))
            item.toolTip = "Export set-aside photos and delete from Photos"
            sendToArchiveItem = item
            if let model = splitVC?.model {
                updateArchiveItems(model: model)
            }
            return item

        case .librarianPutBack:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Put Back"
            item.paletteLabel = "Put Back"
            item.image = NSImage(systemSymbolName: "arrow.uturn.left.circle", accessibilityDescription: "Put Back")
            item.autovalidates = false
            item.target = splitVC
            item.action = #selector(MainSplitViewController.putBackSelectionAction(_:))
            item.toolTip = "Remove selected photos from the Set Aside box"
            putBackItem = item
            if let model = splitVC?.model {
                updateArchiveItems(model: model)
            }
            return item

        default:
            return nil
        }
    }

    // MARK: - State updates

    private func updateProgressSpinner(model: AppModel) {
        guard let spinner = progressSpinner else { return }
        if model.isIndexing || model.isSendingArchive || model.isAnalysing {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
    }

    private func updateInspectorToggle(model: AppModel) {
        guard let item = inspectorToggleItem else { return }
        let label = model.isInspectorCollapsed ? "Show Inspector" : "Hide Inspector"
        item.label = label
        item.toolTip = label
        item.isEnabled = true
    }

    private func updateZoomItems(model: AppModel) {
        let isGalleryContext: Bool
        switch model.selectedSidebarItem?.kind ?? .allPhotos {
        case .allPhotos, .recents, .favourites, .screenshots, .setAsideForArchive, .archived,
             .duplicates, .lowQuality, .receiptsAndDocuments, .whatsapp:
            isGalleryContext = true
        }
        zoomOutItem?.isEnabled = isGalleryContext && model.canDecreaseGalleryZoom
        zoomInItem?.isEnabled = isGalleryContext && model.canIncreaseGalleryZoom
    }

    private func updateArchiveItems(model: AppModel) {
        setAsideItem?.isEnabled = splitVC?.canSetAsideSelection == true && !model.isSendingArchive
        let canPutBackSelection = splitVC?.canPutBackSelection == true
        let canPutBackFailed = splitVC?.canPutBackFailedItems == true
        putBackItem?.isEnabled = canPutBackSelection || canPutBackFailed
        if canPutBackSelection {
            putBackItem?.toolTip = "Remove selected photos from the Set Aside box"
        } else if canPutBackFailed {
            putBackItem?.toolTip = "Remove all failed items from the Set Aside box"
        } else {
            putBackItem?.toolTip = "Remove selected photos from the Set Aside box"
        }
        let hasQueuedItems = model.pendingArchiveCandidateCount > 0
        sendToArchiveItem?.isEnabled = hasQueuedItems && !model.isSendingArchive
        sendToArchiveItem?.style = hasQueuedItems ? .prominent : .plain
    }

    func syncToolbarState() {
        guard let model = splitVC?.model else { return }
        refresh(model: model)
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        guard let model = splitVC?.model else { return false }
        updateProgressSpinner(model: model)
        updateZoomItems(model: model)
        updateArchiveItems(model: model)
        updateInspectorToggle(model: model)

        switch item.itemIdentifier {
        case .librarianZoomOut:
            return zoomOutItem?.isEnabled ?? false
        case .librarianZoomIn:
            return zoomInItem?.isEnabled ?? false
        case .librarianSetAside:
            return setAsideItem?.isEnabled ?? false
        case .librarianPutBack:
            return putBackItem?.isEnabled ?? false
        case .librarianSendToArchive:
            return sendToArchiveItem?.isEnabled ?? false
        case .librarianToggleInspector, .librarianSidebarSeparator, .librarianInspectorSeparator, .librarianIndexingProgress:
            return true
        default:
            return true
        }
    }
}
