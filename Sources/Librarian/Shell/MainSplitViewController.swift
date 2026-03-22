import Cocoa
import SharedUI
import SwiftUI
import Combine

@MainActor
final class MainSplitViewController: ThreePaneSplitViewController {

    let model: AppModel
    let toolbarDelegate: ToolbarDelegate

    private let sidebarController: AppKitSidebarController<SidebarSection, SidebarItem>
    private let contentController: ContentController
    private let inspectorController: InspectorController

    private var inspectorKeyMonitor: Any?
    private var keyboardParityMonitor: Any?
    private var archiveExportSheetWindow: NSWindow?
    private var archiveImportSheetPresenter: ArchiveImportSheetPresenter?
    private var lastBindingPromptSignature: String?
    private var isShowingBindingPrompt = false
    private var subtitleObservers: Set<AnyCancellable> = []
    private var toolbarShellController: ToolbarShellController?
    private var didConfigureToolbar = false

    init(model: AppModel) {
        self.model = model

        let sc = AppKitSidebarController(
            sections: SidebarSection.allCases,
            items: Self.buildSidebarItemsWithBadges(model: model)
        )
        let cc = ContentController(model: model)
        let ic = InspectorController(model: model)
        self.sidebarController = sc
        self.contentController = cc
        self.inspectorController = ic
        self.toolbarDelegate = ToolbarDelegate()

        super.init(
            sidebar: sc,
            content: cc,
            inspector: ic,
            mainSplitAutosaveName: "\(AppBrand.identifierPrefix).MainSplit",
            contentSplitAutosaveName: "\(AppBrand.identifierPrefix).InnerSplit",
            inspectorStartsVisible: false
        )

        sc.onSelectionChange = { [weak self] item in
            self?.model.setSelectedSidebarItem(item)
        }

        sc.menuProvider = { [weak self] item in
            self?.sidebarContextMenu(for: item)
        }
        sc.onItemsReordered = { reorderedItems in
            SidebarItem.persistQueueOrder(from: reorderedItems)
        }

        onPaneStateChanged = { [weak self] in
            guard let self else { return }
            self.model.isInspectorCollapsed = self.isInspectorCollapsed
            self.refreshToolbarState()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        toolbarDelegate.configure(splitVC: self)
        observeModelState()
        installSubtitleObservers()
        installContentKeyboardMonitor(contentView: contentController.view) { [weak self] in
            guard let self, self.isGallerySidebarSelection else { return }
            self.quickLookSelectionAction(nil)
        }
        inspectorKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard event.keyCode == 34, modifiers == [.command, .option] else { return event } // ⌘⌥I
            self.toggleInspector(nil)
            return nil
        }
        installKeyboardParityMonitorIfNeeded()
        refreshToolbarState()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // Install toolbar before the window becomes visible — same timing as Ledger.
        // Doing this in viewDidAppear causes a compositor flash on macOS 26.
        guard !didConfigureToolbar, let window = view.window else { return }
        didConfigureToolbar = true
        configureWindowForToolbar(window)
        installToolbar(resetDelegateState: true)
        refreshToolbarState()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if archiveImportSheetPresenter == nil {
            archiveImportSheetPresenter = ArchiveImportSheetPresenter(
                model: model,
                parentWindowProvider: { [weak self] in self?.view.window },
                onDismiss: { [weak self] in
                    guard let self else { return }
                    self.contentController.refreshDisplayedAssets()
                    self.refreshToolbarState()
                }
            )
        }
        refreshWindowTitle()
        refreshWindowSubtitle()
        Task { @MainActor [weak self] in
            await self?.presentArchiveLibraryBindingPromptIfNeeded()
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        if let m = inspectorKeyMonitor { NSEvent.removeMonitor(m); inspectorKeyMonitor = nil }
        if let m = keyboardParityMonitor { NSEvent.removeMonitor(m); keyboardParityMonitor = nil }
    }

    // MARK: - Toolbar

    private func installToolbar(resetDelegateState: Bool) {
        guard let window = view.window else { return }
        if resetDelegateState {
            toolbarDelegate.resetCachedToolbarReferences()
        }
        let shell = toolbarShellController ?? ToolbarShellController(content: toolbarDelegate)
        shell.setContent(toolbarDelegate)
        toolbarShellController = shell
        _ = shell.installToolbar(
            on: window,
            identifier: "\(AppBrand.identifierPrefix).MainToolbar.v1",
            displayMode: .iconOnly,
            allowsUserCustomization: false,
            autosavesConfiguration: false
        )
    }

    private func refreshToolbarState() {
        toolbarShellController?.syncAndValidate(window: view.window)
    }

    // MARK: - Model observation

    private func observeModelState() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(modelStateChanged),
            name: .librarianIndexingStateChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sidebarIndexingStateChanged),
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(modelStateChanged),
            name: .librarianAnalysisStateChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(contentDataChanged),
            name: .librarianContentDataChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(archiveLibraryBindingChanged),
            name: .librarianArchiveLibraryBindingChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(systemPhotoLibraryChanged),
            name: .librarianSystemPhotoLibraryChanged,
            object: nil
        )
    }

    private func installSubtitleObservers() {
        func observe<Value: Equatable>(_ publisher: Published<Value>.Publisher) {
            publisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.refreshWindowSubtitle()
                }
                .store(in: &subtitleObservers)
        }

        observe(model.$isSendingArchive)
        observe(model.$isImportingArchive)
        observe(model.$importStatusText)
        observe(model.$isIndexing)
        observe(model.$indexingProgress)
        observe(model.$isAnalysing)
        observe(model.$analysisStatusText)
        observe(model.$statusMessage)
        observe(model.$archiveRootAvailability)
        observe(model.$latestArchiveLibraryBindingEvaluation)
    }

    @objc private func modelStateChanged() {
        refreshSidebarItemsWithBadges()
        toolbarDelegate.refresh(model: model)
        refreshWindowSubtitle()
    }

    @objc private func sidebarIndexingStateChanged() {
        refreshSidebarItemsWithBadges()
    }

    @objc private func sidebarSelectionChanged() {
        refreshWindowTitle()
        refreshWindowSubtitle()
        toolbarDelegate.refresh(model: model)
    }

    @objc private func contentDataChanged() {
        refreshSidebarItemsWithBadges()
        refreshWindowSubtitle()
    }

    @objc private func archiveLibraryBindingChanged() {
        Task { @MainActor [weak self] in
            await self?.presentArchiveLibraryBindingPromptIfNeeded()
        }
    }

    @objc private func systemPhotoLibraryChanged() {
        lastBindingPromptSignature = nil
        Task { @MainActor [weak self] in
            await self?.presentArchiveLibraryBindingPromptIfNeeded()
        }
    }

    private func presentArchiveLibraryBindingPromptIfNeeded() async {
        guard !isShowingBindingPrompt else { return }
        let gate = model.evaluateArchiveWriteGate(for: .importIntoArchive)
        guard gate.status != .allowed else {
            lastBindingPromptSignature = nil
            return
        }
        guard let evaluation = gate.evaluation else { return }
        guard evaluation.state == .mismatch || evaluation.state == .unbound else { return }

        let signature = [
            evaluation.state.rawValue,
            evaluation.expectedFingerprint ?? "nil",
            evaluation.currentFingerprint ?? "nil",
            evaluation.archiveID ?? "nil",
            model.currentSystemPhotoLibraryFingerprint ?? "nil"
        ].joined(separator: "|")
        guard lastBindingPromptSignature != signature else { return }
        lastBindingPromptSignature = signature

        isShowingBindingPrompt = true
        _ = await ArchiveLibraryMismatchPrompt.resolveWriteGateIfPossible(
            model: model,
            decision: gate,
            operation: .importIntoArchive,
            parentWindow: view.window
        )
        isShowingBindingPrompt = false
    }

    private func refreshWindowTitle() {
        let itemTitle = model.selectedSidebarItem?.title ?? "Librarian"
        view.window?.title = itemTitle
    }

    private func refreshSidebarItemsWithBadges() {
        guard model.database.assetRepository != nil else { return }
        let selectedKind = model.selectedSidebarItem?.kind ?? .allPhotos
        let updatedItems = Self.buildSidebarItemsWithBadges(model: model)
        guard updatedItems != sidebarController.items else { return }
        sidebarController.items = updatedItems
        sidebarController.reloadData()
        sidebarController.selectItem(where: { $0.kind == selectedKind })
    }

    private static func buildSidebarItemsWithBadges(model: AppModel) -> [SidebarItem] {
        guard let repository = model.database.assetRepository else {
            return SidebarItem.baseItems
        }
        return SidebarItem.baseItems.map { item in
            var updated = item
            let count = (try? repository.countForSidebarKind(item.kind)) ?? 0
            updated.badgeText = compactBadgeText(for: count)
            return updated
        }
    }

    private static func compactBadgeText(for count: Int) -> String? {
        guard count > 0 else { return nil }
        switch count {
        case 0..<1_000:
            return count.formatted()
        case 1_000..<1_000_000:
            return "\(count / 1_000)K"
        default:
            return "\(count / 1_000_000)M"
        }
    }

    private var lastSubtitleText = ""

    private func refreshWindowSubtitle() {
        if let priorityText = windowSubtitlePriorityText() {
            setSubtitle(priorityText)
            return
        }

        guard let kind = model.selectedSidebarItem?.kind else {
            setSubtitle("")
            return
        }
        guard model.database.assetRepository != nil else { return }
        let count = (try? model.database.assetRepository.countForSidebarKind(kind)) ?? 0
        let text: String
        switch kind {
        case .indexing:
            text = ""
        case .setAsideForArchive, .archived, .duplicates, .lowQuality, .receiptsAndDocuments, .screenshots, .whatsapp, .accidental:
            text = count == 1 ? "1 item" : "\(count.formatted()) items"
        case .allPhotos, .recents, .favourites:
            text = count == 1 ? "1 photo" : "\(count.formatted()) photos"
        }
        setSubtitle(text)
    }

    private func windowSubtitlePriorityText() -> String? {
        LibrarianWindowSubtitlePriority.compute(
            isSendingArchive: model.isSendingArchive,
            isImportingArchive: model.isImportingArchive,
            importStatusText: model.importStatusText,
            isIndexing: model.isIndexing,
            indexingStatusText: model.indexingProgress.statusText,
            isAnalysing: model.isAnalysing,
            analysisStatusText: model.analysisStatusText,
            archiveRootAvailability: model.archiveRootAvailability,
            archiveBindingState: model.latestArchiveLibraryBindingEvaluation?.state,
            statusMessage: model.statusMessage
        )
    }

    private func setSubtitle(_ text: String) {
        guard text != lastSubtitleText else { return }
        lastSubtitleText = text
        view.window?.subtitle = text
    }

    @objc func openSelectionInPhotos(_ sender: Any?) {
        contentController.openSelectionInPhotos()
    }

    @objc func quickLookSelectionAction(_ sender: Any?) {
        contentController.quickLookSelection()
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
                    model.setStatusMessage("Removed failed photos from Set Aside: \(removed).", autoClearAfterSuccess: true)
                }
                contentController.refreshDisplayedAssets()
            } catch {
                AppLog.shared.error("Failed to put back failed archive items: \(error.localizedDescription)")
                model.setStatusMessage("Couldn’t remove failed photos from Set Aside. \(error.localizedDescription)")
                showArchiveAlert(title: "Put Back Failed Items", message: error.localizedDescription)
            }
        }
        toolbarDelegate.refresh(model: model)
    }

    override func selectAll(_ sender: Any?) {
        guard shouldHandleContentKeyCommands() else {
            super.selectAll(sender)
            return
        }
        contentController.selectAllVisibleAssets()
        toolbarDelegate.refresh(model: model)
    }

    @objc func keepSelectionAction(_ sender: Any?) {
        contentController.keepSelectedAssets()
        toolbarDelegate.refresh(model: model)
    }

    @objc func resetDecisionAction(_ sender: Any?) {
        contentController.resetSelectedAssetsDecision()
        toolbarDelegate.refresh(model: model)
    }

    @objc func revealSelectionInFinderAction(_ sender: Any?) {
        contentController.revealArchiveSelectionInFinder()
    }

    @objc func setArchiveLocationAction(_ sender: Any?) {
        guard let chosen = promptForArchiveRoot() else { return }
        _ = model.updateArchiveRoot(chosen)
    }

    // MARK: - Sidebar context menus

    private func sidebarContextMenu(for item: SidebarItem) -> NSMenu? {
        switch item.kind {
        case .allPhotos, .recents, .favourites, .indexing:
            return nil

        case .screenshots, .duplicates, .lowQuality, .receiptsAndDocuments, .whatsapp, .accidental:
            guard let keepKind = item.keepDecisionKind else { return nil }
            let menu = NSMenu()
            menu.autoenablesItems = false
            let resetItem = NSMenuItem(
                title: "Reset All Decisions…",
                action: #selector(resetAllDecisionsForQueueAction(_:)),
                keyEquivalent: ""
            )
            resetItem.representedObject = keepKind
            resetItem.target = self
            resetItem.isEnabled = true
            resetItem.image = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: nil)
            menu.addItem(resetItem)
            return menu

        case .setAsideForArchive:
            let menu = NSMenu()
            menu.autoenablesItems = false
            let hasCandidates = model.pendingArchiveCandidateCount > 0
            let sendItem = NSMenuItem(
                title: "Send All to Archive…",
                action: #selector(sendToArchiveAction(_:)),
                keyEquivalent: ""
            )
            sendItem.target = self
            sendItem.isEnabled = hasCandidates && !model.isSendingArchive
            sendItem.image = NSImage(systemSymbolName: "archivebox", accessibilityDescription: nil)
            menu.addItem(sendItem)
            let clearItem = NSMenuItem(
                title: "Clear Set Aside…",
                action: #selector(clearSetAsideAction(_:)),
                keyEquivalent: ""
            )
            clearItem.target = self
            clearItem.isEnabled = hasCandidates && !model.isSendingArchive
            clearItem.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
            menu.addItem(clearItem)
            return menu

        case .archived:
            let menu = NSMenu()
            menu.autoenablesItems = false
            let revealItem = NSMenuItem(
                title: "Open Archive Folder in Finder",
                action: #selector(openArchiveFolderInFinderAction(_:)),
                keyEquivalent: ""
            )
            revealItem.target = self
            revealItem.isEnabled = model.archiveRootURL != nil
            revealItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            menu.addItem(revealItem)
            return menu
        }
    }

    @objc private func resetAllDecisionsForQueueAction(_ sender: NSMenuItem) {
        guard let keepKind = sender.representedObject as? String else { return }
        let alert = NSAlert()
        alert.messageText = "Reset All Decisions?"
        alert.informativeText = "All keep decisions for this queue will be cleared. Photos will reappear as unreviewed."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        alert.runSheetOrModal(for: view.window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            do {
                try self.model.database.assetRepository.clearKeepDecisions(for: keepKind)
                self.contentController.refreshDisplayedAssets()
            } catch {
                self.showArchiveAlert(title: "Reset Failed", message: error.localizedDescription)
            }
        }
    }

    @objc private func clearSetAsideAction(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Clear Set Aside?"
        alert.informativeText = "All photos in Set Aside will be returned to their queues."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        alert.runSheetOrModal(for: view.window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            do {
                let identifiers = try self.model.database.assetRepository
                    .fetchArchiveCandidateIdentifiers(statuses: [.pending, .failed])
                guard !identifiers.isEmpty else { return }
                try self.model.unqueueAssetsForArchive(localIdentifiers: identifiers)
                self.contentController.refreshDisplayedAssets()
                self.toolbarDelegate.refresh(model: self.model)
            } catch {
                self.showArchiveAlert(title: "Clear Set Aside Failed", message: error.localizedDescription)
            }
        }
    }

    @objc private func openArchiveFolderInFinderAction(_ sender: Any?) {
        guard let url = model.archiveRootURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc func addPhotosToArchiveAction(_ sender: Any?) {
        archiveImportSheetPresenter?.present(mode: .pathAUserPick)
    }

    func presentArchiveImportSheet(mode: ArchiveImportSheetMode) {
        archiveImportSheetPresenter?.present(mode: mode)
    }

    @objc func sendToArchiveAction(_ sender: Any?) {
        guard model.pendingArchiveCandidateCount > 0 else { return }
        guard let archiveRoot = resolveOrPromptArchiveRoot() else { return }
        presentArchiveExportSheet(initialDestination: archiveRoot, scopedLocalIdentifiers: nil)
    }

    func sendSelectedToArchive(localIdentifiers: [String]) {
        guard !localIdentifiers.isEmpty else { return }
        guard let archiveRoot = resolveOrPromptArchiveRoot() else { return }
        presentArchiveExportSheet(initialDestination: archiveRoot, scopedLocalIdentifiers: localIdentifiers)
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
             .duplicates, .lowQuality, .receiptsAndDocuments, .whatsapp, .accidental:
            return true
        case .indexing:
            return false
        }
    }

    var canSetAsideSelection: Bool {
        guard isGallerySidebarSelection, contentController.hasSelectedAssets else { return false }
        return model.selectedSidebarItem?.kind != .setAsideForArchive
    }

    var canPutBackSelection: Bool {
        contentController.canPutBackFromArchiveQueue && !model.isSendingArchive
    }

    var canPutBackFailedItems: Bool {
        model.selectedSidebarItem?.kind == .setAsideForArchive
            && model.failedArchiveCandidateCount > 0
            && !model.isSendingArchive
    }

    var canKeepSelection: Bool {
        model.selectedSidebarItem?.keepDecisionKind != nil && contentController.hasSelectedAssets
    }

    var canResetDecision: Bool {
        model.selectedSidebarItem?.keepDecisionKind != nil && contentController.hasSelectedAssets
    }

    var canRevealInFinder: Bool {
        model.selectedSidebarItem?.kind == .archived && contentController.hasSelectedArchiveItems
    }

    private func installKeyboardParityMonitorIfNeeded() {
        guard keyboardParityMonitor == nil else { return }
        keyboardParityMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option, .function])

            if event.keyCode == KeyCode.tab,
               (modifiers.isEmpty || modifiers == [.shift]),
               KeyboardShortcutSupport.shouldHandlePaneTabSwitch(
                    in: self.view.window,
                    sidebarView: self.sidebarController.view,
                    contentView: self.contentController.view
               ) {
                self.togglePaneFocusBetweenSidebarAndContent()
                return nil
            }

            guard self.shouldHandleContentKeyCommands() else { return event }

            if event.charactersIgnoringModifiers == "a", modifiers == [.command] {
                self.contentController.selectAllVisibleAssets()
                self.toolbarDelegate.refresh(model: self.model)
                return nil
            }

            return event
        }
    }

    private func shouldHandleContentKeyCommands() -> Bool {
        guard KeyboardShortcutSupport.canHandleWindowShortcuts(in: view.window) else { return false }
        guard !KeyboardShortcutSupport.isEditableTextResponder(view.window?.firstResponder) else { return false }
        return KeyboardShortcutSupport.isResponder(view.window?.firstResponder, inside: contentController.view)
    }

    private func togglePaneFocusBetweenSidebarAndContent() {
        KeyboardShortcutSupport.togglePaneFocus(
            in: view.window,
            sidebarView: sidebarController.view,
            contentView: contentController.view,
            focusSidebar: { [weak self] in
                self?.sidebarController.focusSidebar()
            },
            focusContent: { [weak self] in
                self?.contentController.focusContentPane()
            }
        )
    }

    private func resolveOrPromptArchiveRoot() -> URL? {
        let availability = model.refreshArchiveRootAvailability()
        if availability == .available, let existing = model.archiveRootURL {
            return existing
        }
        if availability != .notConfigured {
            showArchiveAlert(
                title: "Archive Unavailable",
                message: "\(availability.userVisibleDescription) Choose a new archive destination."
            )
        }
        guard let chosen = promptForArchiveRoot() else { return nil }
        let currentArchiveID = UserDefaults.standard.string(forKey: ArchiveSettings.archiveIDKey)
        let selectedArchiveID = ArchiveSettings.archiveID(for: chosen)

        if let selectedArchiveID,
           let currentArchiveID,
           selectedArchiveID != currentArchiveID,
           !ArchiveRootPrompts.confirmArchiveSwitch(fromArchiveID: currentArchiveID, toArchiveID: selectedArchiveID) {
            return nil
        }

        if selectedArchiveID == nil,
           !ArchiveRootPrompts.confirmInitializeArchive(at: chosen) {
            return nil
        }

        guard model.updateArchiveRoot(chosen) else { return nil }
        return chosen
    }

    private func promptForArchiveRoot() -> URL? {
        let panel = NSOpenPanel()
        panel.prompt = "Choose Folder"
        panel.message = "Choose where Librarian should export archived photos."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        let result = panel.runModal()
        guard result == .OK else { return nil }
        guard let selected = panel.url?.standardizedFileURL else { return nil }
        return ArchiveSettings.resolveArchiveRoot(fromUserSelection: selected) ?? selected
    }

    private func showArchiveAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runSheetOrModal(for: view.window) { _ in }
    }

    private func presentArchiveExportSheet(initialDestination: URL, scopedLocalIdentifiers: [String]?) {
        guard archiveExportSheetWindow == nil else { return }
        guard let parent = view.window else { return }

        let sheetView = ArchiveExportSheetView(
            model: model,
            initialDestinationURL: initialDestination,
            scopedLocalIdentifiers: scopedLocalIdentifiers
        ) { [weak self] in
            self?.dismissArchiveExportSheet()
        }
        let hostingController = NSHostingController(rootView: sheetView)
        let sheetWindow = NSWindow(contentViewController: hostingController)
        sheetWindow.styleMask = [.titled, .closable]
        sheetWindow.titleVisibility = .hidden
        sheetWindow.titlebarAppearsTransparent = true
        sheetWindow.standardWindowButton(.miniaturizeButton)?.isHidden = true
        sheetWindow.standardWindowButton(.zoomButton)?.isHidden = true
        sheetWindow.isReleasedWhenClosed = false

        archiveExportSheetWindow = sheetWindow
        parent.beginSheet(sheetWindow)
    }

    private func dismissArchiveExportSheet() {
        guard let parent = view.window, let sheet = archiveExportSheetWindow else { return }
        parent.endSheet(sheet)
        archiveExportSheetWindow = nil
        contentController.refreshDisplayedAssets()
        toolbarDelegate.refresh(model: model)
    }
}

enum LibrarianWindowSubtitlePriority {
    static func compute(
        isSendingArchive: Bool,
        isImportingArchive: Bool,
        importStatusText: String,
        isIndexing: Bool,
        indexingStatusText: String,
        isAnalysing: Bool,
        analysisStatusText: String,
        archiveRootAvailability: ArchiveSettings.ArchiveRootAvailability,
        archiveBindingState: ArchiveLibraryBindingState?,
        statusMessage: String
    ) -> String? {
        _ = isSendingArchive

        if isImportingArchive {
            let message = importStatusText.trimmingCharacters(in: .whitespacesAndNewlines)
            return message.isEmpty ? "Importing into Archive…" : message
        }

        if isIndexing {
            return indexingStatusText
        }

        if isAnalysing {
            let message = analysisStatusText.trimmingCharacters(in: .whitespacesAndNewlines)
            return message.isEmpty ? "Analysing Library…" : message
        }

        if archiveRootAvailability == .unavailable
            || archiveRootAvailability == .readOnly
            || archiveRootAvailability == .permissionDenied {
            return archiveRootAvailability.userVisibleDescription
        }

        if let archiveBindingState {
            switch archiveBindingState {
            case .mismatch:
                return "Archive linked to a different photo library."
            case .unbound:
                return "Archive is not linked to a photo library."
            case .unknown:
                return "Couldn’t verify active photo library."
            case .match:
                break
            }
        }

        let status = statusMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if !status.isEmpty, status != "Ready" {
            return status
        }

        return nil
    }
}

extension MainSplitViewController {
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(addPhotosToArchiveAction(_:)) {
            return !model.isImportingArchive && model.archiveRootURL != nil
        }
        if item.action == #selector(putBackSelectionAction(_:)) {
            return canPutBackSelection || canPutBackFailedItems
        }
        if item.action == #selector(selectAll(_:)) {
            return isGallerySidebarSelection
        }
        if item.action == #selector(keepSelectionAction(_:)) {
            return canKeepSelection
        }
        if item.action == #selector(setAsideSelectionAction(_:)) {
            return canSetAsideSelection
        }
        if item.action == #selector(resetDecisionAction(_:)) {
            return canResetDecision
        }
        if item.action == #selector(revealSelectionInFinderAction(_:)) {
            return canRevealInFinder
        }
        if item.action == #selector(sendToArchiveAction(_:)) {
            return model.pendingArchiveCandidateCount > 0 && !model.isSendingArchive
        }
        if item.action == #selector(openSelectionInPhotos(_:)) {
            return isGallerySidebarSelection && contentController.hasSelectedAssets
        }
        if item.action == #selector(quickLookSelectionAction(_:)) {
            return isGallerySidebarSelection && contentController.hasSelectedAssets
        }
        if item.action == #selector(zoomInAction(_:)) || item.action == #selector(zoomOutAction(_:)) {
            return isGallerySidebarSelection
        }
        return super.validateUserInterfaceItem(item)
    }
}
