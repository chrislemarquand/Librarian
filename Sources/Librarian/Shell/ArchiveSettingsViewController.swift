import AppKit
import SharedUI

final class ArchiveSettingsViewController: SettingsGridViewController {
    private enum ExistingArchivePromptChoice { case switchToThis, chooseDifferent, cancel }

    private let model: AppModel
    private let archiveOrganizer = ArchiveOrganizer()
    private var archiveImportSheetPresenter: ArchiveImportSheetPresenter?
    private var isOrganizingArchive = false
    private var isMovingArchive = false

    private lazy var archivePathControl = makePathControl(url: nil)
    private lazy var linkedLibraryPathControl = makePathControl(url: nil)
    private lazy var linkedLibraryFallbackLabel = makeDescriptionLabel("Not linked")
    private lazy var linkedLibraryContainer: NSStackView = {
        let stack = NSStackView(views: [linkedLibraryPathControl, linkedLibraryFallbackLabel])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()
    private lazy var showInFinderButton = makeActionButton(title: "Show in Finder", action: #selector(showArchiveInFinder))
    private lazy var newButton          = makeActionButton(title: "New…",           action: #selector(chooseNewArchive))
    private lazy var moveButton         = makeActionButton(title: "Move…",          action: #selector(chooseMoveDestination))
    private lazy var archiveActionButtons: NSStackView = {
        let stack = NSStackView(views: [showInFinderButton, newButton, moveButton])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()
    private lazy var dateOnlyRadio     = makeRadioButton(title: "Date",
                                                        action: #selector(folderLayoutChanged(_:)))
    private lazy var kindThenDateRadio = makeRadioButton(title: "Type then Date",
                                                        action: #selector(folderLayoutChanged(_:)))
    private lazy var organizeButton   = makeActionButton(title: "Organize Archive",      action: #selector(organizeArchiveManually))
    private lazy var organizeLabel    = makeDescriptionLabel("Scans the archive and normalizes folders to YYYY/MM/DD.")
    private lazy var addPhotosButton  = makeActionButton(title: "Add Photos to Archive…", action: #selector(addPhotosToArchive))
    private lazy var addPhotosLabel   = makeDescriptionLabel("Copy photos from a folder into the archive. Original files are never moved or deleted.")

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
        NotificationCenter.default.addObserver(
            self, selector: #selector(archiveBindingChanged),
            name: .librarianArchiveLibraryBindingChanged, object: nil
        )
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if archiveImportSheetPresenter == nil {
            archiveImportSheetPresenter = ArchiveImportSheetPresenter(
                model: model,
                parentWindowProvider: { [weak self] in self?.view.window },
                onDismiss: { [weak self] in
                    guard let self else { return }
                    self.refreshAddPhotosButtonState()
                }
            )
        }
        refreshArchivePath()
        refreshLinkedLibraryPath()
        refreshNewButtonState()
        refreshMoveButtonState()
        refreshFolderLayoutState()
        refreshOrganizeButtonState()
        refreshAddPhotosButtonState()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func makeRows() -> [[NSView]] {
        [
            [makeCategoryLabel(title: "Archive Location:"), archivePathControl,   NSView()],
            [makeCategoryLabel(title: "Linked Photos Library:"), linkedLibraryContainer, NSView()],
            [NSView(),                                      archiveActionButtons, NSView()],
            [makeCategoryLabel(title: "Folder structure:"), dateOnlyRadio,        NSView()],
            [NSView(),                                      kindThenDateRadio,    NSView()],
            [makeCategoryLabel(title: "Archive organization:"), organizeLabel,  organizeButton],
            [makeCategoryLabel(title: "Add photos:"),           addPhotosLabel, addPhotosButton],
        ]
    }

    // MARK: - Actions

    @objc private func showArchiveInFinder() {
        if let treeRoot = ArchiveSettings.currentArchiveTreeRootURL() {
            NSWorkspace.shared.activateFileViewerSelecting([treeRoot])
            return
        }
        guard let fallbackRoot = ArchiveSettings.restoreArchiveRootURL() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([fallbackRoot])
    }

    @objc private func chooseNewArchive() {
        runNewArchivePicker(retrying: false)
    }

    private func runNewArchivePicker(retrying: Bool) {
        let panel = NSOpenPanel()
        panel.prompt = "Choose"
        panel.message = retrying
            ? "Choose an empty or new folder for the archive."
            : "Choose a location for a new archive, or select an existing Librarian archive to switch to it."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = ArchiveSettings.restoreArchiveRootURL() ?? FileManager.default.homeDirectoryForCurrentUser
        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }
        let url = ArchiveSettings.resolveArchiveRoot(fromUserSelection: selectedURL)
            ?? normalizedArchiveRootForCreateSelection(selectedURL)

        // Same folder as current — nothing to do.
        if url.standardizedFileURL == ArchiveSettings.restoreArchiveRootURL()?.standardizedFileURL { return }

        if let selectedArchiveID = ArchiveSettings.archiveID(for: url) {
            // Existing Librarian archive detected — let the user decide.
            switch promptExistingArchiveDetected(at: url) {
            case .switchToThis:
                let currentArchiveID = UserDefaults.standard.string(forKey: ArchiveSettings.archiveIDKey)
                if let currentArchiveID, selectedArchiveID != currentArchiveID,
                   !ArchiveRootPrompts.confirmArchiveSwitch(fromArchiveID: currentArchiveID, toArchiveID: selectedArchiveID) {
                    return
                }
                guard model.updateArchiveRoot(url) else { return }
                refreshArchivePath()
                Task { @MainActor [weak self] in
                    await self?.scanArchiveAndPromptToOrganizeIfNeeded()
                }
            case .chooseDifferent:
                runNewArchivePicker(retrying: true)
            case .cancel:
                return
            }
        } else {
            // New location — confirm initialization and proceed.
            if !ArchiveRootPrompts.confirmInitializeArchive(at: url) { return }
            guard model.updateArchiveRoot(url) else { return }
            refreshArchivePath()
            Task { @MainActor [weak self] in
                await self?.scanArchiveAndPromptToOrganizeIfNeeded()
            }
        }
    }

    private func promptExistingArchiveDetected(at url: URL) -> ExistingArchivePromptChoice {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Existing Archive Detected"
        alert.informativeText =
            """
            The selected folder is already a Librarian archive:
            \(url.path)

            Switch to this archive, or choose a different location for a new archive?
            """
        alert.addButton(withTitle: "Switch to This")
        alert.addButton(withTitle: "Choose Different Location…")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:  return .switchToThis
        case .alertSecondButtonReturn: return .chooseDifferent
        default:                       return .cancel
        }
    }

    @objc private func chooseMoveDestination() {
        guard let currentRootURL = ArchiveSettings.restoreArchiveRootURL() else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Move Destination"
        panel.message = "Choose where to move your archive. Librarian will move all archive files and switch to the new location."
        panel.prompt = "Move Here"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor [weak self] in
            await self?.moveExistingArchive(currentRootURL: currentRootURL, newRootURL: url)
        }
    }

    @objc private func organizeArchiveManually() {
        Task { @MainActor [weak self] in
            await self?.organizeArchive()
        }
    }

    @objc private func addPhotosToArchive() {
        archiveImportSheetPresenter?.present(mode: .pathAUserPick)
    }

    // MARK: - Notification handler

    @objc private func folderLayoutChanged(_ sender: NSButton) {
        if sender === dateOnlyRadio {
            ArchiveSettings.folderLayout = .dateOnly
        } else if sender === kindThenDateRadio {
            ArchiveSettings.folderLayout = .kindThenDate
        }
    }

    @objc private func archiveRootChanged() {
        refreshArchivePath()
        refreshLinkedLibraryPath()
        refreshNewButtonState()
        refreshMoveButtonState()
        refreshFolderLayoutState()
        refreshOrganizeButtonState()
        refreshAddPhotosButtonState()
    }

    @objc private func archiveBindingChanged() {
        refreshLinkedLibraryPath()
    }

    // MARK: - State refresh

    private func refreshArchivePath() {
        guard model.archiveRootAvailability != .unavailable else {
            archivePathControl.url = nil
            return
        }
        guard let treeRoot = ArchiveSettings.currentArchiveTreeRootURL() else {
            archivePathControl.url = nil
            return
        }
        archivePathControl.url = treeRoot
        let all = archivePathControl.pathItems
        if all.count > 4 { archivePathControl.pathItems = Array(all.suffix(4)) }
    }

    private func refreshLinkedLibraryPath() {
        guard let archiveRoot = ArchiveSettings.restoreArchiveRootURL(),
              let path = ArchiveSettings.controlConfig(for: archiveRoot)?.photoLibraryBinding?.libraryPathHint,
              !path.isEmpty else {
            linkedLibraryPathControl.url = nil
            linkedLibraryPathControl.isHidden = true
            linkedLibraryFallbackLabel.isHidden = false
            return
        }
        let url = URL(fileURLWithPath: path)
        linkedLibraryPathControl.url = url
        let all = linkedLibraryPathControl.pathItems
        if all.count > 1 {
            linkedLibraryPathControl.pathItems = Array(all.suffix(1))
        }
        linkedLibraryPathControl.isHidden = false
        linkedLibraryFallbackLabel.isHidden = true
    }

    private func refreshNewButtonState() {
        let hasRoot = ArchiveSettings.restoreArchiveRootURL() != nil
        showInFinderButton.isEnabled = hasRoot && !isMovingArchive
        newButton.isEnabled = !isMovingArchive
    }

    private func refreshMoveButtonState() {
        let hasRoot = ArchiveSettings.restoreArchiveRootURL() != nil
        moveButton.isEnabled = hasRoot && !isMovingArchive
        moveButton.title = isMovingArchive ? "Moving…" : "Move…"
    }

    private func refreshFolderLayoutState() {
        let current = ArchiveSettings.folderLayout
        dateOnlyRadio.state     = current == .dateOnly     ? .on : .off
        kindThenDateRadio.state = current == .kindThenDate ? .on : .off
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

    private func refreshAddPhotosButtonState() {
        let hasRoot = ArchiveSettings.restoreArchiveRootURL() != nil
        addPhotosButton.isEnabled = hasRoot && !model.isImportingArchive && !isMovingArchive
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

        organizeLabel.stringValue = "\(count.formatted()) unorganized files detected."
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Organize New Archive Location?"
        alert.informativeText = "Librarian found \(count.formatted()) files outside the YYYY/MM/DD folder pattern. Organize them now?"
        alert.addButton(withTitle: "Organize Now")
        alert.addButton(withTitle: "Not Now")

        let response = await alert.runSheetOrModal(for: view.window)
        guard response == .alertFirstButtonReturn else { return }
        await organizeArchive()
    }

    @MainActor
    private func organizeArchive() async {
        guard !isOrganizingArchive else { return }
        let gate = model.evaluateArchiveWriteGate(for: .organizeArchive)
        guard gate.isAllowed else {
            let resolved = await ArchiveLibraryMismatchPrompt.resolveWriteGateIfPossible(
                model: model,
                decision: gate,
                operation: .organizeArchive,
                parentWindow: view.window
            )
            guard resolved else {
                organizeLabel.stringValue = gate.message
                return
            }
            await organizeArchive()
            return
        }
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
        organizeLabel.stringValue = "Moved \(summary.movedCount.formatted()) files. \(summary.alreadyOrganizedCount.formatted()) already organized."
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
        refreshNewButtonState()
        refreshMoveButtonState()
        refreshOrganizeButtonState()
        refreshAddPhotosButtonState()

        let destinationRoot = newRootURL.standardizedFileURL

        let preflight: ArchiveMovePreflight
        do {
            preflight = try await Task.detached(priority: .utility) {
                try Self.preflightArchiveMove(sourceRoot: currentRootURL, destinationRoot: destinationRoot)
            }.value
        } catch {
            isMovingArchive = false
            refreshNewButtonState()
        refreshMoveButtonState()
            refreshOrganizeButtonState()
            refreshAddPhotosButtonState()
            showArchiveMoveError("Librarian couldn’t prepare the move. \(error.localizedDescription)")
            return
        }

        guard confirmArchiveMove(
            from: currentRootURL,
            to: destinationRoot,
            preflight: preflight
        ) else {
            isMovingArchive = false
            refreshNewButtonState()
        refreshMoveButtonState()
            refreshOrganizeButtonState()
            refreshAddPhotosButtonState()
            return
        }

        do {
            try await Task.detached(priority: .utility) {
                try Self.moveAndVerifyArchive(
                    sourceRoot: currentRootURL,
                    destinationRoot: destinationRoot,
                    expectedFileCount: preflight.sourceFileCount
                )
            }.value
        } catch {
            isMovingArchive = false
            refreshNewButtonState()
        refreshMoveButtonState()
            refreshOrganizeButtonState()
            refreshAddPhotosButtonState()
            showArchiveMoveError("Librarian couldn’t move the archive. \(error.localizedDescription)")
            return
        }

        guard model.updateArchiveRoot(destinationRoot) else {
            isMovingArchive = false
            refreshNewButtonState()
        refreshMoveButtonState()
            refreshOrganizeButtonState()
            refreshAddPhotosButtonState()
            showArchiveMoveError("Archive was moved, but Librarian couldn’t switch to the new location.")
            return
        }

        refreshArchivePath()
        await scanArchiveAndPromptToOrganizeIfNeeded()
        isMovingArchive = false
        refreshNewButtonState()
        refreshMoveButtonState()
        refreshOrganizeButtonState()
        refreshAddPhotosButtonState()
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
            Librarian will move your current archive to the selected destination and switch to it after verification.

            Files to move: \(preflight.sourceFileCount.formatted())
            Estimated size: \(sizeText)
            Destination free space: \(freeText)
            """
        alert.addButton(withTitle: "Move and Switch")
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
            """
        alert.addButton(withTitle: "OK")
        _ = alert.runModal()
    }

    nonisolated private static func preflightArchiveMove(sourceRoot: URL, destinationRoot: URL) throws -> ArchiveMovePreflight {
        let sourceArchiveRoot = ArchiveSettings.archiveTreeRootURL(from: sourceRoot)
        let destinationArchiveRoot = ArchiveSettings.archiveTreeRootURL(from: destinationRoot)
        let sourcePath = canonicalPath(for: sourceArchiveRoot)
        let destinationPath = canonicalPath(for: destinationArchiveRoot)
        if sourcePath == destinationPath {
            throw NSError(domain: "\(AppBrand.identifierPrefix).archiveMove", code: 10, userInfo: [
                NSLocalizedDescriptionKey: """
                Destination must be different from the current archive location.
                Current: \(sourcePath)
                Selected: \(destinationPath)
                """
            ])
        }
        if isPath(destinationArchiveRoot, inside: sourceArchiveRoot) {
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
                NSLocalizedDescriptionKey: "Current archive is missing required Librarian metadata."
            ])
        }

        let fileManager = FileManager.default
        let destinationExists = fileManager.fileExists(atPath: destinationRoot.path)

        if destinationExists {
            guard isWritableDirectory(destinationRoot, fileManager: fileManager) else {
                throw NSError(domain: "\(AppBrand.identifierPrefix).archiveMove", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Selected destination is not writable."
                ])
            }
        } else {
            let parent = destinationRoot.deletingLastPathComponent()
            guard isWritableDirectory(parent, fileManager: fileManager) else {
                throw NSError(domain: "\(AppBrand.identifierPrefix).archiveMove", code: 12, userInfo: [
                    NSLocalizedDescriptionKey: "Destination parent folder is not writable."
                ])
            }
        }

        guard ArchiveSettings.archiveID(for: destinationRoot) == nil else {
            throw NSError(domain: "\(AppBrand.identifierPrefix).archiveMove", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Selected destination already appears to be a Librarian archive."
            ])
        }

        if fileManager.fileExists(atPath: destinationArchiveRoot.path) {
            let conflicts = try conflictingDestinationPaths(
                sourceRoot: sourceArchiveRoot,
                destinationRoot: destinationArchiveRoot,
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

        let stats = try directoryStats(root: sourceArchiveRoot, fileManager: fileManager)
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

    nonisolated private static func moveAndVerifyArchive(
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

        let sourceArchiveRoot = ArchiveSettings.archiveTreeRootURL(from: sourceRoot)
        let destinationArchiveRoot = ArchiveSettings.archiveTreeRootURL(from: destinationRoot)

        if isPath(destinationArchiveRoot, inside: sourceArchiveRoot) {
            throw NSError(domain: "\(AppBrand.identifierPrefix).archiveMove", code: 11, userInfo: [
                NSLocalizedDescriptionKey: """
                Destination cannot be inside the current archive.
                Current: \(canonicalPath(for: sourceArchiveRoot))
                Selected: \(canonicalPath(for: destinationArchiveRoot))
                """
            ])
        }

        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destinationArchiveRoot.path) {
            throw NSError(domain: "\(AppBrand.identifierPrefix).archiveMove", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "Selected destination already contains an Archive folder."
            ])
        }
        try fileManager.moveItem(at: sourceArchiveRoot, to: destinationArchiveRoot)

        if fileManager.fileExists(atPath: sourceArchiveRoot.path) {
            throw NSError(domain: "\(AppBrand.identifierPrefix).archiveMove", code: 8, userInfo: [
                NSLocalizedDescriptionKey: "Verification failed after move. Source archive folder still exists."
            ])
        }

        let destinationStats = try directoryStats(root: destinationArchiveRoot, fileManager: fileManager)
        guard destinationStats.fileCount >= expectedFileCount else {
            throw NSError(domain: "\(AppBrand.identifierPrefix).archiveMove", code: 8, userInfo: [
                NSLocalizedDescriptionKey: "Verification failed after move (\(destinationStats.fileCount) of \(expectedFileCount) files visible at destination)."
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

    nonisolated private static func isWritableDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }

        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        if !didAccess && !fileManager.isReadableFile(atPath: url.path) {
            return false
        }
        if !fileManager.isWritableFile(atPath: url.path) {
            return false
        }

        do {
            let values = try url.resourceValues(forKeys: [.volumeIsReadOnlyKey])
            if values.volumeIsReadOnly == true {
                return false
            }
        } catch {
            return false
        }

        return true
    }

    private func normalizedArchiveRootForCreateSelection(_ selectedURL: URL) -> URL {
        let selected = selectedURL.standardizedFileURL
        guard selected.lastPathComponent == ArchiveSettings.archiveFolderName else {
            return selected
        }
        return selected.deletingLastPathComponent().standardizedFileURL
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
        try moveAndVerifyArchive(
            sourceRoot: sourceRoot,
            destinationRoot: destinationRoot,
            expectedFileCount: expectedFileCount
        )
    }
#endif

}
