import AppKit
import SharedUI

final class ArchiveSettingsViewController: SettingsGridViewController {
    private enum ArchiveDestinationSelection {
        case useAsNewArchive
        case moveExistingArchive
        case cancel
    }

    private let model: AppModel
    private let archiveOrganizer = ArchiveOrganizer()
    private var isOrganizingArchive = false
    private var isCreatingArchive = false
    private var isMovingArchive = false

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
        refreshChooseButtonState()
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
        panel.message = "Choose the active archive root used for export and the Archive view."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = ArchiveSettings.restoreArchiveRootURL() ?? FileManager.default.homeDirectoryForCurrentUser
        let result = panel.runModal()
        guard result == .OK, let url = panel.url else { return }

        let currentRootURL = ArchiveSettings.restoreArchiveRootURL()
        let currentArchiveID = UserDefaults.standard.string(forKey: ArchiveSettings.archiveIDKey)
        let selectedArchiveID = ArchiveSettings.archiveID(for: url)
        var requiresInitializationConfirmation = true

        if selectedArchiveID == nil,
           let currentRootURL,
           currentRootURL.standardizedFileURL != url.standardizedFileURL {
            switch promptArchiveDestinationSelection(currentRootURL: currentRootURL, newRootURL: url) {
            case .cancel:
                return
            case .moveExistingArchive:
                Task { @MainActor [weak self] in
                    await self?.moveExistingArchive(currentRootURL: currentRootURL, newRootURL: url)
                }
                return
            case .useAsNewArchive:
                requiresInitializationConfirmation = false
            }
        }

        if let selectedArchiveID,
           let currentArchiveID,
           selectedArchiveID != currentArchiveID,
           !ArchiveRootPrompts.confirmArchiveSwitch(fromArchiveID: currentArchiveID, toArchiveID: selectedArchiveID) {
            return
        }

        if selectedArchiveID == nil,
           requiresInitializationConfirmation,
           !ArchiveRootPrompts.confirmInitializeArchive(at: url) {
            return
        }

        guard model.updateArchiveRoot(url) else { return }
        refreshArchivePath()
        Task { @MainActor [weak self] in
            await self?.scanArchiveAndPromptToOrganizeIfNeeded()
        }
    }

    private func promptArchiveDestinationSelection(
        currentRootURL: URL,
        newRootURL: URL
    ) -> ArchiveDestinationSelection {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Set a New Archive Location"
        alert.informativeText =
            """
            Choose how Librarian should handle this destination:

            • Use as New Archive: switch immediately and initialize a fresh archive at:
              \(newRootURL.path)

            • Move Existing Archive: migrate your current archive from:
              \(currentRootURL.path)
            """
        alert.addButton(withTitle: "Use as New Archive")
        alert.addButton(withTitle: "Move Existing Archive…")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .useAsNewArchive
        case .alertSecondButtonReturn:
            return .moveExistingArchive
        default:
            return .cancel
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
        refreshChooseButtonState()
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

    private func refreshChooseButtonState() {
        chooseButton.isEnabled = !isMovingArchive
        chooseButton.title = isMovingArchive ? "Moving…" : "Change…"
    }

    private func refreshOrganizeButtonState() {
        let hasRoot = ArchiveSettings.restoreArchiveRootURL() != nil
        organizeButton.isEnabled = !isOrganizingArchive && !isMovingArchive && hasRoot
        organizeButton.title = isOrganizingArchive ? "Organizing…" : "Organize Archive"
        if !isOrganizingArchive {
            organizeLabel.stringValue = hasRoot
                ? "Scans the archive and normalizes folders to YYYY/MM/DD."
                : "Choose an archive destination to enable organization."
        }
    }

    private func refreshCreateButtonState() {
        let busy = isCreatingArchive || model.isImportingArchive || isMovingArchive
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

    // MARK: - Move Existing Archive

    private struct ArchiveMovePreflight {
        let sourceFileCount: Int
        let sourceTotalBytes: Int64
        let destinationFreeBytes: Int64?
    }

    @MainActor
    private func moveExistingArchive(currentRootURL: URL, newRootURL: URL) async {
        guard !isMovingArchive else { return }
        isMovingArchive = true
        refreshChooseButtonState()
        refreshOrganizeButtonState()
        refreshCreateButtonState()

        let destinationRoot = newRootURL.standardizedFileURL

        let preflight: ArchiveMovePreflight
        do {
            preflight = try await Task.detached(priority: .utility) {
                try Self.preflightArchiveMove(sourceRoot: currentRootURL, destinationRoot: destinationRoot)
            }.value
        } catch {
            isMovingArchive = false
            refreshChooseButtonState()
            refreshOrganizeButtonState()
            refreshCreateButtonState()
            showArchiveMoveError("Move preflight failed: \(error.localizedDescription)")
            return
        }

        guard confirmArchiveMove(
            from: currentRootURL,
            to: destinationRoot,
            preflight: preflight
        ) else {
            isMovingArchive = false
            refreshChooseButtonState()
            refreshOrganizeButtonState()
            refreshCreateButtonState()
            return
        }

        do {
            try await Task.detached(priority: .utility) {
                try Self.copyAndVerifyArchiveMove(
                    sourceRoot: currentRootURL,
                    destinationRoot: destinationRoot,
                    expectedFileCount: preflight.sourceFileCount
                )
            }.value
        } catch {
            isMovingArchive = false
            refreshChooseButtonState()
            refreshOrganizeButtonState()
            refreshCreateButtonState()
            showArchiveMoveError("Archive copy failed: \(error.localizedDescription)")
            return
        }

        guard model.updateArchiveRoot(destinationRoot) else {
            isMovingArchive = false
            refreshChooseButtonState()
            refreshOrganizeButtonState()
            refreshCreateButtonState()
            showArchiveMoveError("Archive was copied, but Librarian couldn’t switch to the new location.")
            return
        }

        refreshArchivePath()
        await scanArchiveAndPromptToOrganizeIfNeeded()
        isMovingArchive = false
        refreshChooseButtonState()
        refreshOrganizeButtonState()
        refreshCreateButtonState()
        showArchiveMoveSuccess(from: currentRootURL, to: destinationRoot)
    }

    private func confirmArchiveMove(from sourceRoot: URL, to destinationRoot: URL, preflight: ArchiveMovePreflight) -> Bool {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let sizeText = formatter.string(fromByteCount: preflight.sourceTotalBytes)
        let freeText: String
        if let freeBytes = preflight.destinationFreeBytes {
            freeText = formatter.string(fromByteCount: freeBytes)
        } else {
            freeText = "Unknown"
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Move Existing Archive?"
        alert.informativeText =
            """
            Librarian will copy your current archive to the selected destination and switch to it after verification.

            Files to copy: \(preflight.sourceFileCount.formatted())
            Estimated size: \(sizeText)
            Destination free space: \(freeText)

            The current archive will remain untouched.
            """
        alert.addButton(withTitle: "Copy and Switch")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showArchiveMoveError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Move Existing Archive Failed"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        _ = alert.runModal()
    }

    private func showArchiveMoveSuccess(from sourceRoot: URL, to destinationRoot: URL) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Archive Move Complete"
        alert.informativeText =
            """
            Librarian is now using:
            \(destinationRoot.path)

            Previous archive remains at:
            \(sourceRoot.path)
            """
        alert.addButton(withTitle: "OK")
        _ = alert.runModal()
    }

    nonisolated private static func preflightArchiveMove(sourceRoot: URL, destinationRoot: URL) throws -> ArchiveMovePreflight {
        let sourcePath = canonicalPath(for: sourceRoot)
        let destinationPath = canonicalPath(for: destinationRoot)
        if sourcePath == destinationPath {
            throw NSError(domain: "\(AppBrand.identifierPrefix).archiveMove", code: 10, userInfo: [
                NSLocalizedDescriptionKey: """
                Destination must be different from the current archive location.
                Current: \(sourcePath)
                Selected: \(destinationPath)
                """
            ])
        }
        if isPath(destinationRoot, inside: sourceRoot) {
            throw NSError(domain: "\(AppBrand.identifierPrefix).archiveMove", code: 11, userInfo: [
                NSLocalizedDescriptionKey: """
                Destination cannot be inside the current archive.
                Current: \(sourcePath)
                Selected: \(destinationPath)
                """
            ])
        }

        let sourceAvailability = ArchiveSettings.archiveRootAvailability(for: sourceRoot)
        guard sourceAvailability == .available else {
            throw NSError(domain: "\(AppBrand.identifierPrefix).archiveMove", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Current archive is not available: \(sourceAvailability.userVisibleDescription)"
            ])
        }

        guard ArchiveSettings.archiveID(for: sourceRoot) != nil else {
            throw NSError(domain: "\(AppBrand.identifierPrefix).archiveMove", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Current archive is missing its control metadata."
            ])
        }

        let fileManager = FileManager.default
        let destinationExists = fileManager.fileExists(atPath: destinationRoot.path)

        if destinationExists {
            let destinationAvailability = ArchiveSettings.archiveRootAvailability(for: destinationRoot)
            guard destinationAvailability == .available else {
                throw NSError(domain: "\(AppBrand.identifierPrefix).archiveMove", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Selected destination is not writable: \(destinationAvailability.userVisibleDescription)"
                ])
            }
        } else {
            let parent = destinationRoot.deletingLastPathComponent()
            let parentAvailability = ArchiveSettings.archiveRootAvailability(for: parent)
            guard parentAvailability == .available else {
                throw NSError(domain: "\(AppBrand.identifierPrefix).archiveMove", code: 12, userInfo: [
                    NSLocalizedDescriptionKey: "Destination parent folder is not writable: \(parentAvailability.userVisibleDescription)"
                ])
            }
        }

        guard ArchiveSettings.archiveID(for: destinationRoot) == nil else {
            throw NSError(domain: "\(AppBrand.identifierPrefix).archiveMove", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Selected destination already appears to be a Librarian archive."
            ])
        }

        if destinationExists {
            let conflicts = try conflictingDestinationPaths(
                sourceRoot: sourceRoot,
                destinationRoot: destinationRoot,
                fileManager: fileManager
            )
            if !conflicts.isEmpty {
                let preview = conflicts.prefix(3).joined(separator: "\n")
                let suffix = conflicts.count > 3 ? "\n(and \(conflicts.count - 3) more)" : ""
                throw NSError(domain: "\(AppBrand.identifierPrefix).archiveMove", code: 5, userInfo: [
                    NSLocalizedDescriptionKey: """
                    Selected destination already contains files that would be overwritten.
                    Destination: \(destinationPath)
                    Conflicts:
                    \(preview)\(suffix)
                    """
                ])
            }
        }

        let stats = try directoryStats(root: sourceRoot, fileManager: fileManager)
        let freeBytes = try destinationRoot.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage

        if let freeBytes, Int64(freeBytes) < stats.totalBytes {
            throw NSError(domain: "\(AppBrand.identifierPrefix).archiveMove", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "Not enough free space at destination."
            ])
        }

        return ArchiveMovePreflight(
            sourceFileCount: stats.fileCount,
            sourceTotalBytes: stats.totalBytes,
            destinationFreeBytes: freeBytes.map { Int64($0) }
        )
    }

    nonisolated private static func copyAndVerifyArchiveMove(
        sourceRoot: URL,
        destinationRoot: URL,
        expectedFileCount: Int
    ) throws {
        let fileManager = FileManager.default
        let sourceAccess = sourceRoot.startAccessingSecurityScopedResource()
        let destinationAccess = destinationRoot.startAccessingSecurityScopedResource()
        defer {
            if sourceAccess { sourceRoot.stopAccessingSecurityScopedResource() }
            if destinationAccess { destinationRoot.stopAccessingSecurityScopedResource() }
        }

        if isPath(destinationRoot, inside: sourceRoot) {
            throw NSError(domain: "\(AppBrand.identifierPrefix).archiveMove", code: 11, userInfo: [
                NSLocalizedDescriptionKey: """
                Destination cannot be inside the current archive.
                Current: \(canonicalPath(for: sourceRoot))
                Selected: \(canonicalPath(for: destinationRoot))
                """
            ])
        }

        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        guard let enumerator = fileManager.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            throw NSError(domain: "\(AppBrand.identifierPrefix).archiveMove", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "Could not enumerate source archive."
            ])
        }

        var copiedFileCount = 0
        let destinationPath = canonicalPath(for: destinationRoot)
        while let sourceURL = enumerator.nextObject() as? URL {
            let sourcePath = canonicalPath(for: sourceURL)
            if sourcePath == destinationPath || sourcePath.hasPrefix(destinationPath + "/") {
                enumerator.skipDescendants()
                continue
            }

            let values = try sourceURL.resourceValues(forKeys: [.isDirectoryKey])
            guard let relativePath = relativePath(from: sourceRoot, to: sourceURL) else { continue }
            let destinationURL = destinationRoot.appendingPathComponent(relativePath, isDirectory: values.isDirectory == true)
            if values.isDirectory == true {
                try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
            } else {
                let parent = destinationURL.deletingLastPathComponent()
                try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
                copiedFileCount += 1
            }
        }

        guard copiedFileCount == expectedFileCount else {
            throw NSError(domain: "\(AppBrand.identifierPrefix).archiveMove", code: 8, userInfo: [
                NSLocalizedDescriptionKey: "Verification failed after copy (\(copiedFileCount) of \(expectedFileCount) files)."
            ])
        }
    }

    nonisolated private static func conflictingDestinationPaths(
        sourceRoot: URL,
        destinationRoot: URL,
        fileManager: FileManager
    ) throws -> [String] {
        guard let enumerator = fileManager.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            return []
        }

        var conflicts: [String] = []
        for case let sourceURL as URL in enumerator {
            guard let relativePath = relativePath(from: sourceRoot, to: sourceURL) else { continue }
            let destinationURL = destinationRoot.appendingPathComponent(relativePath)
            if fileManager.fileExists(atPath: destinationURL.path) {
                conflicts.append(relativePath)
            }
        }
        return conflicts
    }

    nonisolated private static func directoryStats(root: URL, fileManager: FileManager) throws -> (fileCount: Int, totalBytes: Int64) {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: []
        ) else {
            return (0, 0)
        }
        var count = 0
        var bytes: Int64 = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true {
                count += 1
                bytes += Int64(values.fileSize ?? 0)
            }
        }
        return (count, bytes)
    }

    nonisolated private static func isPath(_ candidate: URL, inside root: URL) -> Bool {
        let candidatePath = canonicalPath(for: candidate)
        let rootPath = canonicalPath(for: root)
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    nonisolated private static func relativePath(from root: URL, to child: URL) -> String? {
        let rootPath = root.standardizedFileURL.path
        let childPath = child.standardizedFileURL.path
        guard childPath.hasPrefix(rootPath) else { return nil }
        var rel = String(childPath.dropFirst(rootPath.count))
        if rel.hasPrefix("/") {
            rel.removeFirst()
        }
        return rel.isEmpty ? nil : rel
    }

    nonisolated private static func canonicalPath(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

#if DEBUG
    nonisolated static func test_preflightArchiveMove(sourceRoot: URL, destinationRoot: URL) throws {
        _ = try preflightArchiveMove(sourceRoot: sourceRoot, destinationRoot: destinationRoot)
    }

    nonisolated static func test_copyAndVerifyArchiveMove(
        sourceRoot: URL,
        destinationRoot: URL,
        expectedFileCount: Int
    ) throws {
        try copyAndVerifyArchiveMove(
            sourceRoot: sourceRoot,
            destinationRoot: destinationRoot,
            expectedFileCount: expectedFileCount
        )
    }
#endif

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
