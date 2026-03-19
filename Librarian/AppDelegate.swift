import Cocoa
import SharedUI

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var appModel: AppModel?
    private var splitController: MainSplitViewController?
    private var mainWindow: NSWindow?
    private var settingsWindowController: SettingsWindowController?
    private var toolbarAppearanceAdapter: ToolbarAppearanceAdapter?

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
        configureWindowForToolbar(window)
        window.title = "Librarian"
        window.isRestorable = false
        window.setFrameAutosaveName("com.librarian.app.MainWindow")
        window.center()

        appModel = model
        splitController = splitVC
        installMainToolbar(on: window, resetDelegateState: true)
        toolbarAppearanceAdapter = ToolbarAppearanceAdapter(window: window) { [weak self] in
            self?.rebuildToolbarForCurrentAppearance()
        }

        mainWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        Task { await model.setup() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        toolbarAppearanceAdapter?.invalidate()
        toolbarAppearanceAdapter = nil
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
        appMenu.addItem(NSMenuItem(title: "Settings…", action: #selector(showSettingsWindow(_:)), keyEquivalent: ","))
        appMenu.addItem(.separator())
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        servicesItem.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(servicesItem)
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
        fileMenu.addItem(NSMenuItem(title: "Set Aside Selection", action: #selector(MainSplitViewController.setAsideSelectionAction(_:)), keyEquivalent: "a").then {
            $0.keyEquivalentModifierMask = [.command, .option]
        })
        fileMenu.addItem(NSMenuItem(title: "Send to Archive", action: #selector(MainSplitViewController.sendToArchiveAction(_:)), keyEquivalent: "a").then {
            $0.keyEquivalentModifierMask = [.command, .option, .shift]
        })
        fileMenu.addItem(.separator())
        fileMenu.addItem(NSMenuItem(title: "Open in Photos", action: #selector(MainSplitViewController.openSelectionInPhotos(_:)), keyEquivalent: "o"))
        fileMenu.addItem(.separator())
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
        viewMenu.addItem(.separator())
        viewMenu.addItem(NSMenuItem(title: "Refresh View", action: #selector(MainSplitViewController.refreshCurrentViewAction(_:)), keyEquivalent: "r"))

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

    @objc private func showSettingsWindow(_ sender: Any?) {
        if settingsWindowController == nil {
            guard let appModel else { return }
            settingsWindowController = SettingsWindowController(tabs: [
                SettingsTabDescriptor(symbolName: "photo.stack", label: "Library",
                    viewController: LibrarySettingsViewController(model: appModel)),
                SettingsTabDescriptor(symbolName: "archivebox", label: "Archive",
                    viewController: ArchiveSettingsViewController(model: appModel)),
            ])
        }
        settingsWindowController?.showWindowAndActivate()
    }

    private func installMainToolbar(on window: NSWindow, resetDelegateState: Bool) {
        guard let splitVC = splitController else { return }
        if resetDelegateState {
            splitVC.toolbarDelegate.resetCachedToolbarReferences()
        }

        let toolbar = NSToolbar(identifier: "com.librarian.app.MainToolbar.v2")
        toolbar.delegate = splitVC.toolbarDelegate
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window.toolbar = toolbar
    }

    private func rebuildToolbarForCurrentAppearance() {
        guard let window = mainWindow, let model = appModel, let splitVC = splitController else { return }
        installMainToolbar(on: window, resetDelegateState: true)
        splitVC.toolbarDelegate.refresh(model: model)
        window.toolbar?.validateVisibleItems()
    }
}

// MARK: - Convenience

extension NSMenuItem {
    func then(_ configure: (NSMenuItem) -> Void) -> NSMenuItem {
        configure(self)
        return self
    }
}

