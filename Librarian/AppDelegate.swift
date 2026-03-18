import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var appModel: AppModel?
    private var splitController: MainSplitViewController?
    private var mainWindow: NSWindow?
    private var settingsWindowController: AppSettingsWindowController?
    private var windowAppearanceObservation: NSKeyValueObservation?
    private var lastWindowAppearanceName: NSAppearance.Name?

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

        appModel = model
        splitController = splitVC
        installMainToolbar(on: window, resetDelegateState: true)
        installWindowAppearanceObservationIfNeeded(on: window)

        mainWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        Task { await model.setup() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        windowAppearanceObservation = nil
        lastWindowAppearanceName = nil
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
            settingsWindowController = AppSettingsWindowController(model: appModel)
        }
        settingsWindowController?.showWindowAndActivate(sender)
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

    private func installWindowAppearanceObservationIfNeeded(on window: NSWindow) {
        guard windowAppearanceObservation == nil else { return }
        lastWindowAppearanceName = window.effectiveAppearance.name
        windowAppearanceObservation = window.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, change in
            guard let self, let newName = change.newValue?.name else { return }
            DispatchQueue.main.async {
                guard self.lastWindowAppearanceName != newName else { return }
                self.lastWindowAppearanceName = newName
                self.rebuildToolbarForCurrentAppearance()
            }
        }
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

final class AppSettingsWindowController: NSWindowController {
    private let settingsController: AppSettingsViewController

    init(model: AppModel) {
        settingsController = AppSettingsViewController(model: model)
        let window = NSWindow(contentViewController: settingsController)
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 620, height: 300))
        window.minSize = NSSize(width: 620, height: 300)
        window.maxSize = NSSize(width: 620, height: 460)
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func showWindowAndActivate(_ sender: Any?) {
        showWindow(sender)
        window?.center()
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }
}

final class AppSettingsViewController: NSViewController {
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private lazy var archivePathField: NSTextField = {
        let field = NSTextField(labelWithString: "Not set")
        field.textColor = .secondaryLabelColor
        field.lineBreakMode = .byTruncatingMiddle
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }()

    private lazy var rebuildButton: NSButton = {
        let button = makeActionButton(title: "Rebuild Index", action: #selector(rebuildIndex))
        return button
    }()

    private lazy var rebuildStatusLabel: NSTextField = {
        let label = NSTextField(labelWithString: "Runs a full library scan and refreshes the local index.")
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 2
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private lazy var analyseButton: NSButton = {
        makeActionButton(title: "Analyse Library", action: #selector(analyseLibrary))
    }()

    private lazy var analyseStatusLabel: NSTextField = {
        let label = NSTextField(labelWithString: "Imports quality scores, file sizes, labels, and duplicate fingerprints.")
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 2
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(indexingStateChanged),
            name: .librarianIndexingStateChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(analysisStateChanged),
            name: .librarianAnalysisStateChanged,
            object: nil
        )
    }

    override func loadView() {
        let container = NSView()
        let destinationLabel = makeCategoryLabel(title: "Archive destination:")
        let chooseButton = makeActionButton(title: "Choose…", action: #selector(chooseArchivePath))
        let rebuildLabel = makeCategoryLabel(title: "Index:")

        let analyseLabel = makeCategoryLabel(title: "Library analysis:")

        let grid = NSGridView(views: [
            [destinationLabel, archivePathField, chooseButton],
            [rebuildLabel, rebuildStatusLabel, rebuildButton],
            [analyseLabel, analyseStatusLabel, analyseButton],
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 12
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        grid.column(at: 2).xPlacement = .leading

        container.addSubview(grid)

        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -24),
        ])

        view = container
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        refreshArchivePath()
        refreshRebuildButtonState()
        refreshAnalyseButtonState()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func makeActionButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .rounded
        return button
    }

    private func makeCategoryLabel(title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .right
        label.textColor = .labelColor
        return label
    }

    @objc private func chooseArchivePath() {
        let panel = NSOpenPanel()
        panel.prompt = "Set Archive Folder"
        panel.message = "Choose where Librarian should export archived photos."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = ArchiveSettings.restoreArchiveRootURL() ?? FileManager.default.homeDirectoryForCurrentUser
        let result = panel.runModal()
        guard result == .OK, let url = panel.url else { return }
        guard ArchiveSettings.persistArchiveRootURL(url) else { return }
        NotificationCenter.default.post(name: .librarianArchiveQueueChanged, object: nil)
        refreshArchivePath()
    }

    @objc private func rebuildIndex() {
        refreshRebuildButtonState()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.model.rebuildIndexManually()
            self.refreshRebuildButtonState()
        }
    }

    @objc private func indexingStateChanged() {
        refreshRebuildButtonState()
    }

    @objc private func analysisStateChanged() {
        refreshAnalyseButtonState()
    }

    @objc private func analyseLibrary() {
        refreshAnalyseButtonState()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.model.runLibraryAnalysis()
            self.refreshAnalyseButtonState()
        }
    }

    private func refreshAnalyseButtonState() {
        analyseButton.isEnabled = !model.isAnalysing
        analyseButton.title = model.isAnalysing ? "Analysing…" : "Analyse Library"
        if model.isAnalysing {
            analyseStatusLabel.stringValue = model.analysisStatusText.isEmpty
                ? "Running…"
                : model.analysisStatusText
        } else {
            analyseStatusLabel.stringValue = "Imports quality scores, file sizes, labels, and duplicate fingerprints."
        }
    }

    private func refreshArchivePath() {
        if let url = ArchiveSettings.restoreArchiveRootURL() {
            archivePathField.stringValue = url.path
            archivePathField.textColor = .labelColor
        } else {
            archivePathField.stringValue = "Not set"
            archivePathField.textColor = .secondaryLabelColor
        }
    }

    private func refreshRebuildButtonState() {
        rebuildButton.isEnabled = !model.isIndexing
        rebuildButton.title = model.isIndexing ? "Rebuilding…" : "Rebuild Index"
        if model.isIndexing {
            rebuildStatusLabel.stringValue = model.indexingProgress.statusText
        } else {
            rebuildStatusLabel.stringValue = "Runs a full library scan and refreshes the local index."
        }
    }
}
