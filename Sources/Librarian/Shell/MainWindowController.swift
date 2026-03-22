import Cocoa
import SharedUI

@MainActor
final class MainWindowController: NSWindowController {

    let appModel: AppModel

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

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }
}
