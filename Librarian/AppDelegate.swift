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
        window.setContentSize(NSSize(width: 620, height: 500))
        window.minSize = NSSize(width: 620, height: 500)
        window.maxSize = NSSize(width: 620, height: 500)
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
    private let archiveOrganizer = ArchiveOrganizer()
    private var isOrganizingArchive = false
    private var isCreatingArchive = false

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

    private lazy var organizeArchiveButton: NSButton = {
        makeActionButton(title: "Organize Archive", action: #selector(organizeArchiveManually))
    }()

    private lazy var organizeArchiveStatusLabel: NSTextField = {
        let label = NSTextField(labelWithString: "Scans the archive and normalizes folders to YYYY/MM/DD.")
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 2
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private lazy var createArchiveButton: NSButton = {
        makeActionButton(title: "Create New Archive…", action: #selector(createNewArchive))
    }()

    private lazy var createArchiveStatusLabel: NSTextField = {
        let label = NSTextField(labelWithString: "Import photos from existing folders into a new archive root.")
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(archiveRootChanged),
            name: .librarianArchiveRootChanged,
            object: nil
        )
    }

    override func loadView() {
        let container = NSView()
        let destinationLabel = makeCategoryLabel(title: "Archive destination:")
        let chooseButton = makeActionButton(title: "Change…", action: #selector(chooseArchivePath))
        let rebuildLabel = makeCategoryLabel(title: "Index:")
        let analyseLabel = makeCategoryLabel(title: "Library analysis:")
        let organizeLabel = makeCategoryLabel(title: "Archive organization:")
        let createArchiveLabel = makeCategoryLabel(title: "Create archive:")

        let keepsLabel = makeCategoryLabel(title: "Queue keep decisions:")
        let keepsNote = NSTextField(labelWithString: "Reset which items have been marked Keep in each queue.")
        keepsNote.textColor = .secondaryLabelColor
        keepsNote.translatesAutoresizingMaskIntoConstraints = false

        let queues: [(title: String, kind: String)] = [
            ("Screenshots", "screenshots"),
            ("Low Quality", "lowQuality"),
            ("Documents", "receiptsAndDocuments"),
            ("Duplicates", "duplicates"),
        ]
        var resetRows: [[NSView]] = [[keepsLabel, keepsNote, NSView()]]
        for queue in queues {
            let label = makeCategoryLabel(title: "\(queue.title):")
            let countLabel = NSTextField(labelWithString: "")
            countLabel.textColor = .secondaryLabelColor
            countLabel.translatesAutoresizingMaskIntoConstraints = false
            let count = (try? model.database.assetRepository.countKeepDecisions(for: queue.kind)) ?? 0
            countLabel.stringValue = count == 0 ? "No items kept" : "\(count) kept"
            let button = makeActionButton(title: "Reset", action: #selector(resetKeepDecisions(_:)))
            button.tag = queues.firstIndex(where: { $0.kind == queue.kind }) ?? 0
            button.isEnabled = count > 0
            resetRows.append([label, countLabel, button])
        }

        let grid = NSGridView(views: [
            [destinationLabel, archivePathField, chooseButton],
            [rebuildLabel, rebuildStatusLabel, rebuildButton],
            [analyseLabel, analyseStatusLabel, analyseButton],
            [organizeLabel, organizeArchiveStatusLabel, organizeArchiveButton],
            [createArchiveLabel, createArchiveStatusLabel, createArchiveButton],
        ] + resetRows)
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
        refreshOrganizeArchiveButtonState()
        refreshCreateArchiveButtonState()
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
        panel.message = "Choose the active archive root used for export and the Archived view."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = ArchiveSettings.restoreArchiveRootURL() ?? FileManager.default.homeDirectoryForCurrentUser
        let result = panel.runModal()
        guard result == .OK, let url = panel.url else { return }
        guard model.updateArchiveRoot(url) else { return }
        refreshArchivePath()
        Task { @MainActor [weak self] in
            await self?.scanArchiveAndPromptToOrganizeIfNeeded()
        }
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

    @objc private func archiveRootChanged() {
        refreshArchivePath()
        refreshOrganizeArchiveButtonState()
    }

    @objc private func analyseLibrary() {
        refreshAnalyseButtonState()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.model.runLibraryAnalysis()
            self.refreshAnalyseButtonState()
        }
    }

    @objc private func organizeArchiveManually() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.organizeArchive()
        }
    }

    @objc private func resetKeepDecisions(_ sender: NSButton) {
        let kinds = ["screenshots", "lowQuality", "receiptsAndDocuments", "duplicates"]
        guard sender.tag < kinds.count else { return }
        let kind = kinds[sender.tag]
        do {
            try model.database.assetRepository.clearKeepDecisions(for: kind)
            NotificationCenter.default.post(name: .librarianIndexingStateChanged, object: nil)
            // Rebuild the view to refresh counts
            loadView()
            viewDidAppear()
        } catch {
            AppLog.shared.error("Failed to reset keep decisions for \(kind): \(error.localizedDescription)")
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

    private func refreshOrganizeArchiveButtonState() {
        organizeArchiveButton.isEnabled = !isOrganizingArchive && ArchiveSettings.restoreArchiveRootURL() != nil
        organizeArchiveButton.title = isOrganizingArchive ? "Organizing…" : "Organize Archive"
        if isOrganizingArchive {
            return
        }
        if ArchiveSettings.restoreArchiveRootURL() == nil {
            organizeArchiveStatusLabel.stringValue = "Choose an archive destination to enable organization."
        } else {
            organizeArchiveStatusLabel.stringValue = "Scans the archive and normalizes folders to YYYY/MM/DD."
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

    @MainActor
    private func scanArchiveAndPromptToOrganizeIfNeeded() async {
        guard let archiveTreeRoot = ArchiveSettings.currentArchiveTreeRootURL() else { return }
        organizeArchiveStatusLabel.stringValue = "Scanning archive folder…"
        let count: Int
        do {
            count = try await Task.detached(priority: .utility) {
                try self.archiveOrganizer.scanUnorganizedCount(in: archiveTreeRoot)
            }.value
        } catch {
            organizeArchiveStatusLabel.stringValue = "Scan failed: \(error.localizedDescription)"
            AppLog.shared.error("Archive organization scan failed: \(error.localizedDescription)")
            return
        }

        if count == 0 {
            organizeArchiveStatusLabel.stringValue = "Archive structure is already organized."
            return
        }

        organizeArchiveStatusLabel.stringValue = "\(count.formatted()) unorganized file(s) detected."
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Organize New Archive Location?"
        alert.informativeText = "Librarian found \(count.formatted()) file(s) outside the YYYY/MM/DD folder pattern. Organize them now?"
        alert.addButton(withTitle: "Organize Now")
        alert.addButton(withTitle: "Not Now")

        let response: NSApplication.ModalResponse
        if let window = view.window {
            response = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { modalResponse in
                    continuation.resume(returning: modalResponse)
                }
            }
        } else {
            response = alert.runModal()
        }

        guard response == .alertFirstButtonReturn else { return }
        await organizeArchive()
    }

    @MainActor
    private func organizeArchive() async {
        guard !isOrganizingArchive else { return }
        guard let archiveTreeRoot = ArchiveSettings.currentArchiveTreeRootURL() else {
            organizeArchiveStatusLabel.stringValue = "Choose an archive destination first."
            return
        }

        isOrganizingArchive = true
        refreshOrganizeArchiveButtonState()
        let summary: ArchiveOrganizationResult
        do {
            summary = try await Task.detached(priority: .utility) {
                try self.archiveOrganizer.organizeArchiveTree(in: archiveTreeRoot)
            }.value
        } catch {
            isOrganizingArchive = false
            refreshOrganizeArchiveButtonState()
            organizeArchiveStatusLabel.stringValue = "Organization failed: \(error.localizedDescription)"
            AppLog.shared.error("Archive organization failed: \(error.localizedDescription)")
            return
        }

        isOrganizingArchive = false
        refreshOrganizeArchiveButtonState()
        organizeArchiveStatusLabel.stringValue = "Moved \(summary.movedCount.formatted()) file(s). \(summary.alreadyOrganizedCount.formatted()) already organized."
        AppLog.shared.info("Archive organization completed. moved=\(summary.movedCount), alreadyOrganized=\(summary.alreadyOrganizedCount), scanned=\(summary.scannedCount)")
        NotificationCenter.default.post(name: .librarianArchiveQueueChanged, object: nil)
    }

    // MARK: - Create New Archive workflow

    @objc private func createNewArchive() {
        guard !isCreatingArchive else { return }
        Task { @MainActor [weak self] in
            await self?.runCreateNewArchiveFlow()
        }
    }

    @MainActor
    private func runCreateNewArchiveFlow() async {
        guard !isCreatingArchive else { return }

        // Step 1: Choose new archive root folder.
        let rootPanel = NSOpenPanel()
        rootPanel.title = "Choose New Archive Root"
        rootPanel.message = "Choose or create a folder that will become the new active archive root."
        rootPanel.prompt = "Choose Root"
        rootPanel.canChooseDirectories = true
        rootPanel.canChooseFiles = false
        rootPanel.allowsMultipleSelection = false
        rootPanel.canCreateDirectories = true
        rootPanel.directoryURL = ArchiveSettings.restoreArchiveRootURL()
            ?? FileManager.default.homeDirectoryForCurrentUser
        guard rootPanel.runModal() == .OK, let archiveRoot = rootPanel.url else { return }

        // Step 2: Choose source folders to import from.
        let sourcePanel = NSOpenPanel()
        sourcePanel.title = "Choose Source Folders"
        sourcePanel.message = "Choose one or more folders whose photos will be imported into the new archive. These folders will not be modified."
        sourcePanel.prompt = "Choose Sources"
        sourcePanel.canChooseDirectories = true
        sourcePanel.canChooseFiles = false
        sourcePanel.allowsMultipleSelection = true
        sourcePanel.canCreateDirectories = false
        sourcePanel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        guard sourcePanel.runModal() == .OK, !sourcePanel.urls.isEmpty else { return }
        let sourceFolders = sourcePanel.urls

        // Step 3: Run preflight scan.
        isCreatingArchive = true
        refreshCreateArchiveButtonState()
        createArchiveStatusLabel.stringValue = "Scanning…"

        let coordinator = ArchiveImportCoordinator(
            archiveRoot: archiveRoot,
            sourceFolders: sourceFolders,
            database: model.database
        )
        let preflight: ArchiveImportPreflightResult
        do {
            preflight = try await Task.detached(priority: .utility) {
                try coordinator.runPreflight()
            }.value
        } catch {
            isCreatingArchive = false
            refreshCreateArchiveButtonState()
            createArchiveStatusLabel.stringValue = "Scan failed: \(error.localizedDescription)"
            AppLog.shared.error("Archive import preflight failed: \(error.localizedDescription)")
            return
        }

        // Step 4: Show preflight report and ask for confirmation.
        createArchiveStatusLabel.stringValue = "\(preflight.totalDiscovered.formatted()) file(s) found."
        let confirmed = await showPreflightConfirmation(preflight: preflight)
        guard confirmed else {
            isCreatingArchive = false
            refreshCreateArchiveButtonState()
            createArchiveStatusLabel.stringValue = "Import cancelled."
            return
        }

        // Guard against no candidates.
        guard preflight.toImport > 0 else {
            isCreatingArchive = false
            refreshCreateArchiveButtonState()
            createArchiveStatusLabel.stringValue = "Nothing to import after deduplication."
            return
        }

        // Step 5: Run import.
        createArchiveStatusLabel.stringValue = "Importing…"
        let summary: ArchiveImportRunSummary
        do {
            summary = try await model.runArchiveImport(
                archiveRoot: archiveRoot,
                sourceFolders: sourceFolders,
                preflight: preflight
            )
        } catch {
            isCreatingArchive = false
            refreshCreateArchiveButtonState()
            createArchiveStatusLabel.stringValue = "Import failed: \(error.localizedDescription)"
            return
        }

        isCreatingArchive = false
        refreshCreateArchiveButtonState()

        // Update archive path display if root was switched.
        if summary.imported > 0 {
            refreshArchivePath()
            refreshOrganizeArchiveButtonState()
        }

        // Step 6: Show completion summary.
        createArchiveStatusLabel.stringValue = "\(summary.imported.formatted()) file(s) imported."
        showImportCompletionAlert(summary: summary)
    }

    @MainActor
    private func showPreflightConfirmation(preflight: ArchiveImportPreflightResult) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Create Archive?"

        var lines: [String] = ["\(preflight.totalDiscovered.formatted()) file(s) discovered."]
        if preflight.duplicatesInSource > 0 {
            lines.append("• \(preflight.duplicatesInSource.formatted()) duplicate(s) within source folders will be skipped.")
        }
        if preflight.existsInPhotoKit > 0 {
            lines.append("• \(preflight.existsInPhotoKit.formatted()) file(s) already in your Photos library will be skipped.")
        }
        lines.append("")
        if preflight.toImport > 0 {
            lines.append("\(preflight.toImport.formatted()) file(s) will be imported.")
        } else {
            lines.append("Nothing to import — all files are duplicates or already in Photos.")
        }
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: preflight.toImport > 0 ? "Create Archive" : "OK")
        if preflight.toImport > 0 {
            alert.addButton(withTitle: "Cancel")
        }

        let response: NSApplication.ModalResponse
        if let window = view.window {
            response = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        } else {
            response = alert.runModal()
        }
        return response == .alertFirstButtonReturn && preflight.toImport > 0
    }

    private func showImportCompletionAlert(summary: ArchiveImportRunSummary) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Archive Created"

        var lines: [String] = ["\(summary.imported.formatted()) file(s) imported."]
        if summary.skippedDuplicateInSource > 0 {
            lines.append("• \(summary.skippedDuplicateInSource.formatted()) duplicate(s) in source folders skipped.")
        }
        if summary.skippedExistsInPhotoKit > 0 {
            lines.append("• \(summary.skippedExistsInPhotoKit.formatted()) file(s) already in Photos skipped.")
        }
        if summary.failed > 0 {
            lines.append("• \(summary.failed.formatted()) file(s) failed — check the log for details.")
        }
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "Done")

        if let window = view.window {
            alert.beginSheetModal(for: window) { _ in }
        } else {
            alert.runModal()
        }
    }

    private func refreshCreateArchiveButtonState() {
        createArchiveButton.isEnabled = !isCreatingArchive && !model.isImportingArchive
        createArchiveButton.title = (isCreatingArchive || model.isImportingArchive) ? "Importing…" : "Create New Archive…"
        if !isCreatingArchive && !model.isImportingArchive {
            if createArchiveStatusLabel.stringValue == "Importing…"
                || createArchiveStatusLabel.stringValue == "Scanning…" {
                createArchiveStatusLabel.stringValue = "Import photos from existing folders into a new archive root."
            }
        }
    }
}
