import Cocoa
import SharedUI

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
    private var isShowingTerminateConfirmation = false
    private var isPresentingArchiveRelinkFlow = false
    private var allowImmediateTermination = false
    var appModel: AppModel? { mainWindowController?.appModel }

    func showAboutPanel() {
        presentAboutPanel(
            purpose: "Curate and archive your Apple Photos library.",
            credits: [
                .init(text: "Uses osxphotos by Rhet Turnbull", linkURL: "https://github.com/RhetTbull/osxphotos"),
            ],
            copyright: "© 2026 Chris Le Marquand"
        )
    }

    @objc func showAboutPanelMenuAction(_: Any?) {
        showAboutPanel()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        configureApplicationMenu()

        let model = AppModel()
        settingsWindowController = SettingsWindowController(tabs: [
            SettingsTabDescriptor(symbolName: "photo.stack", label: "Library",
                viewController: LibrarySettingsViewController(model: model)),
            SettingsTabDescriptor(symbolName: "shippingbox", label: "Boxes",
                viewController: BoxesSettingsViewController(model: model)),
            SettingsTabDescriptor(symbolName: "archivebox", label: "Archive",
                viewController: ArchiveSettingsViewController(model: model)),
            SettingsTabDescriptor(symbolName: "sidebar.right", label: "Inspector",
                viewController: InspectorSettingsViewController(model: model), preferredHeight: 520),
        ])
        let windowController = MainWindowController(model: model)
        mainWindowController = windowController
        windowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

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

        Task { await model.setup() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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
              appModel.isSendingArchive || appModel.isIndexing || appModel.isAnalysing || appModel.isImportingArchive
        else {
            return .terminateNow
        }

        guard !isShowingTerminateConfirmation else {
            return .terminateCancel
        }
        isShowingTerminateConfirmation = true

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "An operation is still in progress."
        alert.informativeText = "Quit now? The operation will be interrupted."
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
            settingsAction: #selector(showSettingsWindow(_:))
        )
        mainMenu.addItem(appItem)

        // File menu
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu
        fileMenu.addItem(NSMenuItem(title: "Import Photos into Archive…", action: #selector(MainSplitViewController.addPhotosToArchiveAction(_:)), keyEquivalent: ""))
        fileMenu.addItem(NSMenuItem(title: "Set Archive Location…", action: #selector(MainSplitViewController.setArchiveLocationAction(_:)), keyEquivalent: ""))
        fileMenu.addItem(.separator())
        fileMenu.addItem(NSMenuItem(title: "Open in Photos", action: #selector(MainSplitViewController.openSelectionInPhotos(_:)), keyEquivalent: "o"))
        let revealItem = NSMenuItem(title: "Reveal in Finder", action: #selector(MainSplitViewController.revealSelectionInFinderAction(_:)), keyEquivalent: "r")
        revealItem.keyEquivalentModifierMask = [.command, .option]
        fileMenu.addItem(revealItem)
        let quickLookItem = NSMenuItem(title: "Quick Look", action: #selector(MainSplitViewController.quickLookSelectionAction(_:)), keyEquivalent: "y")
        quickLookItem.keyEquivalentModifierMask = .command
        fileMenu.addItem(quickLookItem)

        // Edit menu
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector("undo:"), keyEquivalent: "z"))
        let redoItem = NSMenuItem(title: "Redo", action: Selector("redo:"), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a"))

        // Photo menu
        let photoItem = NSMenuItem(title: "Photo", action: nil, keyEquivalent: "")
        mainMenu.addItem(photoItem)
        let photoMenu = NSMenu(title: "Photo")
        photoItem.submenu = photoMenu
        photoMenu.addItem(NSMenuItem(title: "Keep", action: #selector(MainSplitViewController.keepSelectionAction(_:)), keyEquivalent: "k"))
        let setAsideItem = NSMenuItem(title: "Set Aside", action: #selector(MainSplitViewController.setAsideSelectionAction(_:)), keyEquivalent: "d")
        photoMenu.addItem(setAsideItem)
        let putBackItem = NSMenuItem(title: "Put Back", action: #selector(MainSplitViewController.putBackSelectionAction(_:)), keyEquivalent: "d")
        putBackItem.keyEquivalentModifierMask = [.command, .option]
        photoMenu.addItem(putBackItem)
        let resetItem = NSMenuItem(title: "Reset Decision", action: #selector(MainSplitViewController.resetDecisionAction(_:)), keyEquivalent: "\u{8}")
        resetItem.keyEquivalentModifierMask = .command
        photoMenu.addItem(resetItem)
        photoMenu.addItem(.separator())
        let sendToArchiveItem = NSMenuItem(title: "Send Selected to Archive…", action: #selector(MainSplitViewController.sendToArchiveAction(_:)), keyEquivalent: "s")
        sendToArchiveItem.keyEquivalentModifierMask = [.command, .option, .shift]
        photoMenu.addItem(sendToArchiveItem)

        // View menu
        let viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu
        let zoomInItem = NSMenuItem(title: "Zoom In", action: #selector(MainSplitViewController.zoomInAction(_:)), keyEquivalent: "+")
        zoomInItem.keyEquivalentModifierMask = .command
        viewMenu.addItem(zoomInItem)
        let zoomOutItem = NSMenuItem(title: "Zoom Out", action: #selector(MainSplitViewController.zoomOutAction(_:)), keyEquivalent: "-")
        zoomOutItem.keyEquivalentModifierMask = .command
        viewMenu.addItem(zoomOutItem)
        viewMenu.addItem(.separator())
        let toggleSidebarItem = NSMenuItem(title: "Toggle Sidebar", action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s")
        toggleSidebarItem.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(toggleSidebarItem)
        let toggleInspectorItem = NSMenuItem(title: "Toggle Inspector", action: #selector(MainSplitViewController.toggleInspector(_:)), keyEquivalent: "i")
        toggleInspectorItem.keyEquivalentModifierMask = [.command, .option]
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
                SettingsTabDescriptor(symbolName: "shippingbox", label: "Boxes",
                    viewController: BoxesSettingsViewController(model: appModel)),
                SettingsTabDescriptor(symbolName: "archivebox", label: "Archive",
                    viewController: ArchiveSettingsViewController(model: appModel)),
                SettingsTabDescriptor(symbolName: "sidebar.right", label: "Inspector",
                    viewController: InspectorSettingsViewController(model: appModel), preferredHeight: 520),
            ])
        }
        settingsWindowController?.showWindowAndActivate()
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
