import Cocoa
import SharedUI
import SwiftUI

@MainActor
final class MainSplitViewController: ThreePaneSplitViewController {

    let model: AppModel
    let toolbarDelegate: ToolbarDelegate

    private let sidebarController: AppKitSidebarController<SidebarSection, SidebarItem>
    private let contentController: ContentController
    private let inspectorController: InspectorController

    private var inspectorKeyMonitor: Any?
    private var archiveExportSheetWindow: NSWindow?
    private var archiveImportSheetPresenter: ArchiveImportSheetPresenter?
    private var lastBindingPromptSignature: String?
    private var isShowingBindingPrompt = false

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

        onPaneStateChanged = { [weak self] in
            guard let self else { return }
            self.model.isInspectorCollapsed = self.isInspectorCollapsed
            self.toolbarDelegate.refresh(model: self.model)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        toolbarDelegate.configure(splitVC: self)
        observeModelState()
        installContentKeyboardMonitor(contentView: contentController.view) { [weak self] in
            guard let self, self.isGallerySidebarSelection else { return }
            self.quickLookSelectionAction(nil)
        }
        inspectorKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard event.keyCode == 34, modifiers == [.command, .control] else { return event } // ⌘⌃I
            self.toggleInspector(nil)
            return nil
        }
        toolbarDelegate.refresh(model: model)
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
                    self.toolbarDelegate.refresh(model: self.model)
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

    private func presentArchiveLibraryBindingPromptIfNeeded() async {
        guard !isShowingBindingPrompt else { return }
        let gate = model.evaluateArchiveWriteGate(for: .importIntoArchive)
        guard gate.status != .allowed else { return }
        guard let evaluation = gate.evaluation else { return }

        let signature = [
            evaluation.state.rawValue,
            evaluation.expectedFingerprint ?? "nil",
            evaluation.currentFingerprint ?? "nil",
            evaluation.archiveID ?? "nil"
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
        guard let kind = model.selectedSidebarItem?.kind else {
            setSubtitle("")
            return
        }
        guard model.database.assetRepository != nil else { return }
        let count = (try? model.database.assetRepository.countForSidebarKind(kind)) ?? 0
        let text: String
        switch kind {
        case .log, .indexing:
            text = ""
        case .setAsideForArchive, .archived, .duplicates, .lowQuality, .receiptsAndDocuments, .screenshots, .whatsapp, .accidental:
            text = count == 1 ? "1 item" : "\(count.formatted()) items"
        case .allPhotos, .recents, .favourites:
            text = count == 1 ? "1 photo" : "\(count.formatted()) photos"
        }
        setSubtitle(text)
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
        case .indexing, .log:
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

    private func resolveOrPromptArchiveRoot() -> URL? {
        if let existing = ArchiveSettings.restoreArchiveRootURL() {
            let availability = ArchiveSettings.archiveRootAvailability(for: existing)
            if availability == .available {
                return existing
            }
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

extension MainSplitViewController {
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(addPhotosToArchiveAction(_:)) {
            return !model.isImportingArchive && ArchiveSettings.restoreArchiveRootURL() != nil
        }
        return super.validateUserInterfaceItem(item)
    }
}
