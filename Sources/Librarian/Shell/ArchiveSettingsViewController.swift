import AppKit
import SharedUI

final class ArchiveSettingsViewController: SettingsGridViewController {
    private let model: AppModel
    private let archiveOrganizer = ArchiveOrganizer()
    private var isOrganizingArchive = false
    private var isCreatingArchive = false

    private lazy var archivePathField: NSTextField = {
        let field = NSTextField(labelWithString: "Not set")
        field.textColor = .secondaryLabelColor
        field.lineBreakMode = .byTruncatingMiddle
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }()
    private lazy var chooseButton     = makeActionButton(title: "Change…",           action: #selector(chooseArchivePath))
    private lazy var organizeButton   = makeActionButton(title: "Organize Archive",  action: #selector(organizeArchiveManually))
    private lazy var organizeLabel    = makeDescriptionLabel("Scans the archive and normalizes folders to YYYY/MM/DD.")
    private lazy var createButton     = makeActionButton(title: "Create New Archive…", action: #selector(createNewArchive))
    private lazy var createLabel      = makeDescriptionLabel("Import photos from existing folders into a new archive root.")

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(
            self, selector: #selector(archiveRootChanged),
            name: .librarianArchiveRootChanged, object: nil
        )
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        refreshArchivePath()
        refreshOrganizeButtonState()
        refreshCreateButtonState()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func makeRows() -> [[NSView]] {
        [
            [makeCategoryLabel(title: "Archive destination:"), archivePathField, chooseButton],
            [makeCategoryLabel(title: "Archive organization:"), organizeLabel,   organizeButton],
            [makeCategoryLabel(title: "Create archive:"),       createLabel,     createButton],
        ]
    }

    // MARK: - Actions

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

    @objc private func organizeArchiveManually() {
        Task { @MainActor [weak self] in
            await self?.organizeArchive()
        }
    }

    @objc private func createNewArchive() {
        guard !isCreatingArchive else { return }
        Task { @MainActor [weak self] in
            await self?.runCreateNewArchiveFlow()
        }
    }

    // MARK: - Notification handler

    @objc private func archiveRootChanged() {
        refreshArchivePath()
        refreshOrganizeButtonState()
    }

    // MARK: - State refresh

    private func refreshArchivePath() {
        if let url = ArchiveSettings.restoreArchiveRootURL() {
            archivePathField.stringValue = url.path
            archivePathField.textColor = .labelColor
        } else {
            archivePathField.stringValue = "Not set"
            archivePathField.textColor = .secondaryLabelColor
        }
    }

    private func refreshOrganizeButtonState() {
        let hasRoot = ArchiveSettings.restoreArchiveRootURL() != nil
        organizeButton.isEnabled = !isOrganizingArchive && hasRoot
        organizeButton.title = isOrganizingArchive ? "Organizing…" : "Organize Archive"
        if !isOrganizingArchive {
            organizeLabel.stringValue = hasRoot
                ? "Scans the archive and normalizes folders to YYYY/MM/DD."
                : "Choose an archive destination to enable organization."
        }
    }

    private func refreshCreateButtonState() {
        let busy = isCreatingArchive || model.isImportingArchive
        createButton.isEnabled = !busy
        createButton.title = busy ? "Importing…" : "Create New Archive…"
        if !busy, createLabel.stringValue == "Importing…" || createLabel.stringValue == "Scanning…" {
            createLabel.stringValue = "Import photos from existing folders into a new archive root."
        }
    }

    // MARK: - Archive organisation

    @MainActor
    private func scanArchiveAndPromptToOrganizeIfNeeded() async {
        guard let archiveTreeRoot = ArchiveSettings.currentArchiveTreeRootURL() else { return }
        organizeLabel.stringValue = "Scanning archive folder…"
        let count: Int
        do {
            count = try await Task.detached(priority: .utility) {
                try self.archiveOrganizer.scanUnorganizedCount(in: archiveTreeRoot)
            }.value
        } catch {
            organizeLabel.stringValue = "Scan failed: \(error.localizedDescription)"
            AppLog.shared.error("Archive organization scan failed: \(error.localizedDescription)")
            return
        }

        if count == 0 {
            organizeLabel.stringValue = "Archive structure is already organized."
            return
        }

        organizeLabel.stringValue = "\(count.formatted()) unorganized file(s) detected."
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Organize New Archive Location?"
        alert.informativeText = "Librarian found \(count.formatted()) file(s) outside the YYYY/MM/DD folder pattern. Organize them now?"
        alert.addButton(withTitle: "Organize Now")
        alert.addButton(withTitle: "Not Now")

        let response = await alert.runSheetOrModal(for: view.window)
        guard response == .alertFirstButtonReturn else { return }
        await organizeArchive()
    }

    @MainActor
    private func organizeArchive() async {
        guard !isOrganizingArchive else { return }
        guard let archiveTreeRoot = ArchiveSettings.currentArchiveTreeRootURL() else {
            organizeLabel.stringValue = "Choose an archive destination first."
            return
        }
        isOrganizingArchive = true
        refreshOrganizeButtonState()
        let summary: ArchiveOrganizationResult
        do {
            summary = try await Task.detached(priority: .utility) {
                try self.archiveOrganizer.organizeArchiveTree(in: archiveTreeRoot)
            }.value
        } catch {
            isOrganizingArchive = false
            refreshOrganizeButtonState()
            organizeLabel.stringValue = "Organization failed: \(error.localizedDescription)"
            AppLog.shared.error("Archive organization failed: \(error.localizedDescription)")
            return
        }
        isOrganizingArchive = false
        refreshOrganizeButtonState()
        organizeLabel.stringValue = "Moved \(summary.movedCount.formatted()) file(s). \(summary.alreadyOrganizedCount.formatted()) already organized."
        AppLog.shared.info("Archive organization completed. moved=\(summary.movedCount), alreadyOrganized=\(summary.alreadyOrganizedCount), scanned=\(summary.scannedCount)")
        NotificationCenter.default.post(name: .librarianArchiveQueueChanged, object: nil)
    }

    // MARK: - Create New Archive workflow

    @MainActor
    private func runCreateNewArchiveFlow() async {
        guard !isCreatingArchive else { return }

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

        isCreatingArchive = true
        refreshCreateButtonState()
        createLabel.stringValue = "Scanning…"

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
            refreshCreateButtonState()
            createLabel.stringValue = "Scan failed: \(error.localizedDescription)"
            AppLog.shared.error("Archive import preflight failed: \(error.localizedDescription)")
            return
        }

        createLabel.stringValue = "\(preflight.totalDiscovered.formatted()) file(s) found."
        let confirmed = await showPreflightConfirmation(preflight: preflight)
        guard confirmed else {
            isCreatingArchive = false
            refreshCreateButtonState()
            createLabel.stringValue = "Import cancelled."
            return
        }

        guard preflight.toImport > 0 else {
            isCreatingArchive = false
            refreshCreateButtonState()
            createLabel.stringValue = "Nothing to import after deduplication."
            return
        }

        createLabel.stringValue = "Importing…"
        let summary: ArchiveImportRunSummary
        do {
            summary = try await model.runArchiveImport(
                archiveRoot: archiveRoot,
                sourceFolders: sourceFolders,
                preflight: preflight
            )
        } catch {
            isCreatingArchive = false
            refreshCreateButtonState()
            createLabel.stringValue = "Import failed: \(error.localizedDescription)"
            return
        }

        isCreatingArchive = false
        refreshCreateButtonState()
        if summary.imported > 0 {
            refreshArchivePath()
            refreshOrganizeButtonState()
        }
        createLabel.stringValue = "\(summary.imported.formatted()) file(s) imported."
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
        lines.append(preflight.toImport > 0
            ? "\(preflight.toImport.formatted()) file(s) will be imported."
            : "Nothing to import — all files are duplicates or already in Photos.")
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: preflight.toImport > 0 ? "Create Archive" : "OK")
        if preflight.toImport > 0 { alert.addButton(withTitle: "Cancel") }

        let response = await alert.runSheetOrModal(for: view.window)
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

        alert.runSheetOrModal(for: view.window) { _ in }
    }
}
