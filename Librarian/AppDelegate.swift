import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        configureApplicationMenu()

        let model = AppModel()
        let splitVC = MainSplitViewController(model: model)
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
        window.isRestorable = false
        window.setFrameAutosaveName("com.librarian.app.MainWindow")
        window.center()

        let toolbar = NSToolbar(identifier: "com.librarian.app.MainToolbar")
        toolbar.delegate = splitVC.toolbarDelegate
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window.toolbar = toolbar

        mainWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        Task { await model.setup() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        false
    }

    // MARK: - Menu

    private func configureApplicationMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appItem = NSMenuItem(title: "Librarian", action: nil, keyEquivalent: "")
        mainMenu.addItem(appItem)
        let appMenu = NSMenu(title: "Librarian")
        appItem.submenu = appMenu
        appMenu.addItem(NSMenuItem(title: "About Librarian", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Hide Librarian", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        let hideOthers = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Librarian", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        // File menu
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu
        fileMenu.addItem(NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))

        // View menu
        let viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu
        viewMenu.addItem(NSMenuItem(title: "Toggle Sidebar", action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s").then {
            $0.keyEquivalentModifierMask = [.command, .control]
        })
        viewMenu.addItem(NSMenuItem(title: "Toggle Inspector", action: #selector(MainSplitViewController.toggleInspector(_:)), keyEquivalent: "i").then {
            $0.keyEquivalentModifierMask = [.command, .control]
        })

        // Window menu
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: ""))
        windowMenu.addItem(.separator())
        windowMenu.addItem(NSMenuItem(title: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""))
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }
}

// MARK: - Convenience

extension NSMenuItem {
    func then(_ configure: (NSMenuItem) -> Void) -> NSMenuItem {
        configure(self)
        return self
    }
}
