import Cocoa
import SharedUI
import UserNotifications

@MainActor
@main
enum LibrarianMain {
    private static var appDelegate: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        self.appDelegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var mainWindowController: MainWindowController?
    private var settingsWindowController: SettingsWindowController?
    private var welcomeCoordinator: WelcomeScreenCoordinator?
    private var isShowingTerminateConfirmation = false
    private var isPresentingArchiveRelinkFlow = false
    private var allowImmediateTermination = false
    private var updateService: UpdateService?
    var appModel: AppModel? { mainWindowController?.appModel }

    func showAboutPanel() {
        presentAboutPanel(
            purpose: "Curate and archive your Apple Photos Library.",
            credits: [
                .init(text: "Uses osxphotos by Rhet Turnbull", linkURL: "https://github.com/RhetTbull/osxphotos"),
            ],
            copyright: "© 2026 Chris Le Marquand"
        )
    }

    @objc func showAboutPanelMenuAction(_: Any?) {
        showAboutPanel()
    }

    @objc func checkForUpdatesAction(_ sender: Any?) {
        updateService?.checkForUpdates(sender)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        configureApplicationMenu()
        UNUserNotificationCenter.current().delegate = self

        let model = AppModel()
        settingsWindowController = SettingsWindowController(tabs: [
            SettingsTabDescriptor(symbolName: "photo.stack", label: "Library",
                viewController: LibrarySettingsViewController(model: model)),
            SettingsTabDescriptor(symbolName: "archivebox", label: "Archive",
                viewController: ArchiveSettingsViewController(model: model)),
            SettingsTabDescriptor(symbolName: "sidebar.right", label: "Inspector",
                viewController: InspectorSettingsViewController(model: model), preferredHeight: 520),
        ])
        let windowController = MainWindowController(model: model)
        mainWindowController = windowController
        windowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        updateService = UpdateService()
        updateService?.performBackgroundCheck()

        NotificationCenter.default.addObserver(
            forName: .librarianArchiveNeedsRelink,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard !self.isPresentingArchiveRelinkFlow else { return }
                guard model.refreshArchiveRootAvailability() == .unavailable else { return }
                self.isPresentingArchiveRelinkFlow = true
                defer { self.isPresentingArchiveRelinkFlow = false }
                await runArchiveRelinkFlow(
                    model: model,
                    presentingWindow: self.mainWindowController?.window
                )
            }
        }

        NotificationCenter.default.addObserver(
            forName: .librarianSystemPhotoLibraryChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let currentPath = ArchiveSettings.currentPhotoLibraryPath(),
                      let archiveRoot = ArchiveSettings.restoreArchiveRootURL(),
                      let config = ArchiveSettings.controlConfig(for: archiveRoot),
                      let storedPath = config.lastKnownPhotoLibraryPath,
                      !storedPath.isEmpty else { return }

                let stored = URL(fileURLWithPath: storedPath).standardizedFileURL.path
                let current = URL(fileURLWithPath: currentPath).standardizedFileURL.path
                guard stored != current else { return }

                let currentName = URL(fileURLWithPath: currentPath).deletingPathExtension().lastPathComponent
                let alert = NSAlert()
                alert.alertStyle = .informational
                alert.messageText = "Photos Library Changed"
                alert.informativeText = "Your system Photos Library is now \"\(currentName)\".\n\nYou may want to choose a different Archive location for this library."
                alert.addButton(withTitle: "OK")
                _ = await alert.runSheetOrModal(
                    for: self.mainWindowController?.window
                )

                ArchiveSettings.updateControlConfig(at: archiveRoot) { config in
                    config.lastKnownPhotoLibraryPath = currentPath
                }
            }
        }

        if Self.isFirstRun() {
            let coordinator = WelcomeScreenCoordinator(model: model) {
                Task { await model.setup() }
            }
            self.welcomeCoordinator = coordinator
            Task { @MainActor in
                await Task.yield()
                model.activeWelcomePresentation = coordinator.makePresentation()
            }
        } else {
            Task { await model.setup() }
        }
    }

    // MARK: - First-run detection

    private static let firstRunKey = "hasCompletedWelcomeScreen"

    private static func isFirstRun() -> Bool {
        !UserDefaults.standard.bool(forKey: firstRunKey)
    }

    static func markWelcomeScreenComplete() {
        UserDefaults.standard.set(true, forKey: firstRunKey)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            mainWindowController?.showWindow(nil)
        } else {
            mainWindowController?.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationShouldSaveApplicationState(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldRestoreApplicationState(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if allowImmediateTermination {
            allowImmediateTermination = false
            return .terminateNow
        }

        guard let appModel,
              appModel.isIndexing
                || appModel.isAnalysisInNonResumableStage
        else {
            return .terminateNow
        }

        guard !isShowingTerminateConfirmation else {
            return .terminateCancel
        }
        isShowingTerminateConfirmation = true

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit While Work Is In Progress?"
        alert.informativeText = "Librarian is still updating your Catalogue or analysing your library."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")

        let keyWindow = NSApp.keyWindow ?? mainWindowController?.window
        if let keyWindow {
            alert.runSheetOrModal(for: keyWindow) { [weak self] response in
                guard let self else { return }
                self.isShowingTerminateConfirmation = false
                if response == .alertFirstButtonReturn {
                    self.allowImmediateTermination = true
                    sender.terminate(nil)
                } else {
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                alert.runSheetOrModal(for: nil) { response in
                    self.isShowingTerminateConfirmation = false
                    if response == .alertFirstButtonReturn {
                        self.allowImmediateTermination = true
                        sender.terminate(nil)
                    } else {
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
            }
        }
        return .terminateCancel
    }

    // MARK: - Menu

    private func configureApplicationMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appName = AppBrand.displayName
        let appItem = NSMenuItem(title: appName, action: nil, keyEquivalent: "")
        appItem.submenu = makeStandardAppMenu(
            appName: appName,
            aboutAction: #selector(showAboutPanelMenuAction(_:)),
            settingsAction: #selector(showSettingsWindow(_:)),
            checkForUpdatesAction: #selector(checkForUpdatesAction(_:))
        )
        mainMenu.addItem(appItem)

        // File menu
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu
        let importItem = NSMenuItem(title: "Import Photos into Archive…", action: #selector(MainSplitViewController.addPhotosToArchiveAction(_:)), keyEquivalent: "")
        importItem.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: nil)
        fileMenu.addItem(importItem)
        let archiveLocationItem = NSMenuItem(title: "Set Archive Location…", action: #selector(MainSplitViewController.setArchiveLocationAction(_:)), keyEquivalent: "")
        archiveLocationItem.image = NSImage(systemSymbolName: "folder.badge.gear", accessibilityDescription: nil)
        fileMenu.addItem(archiveLocationItem)
        fileMenu.addItem(.separator())
        let openInPhotosItem = NSMenuItem(title: "Open in Photos", action: #selector(MainSplitViewController.openSelectionInPhotos(_:)), keyEquivalent: "o")
        openInPhotosItem.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
        fileMenu.addItem(openInPhotosItem)
        let revealItem = NSMenuItem(title: "Reveal in Finder", action: #selector(MainSplitViewController.revealSelectionInFinderAction(_:)), keyEquivalent: "r")
        revealItem.keyEquivalentModifierMask = [.command, .option]
        revealItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        fileMenu.addItem(revealItem)
        let quickLookItem = NSMenuItem(title: "Quick Look", action: #selector(MainSplitViewController.quickLookSelectionAction(_:)), keyEquivalent: "y")
        quickLookItem.keyEquivalentModifierMask = .command
        quickLookItem.image = NSImage(systemSymbolName: "eye", accessibilityDescription: nil)
        fileMenu.addItem(quickLookItem)

        // Edit menu
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        let undoItem = NSMenuItem(title: "Undo", action: Selector("undo:"), keyEquivalent: "z")
        undoItem.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: nil)
        editMenu.addItem(undoItem)
        let redoItem = NSMenuItem(title: "Redo", action: Selector("redo:"), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        redoItem.image = NSImage(systemSymbolName: "arrow.uturn.forward", accessibilityDescription: nil)
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a"))

        // Photo menu
        let photoItem = NSMenuItem(title: "Photo", action: nil, keyEquivalent: "")
        mainMenu.addItem(photoItem)
        let photoMenu = NSMenu(title: "Photo")
        photoItem.submenu = photoMenu
        let setAsideItem = NSMenuItem(title: "Set Aside", action: #selector(MainSplitViewController.setAsideSelectionAction(_:)), keyEquivalent: "d")
        setAsideItem.image = NSImage(systemSymbolName: "tray.and.arrow.down", accessibilityDescription: nil)
        photoMenu.addItem(setAsideItem)
        let putBackItem = NSMenuItem(title: "Put Back", action: #selector(MainSplitViewController.putBackSelectionAction(_:)), keyEquivalent: "d")
        putBackItem.keyEquivalentModifierMask = [.command, .option]
        putBackItem.image = NSImage(systemSymbolName: "arrow.uturn.left.circle", accessibilityDescription: nil)
        photoMenu.addItem(putBackItem)
        photoMenu.addItem(.separator())
        let sendToArchiveItem = NSMenuItem(title: "Send Selected to Archive…", action: #selector(MainSplitViewController.sendToArchiveAction(_:)), keyEquivalent: "s")
        sendToArchiveItem.keyEquivalentModifierMask = [.command, .option, .shift]
        sendToArchiveItem.image = NSImage(systemSymbolName: "archivebox", accessibilityDescription: nil)
        photoMenu.addItem(sendToArchiveItem)

        // Tools menu
        let toolsItem = NSMenuItem(title: "Tools", action: nil, keyEquivalent: "")
        mainMenu.addItem(toolsItem)
        let toolsMenu = NSMenu(title: "Tools")
        toolsItem.submenu = toolsMenu
        let updateCatalogueItem = NSMenuItem(title: "Update Catalogue", action: #selector(MainSplitViewController.updateCatalogueAction(_:)), keyEquivalent: "")
        updateCatalogueItem.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        toolsMenu.addItem(updateCatalogueItem)
        let analyseLibraryItem = NSMenuItem(title: "Analyse Library", action: #selector(MainSplitViewController.analyseLibraryAction(_:)), keyEquivalent: "")
        analyseLibraryItem.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        toolsMenu.addItem(analyseLibraryItem)

        // View menu
        let viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu
        let zoomInItem = NSMenuItem(title: "Zoom In", action: #selector(MainSplitViewController.zoomInAction(_:)), keyEquivalent: "+")
        zoomInItem.keyEquivalentModifierMask = .command
        zoomInItem.image = NSImage(systemSymbolName: "plus.magnifyingglass", accessibilityDescription: nil)
        viewMenu.addItem(zoomInItem)
        let zoomOutItem = NSMenuItem(title: "Zoom Out", action: #selector(MainSplitViewController.zoomOutAction(_:)), keyEquivalent: "-")
        zoomOutItem.keyEquivalentModifierMask = .command
        zoomOutItem.image = NSImage(systemSymbolName: "minus.magnifyingglass", accessibilityDescription: nil)
        viewMenu.addItem(zoomOutItem)
        viewMenu.addItem(.separator())
        let toggleSidebarItem = NSMenuItem(title: "Toggle Sidebar", action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s")
        toggleSidebarItem.keyEquivalentModifierMask = [.command, .option]
        toggleSidebarItem.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: nil)
        viewMenu.addItem(toggleSidebarItem)
        let toggleInspectorItem = NSMenuItem(title: "Toggle Inspector", action: #selector(MainSplitViewController.toggleInspector(_:)), keyEquivalent: "i")
        toggleInspectorItem.keyEquivalentModifierMask = [.command, .option]
        toggleInspectorItem.image = NSImage(systemSymbolName: "sidebar.trailing", accessibilityDescription: nil)
        viewMenu.addItem(toggleInspectorItem)

        // Window menu
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let windowMenu = makeStandardWindowMenu()
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu
        mainMenu.addItem(windowItem)

        NSApp.mainMenu = mainMenu
    }

    @MainActor @objc private func showSettingsWindow(_ sender: Any?) {
        if settingsWindowController == nil {
            guard let appModel else { return }
            settingsWindowController = SettingsWindowController(tabs: [
                SettingsTabDescriptor(symbolName: "photo.stack", label: "Library",
                    viewController: LibrarySettingsViewController(model: appModel)),
                SettingsTabDescriptor(symbolName: "archivebox", label: "Archive",
                    viewController: ArchiveSettingsViewController(model: appModel)),
                SettingsTabDescriptor(symbolName: "sidebar.right", label: "Inspector",
                    viewController: InspectorSettingsViewController(model: appModel), preferredHeight: 520),
            ])
        }
        settingsWindowController?.showWindowAndActivate()
    }

}

@MainActor
extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        _ = center
        _ = response
        await MainActor.run {
            if let window = self.mainWindowController?.window {
                window.makeKeyAndOrderFront(nil)
            } else {
                self.mainWindowController?.showWindow(nil)
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

private struct AboutCredit {
    let text: String
    let linkURL: String?
}

@MainActor
private func presentAboutPanel(
    purpose: String,
    credits: [AboutCredit] = [],
    copyright: String? = nil
) {
    let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    let color = NSColor.secondaryLabelColor
    let centered = NSMutableParagraphStyle()
    centered.alignment = .center
    let baseAttributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: centered,
    ]

    let body = NSMutableAttributedString(string: purpose, attributes: baseAttributes)
    for credit in credits {
        body.append(NSAttributedString(string: "\n\n\(credit.text)", attributes: baseAttributes))
        if let linkURL = credit.linkURL {
            body.append(NSAttributedString(string: "\n", attributes: baseAttributes))
            let range = NSRange(location: body.length, length: (linkURL as NSString).length)
            body.append(NSAttributedString(string: linkURL, attributes: baseAttributes))
            body.addAttributes(
                [
                    .link: linkURL,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ],
                range: range
            )
        }
    }

    let bundle = Bundle.main
    let appName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
        ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
        ?? ProcessInfo.processInfo.processName
    let shortVersion = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0"

    var options: [NSApplication.AboutPanelOptionKey: Any] = [
        .applicationName: appName,
        .applicationVersion: shortVersion,
        .credits: body,
    ]
    if let copyright {
        options[NSApplication.AboutPanelOptionKey(rawValue: "Copyright")] = copyright
    }

    NSApp.orderFrontStandardAboutPanel(options: options)
    NSApp.activate(ignoringOtherApps: true)
}
