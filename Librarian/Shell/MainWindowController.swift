import Cocoa
import SharedUI

final class MainWindowController: NSWindowController {

    let model: AppModel

    init(model: AppModel) {
        self.model = model

        let splitVC = MainSplitViewController(model: model)

        // Use the explicit initializer — more reliable than NSWindow(contentViewController:)
        // when assembling the shell programmatically.
        let defaultSize = ThreePaneSplitViewController.Metrics.windowDefault
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: defaultSize.width, height: defaultSize.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = splitVC
        splitVC.loadViewIfNeeded()
        window.minSize = ThreePaneSplitViewController.Metrics.windowMinimum
        window.isRestorable = true
        window.toolbarStyle = .automatic
        window.titlebarSeparatorStyle = .automatic
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.title = "Librarian"
        window.setFrameAutosaveName("com.librarian.app.MainWindow")
        window.center()

        let toolbar = NSToolbar(identifier: "com.librarian.app.MainToolbar.v1")
        toolbar.delegate = splitVC.toolbarDelegate
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window.toolbar = toolbar

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
