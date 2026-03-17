import Cocoa

final class MainWindowController: NSWindowController {

    let model: AppModel

    init(model: AppModel) {
        self.model = model

        let splitVC = MainSplitViewController(model: model)

        // Use the explicit initializer — more reliable than NSWindow(contentViewController:)
        // when assembling the shell programmatically.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1300, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = splitVC
        splitVC.loadViewIfNeeded()
        window.minSize = NSSize(width: 1100, height: 680)
        window.toolbarStyle = .automatic
        window.titlebarSeparatorStyle = .automatic
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.title = "Librarian"
        window.setFrameAutosaveName("com.librarian.app.MainWindow")
        window.center()

        let toolbar = NSToolbar(identifier: "com.librarian.app.MainToolbar")
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
