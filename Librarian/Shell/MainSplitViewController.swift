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
        toolbarDelegate.configure(splitVC: self)
        toolbarDelegate.refresh(model: model)
        observeModelState()
        installKeyEventMonitor()
        observeInnerSplitResize()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        applyInitialInnerSplitIfNeeded()
        refreshWindowTitle()
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
        sidebarWrap.maximumThickness = 380
        sidebarWrap.canCollapse = true
        sidebarWrap.holdingPriority = .defaultHigh
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
    }

    @objc private func modelStateChanged() {
        toolbarDelegate.refresh(model: model)
    }

    @objc private func sidebarSelectionChanged() {
        refreshWindowTitle()
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

    @objc func openSelectionInPhotos(_ sender: Any?) {
        contentController.openSelectionInPhotos()
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
        case .allPhotos, .recents, .favourites, .screenshots:
            return true
        case .indexing, .log:
            return false
        }
    }
}
