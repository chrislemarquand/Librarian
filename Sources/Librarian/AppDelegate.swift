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
            SettingsTabDescriptor(symbolName: "archivebox", label: "Archive",
                viewController: ArchiveSettingsViewController(model: model)),
            SettingsTabDescriptor(symbolName: "sidebar.right", label: "Inspector",
                viewController: InspectorSettingsViewController(model: model), preferredHeight: 520),
        ])
        let windowController = MainWindowController(model: model)
        mainWindowController = windowController
        windowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

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
        let setAsideItem = NSMenuItem(title: "Set Aside Selection", action: #selector(MainSplitViewController.setAsideSelectionAction(_:)), keyEquivalent: "a")
        setAsideItem.keyEquivalentModifierMask = [.command, .option]
        fileMenu.addItem(setAsideItem)
        let sendToArchiveItem = NSMenuItem(title: "Send to Archive", action: #selector(MainSplitViewController.sendToArchiveAction(_:)), keyEquivalent: "a")
        sendToArchiveItem.keyEquivalentModifierMask = [.command, .option, .shift]
        fileMenu.addItem(sendToArchiveItem)
        fileMenu.addItem(.separator())
        fileMenu.addItem(NSMenuItem(title: "Open in Photos", action: #selector(MainSplitViewController.openSelectionInPhotos(_:)), keyEquivalent: "o"))
        fileMenu.addItem(.separator())
        fileMenu.addItem(NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))

        // View menu
        let viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu
        let toggleSidebarItem = NSMenuItem(title: "Toggle Sidebar", action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s")
        toggleSidebarItem.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(toggleSidebarItem)
        let toggleInspectorItem = NSMenuItem(title: "Toggle Inspector", action: #selector(MainSplitViewController.toggleInspector(_:)), keyEquivalent: "i")
        toggleInspectorItem.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(toggleInspectorItem)
        viewMenu.addItem(.separator())
        viewMenu.addItem(NSMenuItem(title: "Refresh View", action: #selector(MainSplitViewController.refreshCurrentViewAction(_:)), keyEquivalent: "r"))

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
