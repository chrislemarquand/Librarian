import Cocoa
import SharedUI

@MainActor
final class MainWindowController: NSWindowController {

    let appModel: AppModel
    private var framePersistenceController: WindowFramePersistenceController?

    var splitController: MainSplitViewController? {
        contentViewController as? MainSplitViewController
    }

    init(model: AppModel) {
        appModel = model
        let splitVC = MainSplitViewController(model: model)
        let window = NSWindow(contentViewController: splitVC)
        window.title = AppBrand.displayName
        window.isReleasedWhenClosed = false
        window.isRestorable = true
        configureWindowForToolbar(window)
        super.init(window: window)
        framePersistenceController = WindowFramePersistenceController(
            window: window,
            autosaveName: "\(AppBrand.identifierPrefix).MainWindow",
            minSize: ThreePaneSplitViewController.Metrics.windowMinimum,
            defaultContentSize: ThreePaneSplitViewController.Metrics.windowDefault
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }
}
