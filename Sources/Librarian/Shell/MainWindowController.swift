import Cocoa
import SharedUI

@MainActor
final class MainWindowController: NSWindowController {

    let appModel: AppModel
    private var toolbarAppearanceAdapter: ToolbarAppearanceAdapter?

    var splitController: MainSplitViewController? {
        contentViewController as? MainSplitViewController
    }

    init(model: AppModel) {
        appModel = model
        let splitVC = MainSplitViewController(model: model)
        let window = NSWindow(contentViewController: splitVC)
        window.setContentSize(ThreePaneSplitViewController.Metrics.windowDefault)
        window.minSize = ThreePaneSplitViewController.Metrics.windowMinimum
        window.title = AppBrand.displayName
        window.isReleasedWhenClosed = false
        window.isRestorable = true
        window.setFrameAutosaveName("\(AppBrand.identifierPrefix).MainWindow")
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        MainActor.assumeIsolated {
            toolbarAppearanceAdapter?.invalidate()
        }
    }

    override func showWindow(_ sender: Any?) {
        // Configure the window before it becomes visible — same as Ledger's viewWillAppear pattern.
        // Doing this after super.showWindow causes a compositor flash on macOS 26.
        if let window, window.toolbar == nil {
            configureWindowForToolbar(window)
            installToolbar(resetDelegateState: true)
        }
        if toolbarAppearanceAdapter == nil, let window {
            toolbarAppearanceAdapter = ToolbarAppearanceAdapter(window: window) { [weak self] in
                self?.rebuildToolbarForCurrentAppearance()
            }
        }
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Toolbar

    private func installToolbar(resetDelegateState: Bool) {
        guard let splitVC = splitController, let window else { return }
        if resetDelegateState {
            splitVC.toolbarDelegate.resetCachedToolbarReferences()
        }
        let toolbar = NSToolbar(identifier: "\(AppBrand.identifierPrefix).MainToolbar")
        toolbar.delegate = splitVC.toolbarDelegate
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window.toolbar = toolbar
    }

    private func rebuildToolbarForCurrentAppearance() {
        guard let splitVC = splitController else { return }
        installToolbar(resetDelegateState: true)
        splitVC.toolbarDelegate.refresh(model: appModel)
        window?.toolbar?.validateVisibleItems()
    }
}
