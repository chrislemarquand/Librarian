import Cocoa
import SharedUI

@MainActor
final class MainSplitViewController: ThreePaneSplitViewController {

    let model: AppModel
    let toolbarDelegate: ToolbarDelegate

    private let sidebarController: AppKitSidebarController<SidebarSection, SidebarItem>
    private let contentController: ContentController
    private let inspectorController: InspectorController

    private var keyEventMonitor: Any?

    init(model: AppModel) {
        self.model = model

        let sc = AppKitSidebarController(
            sections: SidebarSection.allCases,
            items: SidebarItem.allItems
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
        installKeyEventMonitor()
        toolbarDelegate.refresh(model: model)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        refreshWindowTitle()
        refreshWindowSubtitle()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        removeKeyEventMonitor()
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
    }

    @objc private func modelStateChanged() {
        toolbarDelegate.refresh(model: model)
        refreshWindowSubtitle()
    }

    @objc private func sidebarIndexingStateChanged() {
        let selectedKind = model.selectedSidebarItem?.kind ?? .allPhotos
        sidebarController.reloadData()
        sidebarController.selectItem(where: { $0.kind == selectedKind })
    }

    @objc private func sidebarSelectionChanged() {
        refreshWindowTitle()
        refreshWindowSubtitle()
        toolbarDelegate.refresh(model: model)
    }

    // MARK: - Keyboard

    private func installKeyEventMonitor() {
        removeKeyEventMonitor()
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event) ?? event
        }
    }

    private func removeKeyEventMonitor() {
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
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
        let count = (try? model.database.assetRepository.countForSidebarKind(kind)) ?? 0
        let text: String
        switch kind {
        case .log, .indexing:
            text = ""
        case .setAsideForArchive, .archived, .duplicates, .lowQuality, .receiptsAndDocuments, .screenshots:
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
        alert.runSheetOrModal(for: view.window) { _ in }
    }
}
