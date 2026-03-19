import Cocoa

final class MainSplitViewController: NSSplitViewController {

    let model: AppModel
    let toolbarDelegate: ToolbarDelegate

    private let sidebarController: SidebarController
    private let contentController: ContentController
    private let inspectorController: InspectorController

    // The inner split holds content + inspector side by side.
    // Internal so ToolbarDelegate can reference its splitView for tracking separators.
    let innerSplit = NSSplitViewController()

    private static let mainSplitAutosave = "com.librarian.app.MainSplit"
    private static let innerSplitAutosave = "com.librarian.app.InnerSplit"
    private var didApplyInitialSplit = false
    private var keyEventMonitor: Any?

    init(model: AppModel) {
        self.model = model
        self.sidebarController = SidebarController(model: model)
        self.contentController = ContentController(model: model)
        self.inspectorController = InspectorController(model: model)
        self.toolbarDelegate = ToolbarDelegate()
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        buildSplitLayout()
        inspectorSplitItem?.isCollapsed = true
        toolbarDelegate.configure(splitVC: self)
        observeModelState()
        installKeyEventMonitor()
        observeInnerSplitResize()
        syncInspectorState()
        toolbarDelegate.refresh(model: model)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        applyInitialInnerSplitIfNeeded()
        refreshWindowTitle()
        refreshWindowSubtitle()
    }

    deinit {
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    // MARK: - Layout

    private func buildSplitLayout() {
        splitView.isVertical = true
        splitView.autosaveName = NSSplitView.AutosaveName(Self.mainSplitAutosave)
        splitView.dividerStyle = .thin

        let sidebarWrap = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarWrap.minimumThickness = 200
        sidebarWrap.allowsFullHeightLayout = true
        addSplitViewItem(sidebarWrap)

        innerSplit.splitView.isVertical = true
        innerSplit.splitView.autosaveName = NSSplitView.AutosaveName(Self.innerSplitAutosave)
        innerSplit.splitView.dividerStyle = .thin

        let contentWrap = NSSplitViewItem(viewController: contentController)
        contentWrap.minimumThickness = 300
        contentWrap.holdingPriority = NSLayoutConstraint.Priority(rawValue: NSLayoutConstraint.Priority.defaultLow.rawValue - 1)
        innerSplit.addSplitViewItem(contentWrap)

        let inspectorWrap = NSSplitViewItem(inspectorWithViewController: inspectorController)
        inspectorWrap.minimumThickness = 240
        inspectorWrap.maximumThickness = 480
        inspectorWrap.canCollapse = true
        inspectorWrap.holdingPriority = .defaultLow
        innerSplit.addSplitViewItem(inspectorWrap)

        let innerWrap = NSSplitViewItem(viewController: innerSplit)
        innerWrap.holdingPriority = .defaultLow
        addSplitViewItem(innerWrap)

        sidebarController.view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sidebarController.view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        inspectorController.view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        inspectorController.view.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    private var inspectorSplitItem: NSSplitViewItem? {
        innerSplit.splitViewItems.count == 2 ? innerSplit.splitViewItems[1] : nil
    }

    // MARK: - Inspector toggle

    @objc override func toggleInspector(_ sender: Any?) {
        guard let item = inspectorSplitItem else { return }
        let previous = view.window?.firstResponder
        item.animator().isCollapsed.toggle()
        syncInspectorState()
        if let previous {
            DispatchQueue.main.async { [weak self] in
                self?.view.window?.makeFirstResponder(previous)
            }
        }
    }

    private func syncInspectorState() {
        guard let item = inspectorSplitItem else { return }
        model.isInspectorCollapsed = item.isCollapsed
        toolbarDelegate.refresh(model: model)
    }

    // MARK: - Split resize observation

    private func observeInnerSplitResize() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(innerSplitDidResize(_:)),
            name: NSSplitView.didResizeSubviewsNotification,
            object: innerSplit.splitView
        )
    }

    private func observeModelState() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(modelStateChanged),
            name: .librarianIndexingStateChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sidebarSelectionChanged),
            name: .librarianSidebarSelectionChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(modelStateChanged),
            name: .librarianGalleryZoomChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(modelStateChanged),
            name: .librarianSelectionChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(modelStateChanged),
            name: .librarianArchiveQueueChanged,
            object: nil
        )
    }

    @objc private func modelStateChanged() {
        toolbarDelegate.refresh(model: model)
        refreshWindowSubtitle()
    }

    @objc private func sidebarSelectionChanged() {
        refreshWindowTitle()
        refreshWindowSubtitle()
        toolbarDelegate.refresh(model: model)
    }

    @objc private func innerSplitDidResize(_ notification: Notification) {
        syncInspectorState()
    }

    // MARK: - Initial proportions

    private func applyInitialInnerSplitIfNeeded() {
        guard !didApplyInitialSplit else { return }
        didApplyInitialSplit = true

        let key = "NSSplitView Subview Frames \(Self.innerSplitAutosave)"
        guard UserDefaults.standard.object(forKey: key) == nil else { return }

        let total = innerSplit.splitView.bounds.width
        guard total > 400 else { return }

        let target = min(max(total * 0.68, 300), total - 240)
        innerSplit.splitView.setPosition(target, ofDividerAt: 0)
    }

    // MARK: - Keyboard

    private func installKeyEventMonitor() {
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event) ?? event
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 34, modifiers == [.command, .control] { // ⌘⌃I
            toggleInspector(nil)
            return nil
        }
        return event
    }

    private func refreshWindowTitle() {
        let itemTitle = model.selectedSidebarItem?.title ?? "Librarian"
        view.window?.title = itemTitle
    }

    private var lastSubtitleText = ""

    private func refreshWindowSubtitle() {
        guard let kind = model.selectedSidebarItem?.kind else {
            setSubtitle("")
            return
        }
        guard model.database.assetRepository != nil else { return }
        let database = model.database
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let count = (try? database.assetRepository.countForSidebarKind(kind)) ?? 0
            let text: String
            switch kind {
            case .log, .indexing:
                text = ""
            case .setAsideForArchive, .archived, .duplicates, .lowQuality, .receiptsAndDocuments, .screenshots:
                text = count == 1 ? "1 item" : "\(count.formatted()) items"
            case .allPhotos, .recents, .favourites:
                text = count == 1 ? "1 photo" : "\(count.formatted()) photos"
            }
            DispatchQueue.main.async { [weak self] in
                self?.setSubtitle(text)
            }
        }
    }

    private func setSubtitle(_ text: String) {
        guard text != lastSubtitleText else { return }
        lastSubtitleText = text
        view.window?.subtitle = text
    }

    @objc func openSelectionInPhotos(_ sender: Any?) {
        contentController.openSelectionInPhotos()
    }

    @objc func refreshCurrentViewAction(_ sender: Any?) {
        contentController.refreshDisplayedAssets()
    }

    @objc func setAsideSelectionAction(_ sender: Any?) {
        contentController.queueSelectedAssetsForArchive()
        toolbarDelegate.refresh(model: model)
    }

    @objc func putBackSelectionAction(_ sender: Any?) {
        if canPutBackSelection {
            contentController.putBackSelectedArchiveAssets()
        } else if canPutBackFailedItems {
            do {
                let removed = try model.unqueueFailedArchiveAssets()
                if removed > 0 {
                    showArchiveAlert(
                        title: "Put Back Failed Items",
                        message: "Removed \(removed) failed item(s) from Set Aside."
                    )
                }
                contentController.refreshDisplayedAssets()
            } catch {
                AppLog.shared.error("Failed to put back failed archive items: \(error.localizedDescription)")
                showArchiveAlert(title: "Put Back Failed Items", message: error.localizedDescription)
            }
        }
        toolbarDelegate.refresh(model: model)
    }

    @objc func sendToArchiveAction(_ sender: Any?) {
        guard model.pendingArchiveCandidateCount > 0 else { return }
        guard let archiveRoot = resolveOrPromptArchiveRoot() else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let didAccess = archiveRoot.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    archiveRoot.stopAccessingSecurityScopedResource()
                }
            }
            do {
                try await self.model.sendPendingArchive(to: archiveRoot)
                self.showArchiveAlert(
                    title: "Archive Complete",
                    message: "Set-aside photos were exported and moved to Recently Deleted in Photos."
                )
            } catch {
                AppLog.shared.error("Send to archive failed: \(error.localizedDescription)")
                self.showArchiveAlert(
                    title: "Archive Failed",
                    message: error.localizedDescription
                )
            }
            self.contentController.refreshDisplayedAssets()
            self.toolbarDelegate.refresh(model: self.model)
        }
    }

    @objc func zoomOutAction(_ sender: Any?) {
        guard isGallerySidebarSelection else { return }
        model.decreaseGalleryZoom()
        toolbarDelegate.refresh(model: model)
    }

    @objc func zoomInAction(_ sender: Any?) {
        guard isGallerySidebarSelection else { return }
        model.increaseGalleryZoom()
        toolbarDelegate.refresh(model: model)
    }

    private var isGallerySidebarSelection: Bool {
        switch model.selectedSidebarItem?.kind ?? .allPhotos {
        case .allPhotos, .recents, .favourites, .screenshots, .setAsideForArchive, .archived,
             .duplicates, .lowQuality, .receiptsAndDocuments:
            return true
        case .indexing, .log:
            return false
        }
    }

    var canSetAsideSelection: Bool {
        isGallerySidebarSelection && contentController.hasSelectedAssets
    }

    var canPutBackSelection: Bool {
        contentController.canPutBackFromArchiveQueue && !model.isSendingArchive
    }

    var canPutBackFailedItems: Bool {
        model.selectedSidebarItem?.kind == .setAsideForArchive
            && model.failedArchiveCandidateCount > 0
            && !model.isSendingArchive
    }

    private func resolveOrPromptArchiveRoot() -> URL? {
        if let existing = ArchiveSettings.restoreArchiveRootURL() {
            return existing
        }
        guard let chosen = promptForArchiveRoot() else { return nil }
        guard ArchiveSettings.persistArchiveRootURL(chosen) else { return nil }
        return chosen
    }

    private func promptForArchiveRoot() -> URL? {
        let panel = NSOpenPanel()
        panel.prompt = "Set Archive Folder"
        panel.message = "Choose where Librarian should export archived photos."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        let result = panel.runModal()
        guard result == .OK else { return nil }
        return panel.url
    }

    private func showArchiveAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }
}
