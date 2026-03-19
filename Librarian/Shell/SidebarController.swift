import Cocoa

// MARK: - Sidebar data model

enum SidebarSection: String, CaseIterable {
    case library = "Library"
    case queues  = "Queues"
    case archive = "Archive"
    case tasks   = "Tasks"

    var title: String { rawValue }
}

struct SidebarItem: Equatable {
    enum Kind: Equatable {
        case allPhotos
        case recents
        case favourites
        case screenshots
        case setAsideForArchive
        case archived
        case duplicates
        case lowQuality
        case receiptsAndDocuments
        case indexing
        case log
    }

    let section: SidebarSection
    let kind: Kind
    var title: String
    var symbolName: String

    static let allItems: [SidebarItem] = [
        SidebarItem(section: .library, kind: .allPhotos,         title: "All Photos",  symbolName: "photo.on.rectangle.angled"),
        SidebarItem(section: .library, kind: .recents,           title: "Recents",     symbolName: "clock"),
        SidebarItem(section: .library, kind: .favourites,        title: "Favourites",  symbolName: "heart"),
        SidebarItem(section: .queues,  kind: .screenshots,          title: "Screenshots",          symbolName: "camera.viewfinder"),
        SidebarItem(section: .queues,  kind: .duplicates,           title: "Duplicates",           symbolName: "doc.on.doc"),
        SidebarItem(section: .queues,  kind: .lowQuality,           title: "Low Quality",          symbolName: "wand.and.stars.inverse"),
        SidebarItem(section: .queues,  kind: .receiptsAndDocuments, title: "Documents", symbolName: "doc.text"),
        SidebarItem(section: .archive, kind: .setAsideForArchive,   title: "Set Aside",            symbolName: "tray.full"),
        SidebarItem(section: .archive, kind: .archived,             title: "Archived",             symbolName: "archivebox"),
        SidebarItem(section: .tasks,   kind: .log,               title: "Log",         symbolName: "list.bullet.rectangle"),
    ]

    static func items(in section: SidebarSection) -> [SidebarItem] {
        allItems.filter { $0.section == section }
    }
}

extension SidebarItem.Kind {
    var debugName: String {
        switch self {
        case .allPhotos: return "allPhotos"
        case .recents: return "recents"
        case .favourites: return "favourites"
        case .screenshots: return "screenshots"
        case .setAsideForArchive: return "setAsideForArchive"
        case .archived: return "archived"
        case .duplicates: return "duplicates"
        case .lowQuality: return "lowQuality"
        case .receiptsAndDocuments: return "receiptsAndDocuments"
        case .indexing: return "indexing"
        case .log: return "log"
        }
    }
}

// MARK: - SidebarController

final class SidebarController: NSViewController {

    let model: AppModel
    private var outlineView: NSOutlineView!
    private var scrollView: NSScrollView!

    // The outline data is sections at top level, items as children
    private let sections = SidebarSection.allCases

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - View lifecycle

    override func loadView() {
        outlineView = NSOutlineView()
        outlineView.style = .sourceList
        outlineView.headerView = nil
        outlineView.floatsGroupRows = false
        outlineView.allowsEmptySelection = false
        outlineView.allowsMultipleSelection = false
        outlineView.indentationPerLevel = 16
        outlineView.rowSizeStyle = .default
        outlineView.focusRingType = .none

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.isEditable = false
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        outlineView.dataSource = self
        outlineView.delegate = self

        scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .overlay

        view = scrollView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        outlineView.reloadData()

        // Expand all sections
        for section in sections {
            outlineView.expandItem(section)
        }

        // Select All Photos by default
        selectItem(kind: .allPhotos)

        observeModel()
    }

    // MARK: - Selection

    private func selectItem(kind: SidebarItem.Kind) {
        for row in 0..<outlineView.numberOfRows {
            guard let item = outlineView.item(atRow: row) as? SidebarItem,
                  item.kind == kind else { continue }
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            break
        }
    }

    // MARK: - Model observation

    private func observeModel() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(indexingStateChanged),
            name: .librarianIndexingStateChanged,
            object: nil
        )
    }

    @objc private func indexingStateChanged() {
        let selectedKind = model.selectedSidebarItem?.kind ?? .allPhotos
        outlineView.reloadData()
        for section in sections {
            outlineView.expandItem(section)
        }
        selectItem(kind: selectedKind)
    }
}

// MARK: - NSOutlineViewDataSource

extension SidebarController: NSOutlineViewDataSource {

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            return sections.count
        }
        if let section = item as? SidebarSection {
            return SidebarItem.items(in: section).count
        }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return sections[index]
        }
        if let section = item as? SidebarSection {
            return SidebarItem.items(in: section)[index]
        }
        return sections[0]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is SidebarSection
    }
}

// MARK: - NSOutlineViewDelegate

extension SidebarController: NSOutlineViewDelegate {

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let section = item as? SidebarSection {
            return makeSectionHeaderView(title: section.title)
        }
        if let sidebarItem = item as? SidebarItem {
            return makeItemView(sidebarItem)
        }
        return nil
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        item is SidebarSection
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        item is SidebarItem
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        guard item is SidebarItem else { return nil }
        let id = NSUserInterfaceItemIdentifier("SidebarSelectionRowView")
        if let reused = outlineView.makeView(withIdentifier: id, owner: nil) as? SidebarSelectionRowView {
            return reused
        }
        let rowView = SidebarSelectionRowView()
        rowView.identifier = id
        return rowView
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = outlineView.selectedRow
        guard row >= 0, let sidebarItem = outlineView.item(atRow: row) as? SidebarItem else { return }
        model.setSelectedSidebarItem(sidebarItem)
    }

    // MARK: - Cell views

    private func makeSectionHeaderView(title: String) -> NSView {
        let id = NSUserInterfaceItemIdentifier("SidebarSectionCell")
        if let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
            cell.textField?.stringValue = title
            return cell
        }

        let cell = NSTableCellView()
        cell.identifier = id
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        // Align with the left edge of the selection pill (SidebarSelectionRowView draws
        // the pill with dx: 6, so the pill left edge sits at x=6 from the row bounds).
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: SidebarSelectionRowView.pillInsetX),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func makeItemView(_ sidebarItem: SidebarItem) -> NSView {
        let id = NSUserInterfaceItemIdentifier("SidebarItemCell")
        let cell: NSTableCellView
        if let reused = outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = id

            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.imageScaling = .scaleNone

            let title = NSTextField(labelWithString: "")
            title.translatesAutoresizingMaskIntoConstraints = false
            title.lineBreakMode = .byTruncatingTail

            cell.addSubview(icon)
            cell.addSubview(title)
            cell.imageView = icon
            cell.textField = title

            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 22),
                icon.heightAnchor.constraint(equalToConstant: 22),

                title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
                title.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                title.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
            ])
        }

        cell.textField?.stringValue = sidebarItem.title
        cell.imageView?.image = NSImage(systemSymbolName: sidebarItem.symbolName, accessibilityDescription: sidebarItem.title)

        return cell
    }
}

private final class SidebarSelectionRowView: NSTableRowView {

    override var isSelected: Bool {
        didSet { updateSubviewColors() }
    }

    override var isEmphasized: Bool {
        didSet { updateSubviewColors() }
    }

    // Only tell cell views to use white text when the row is selected AND focused.
    // Unfocused-selected → .normal so text stays at labelColor over the grey pill.
    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        isSelected && isEmphasized ? .emphasized : .normal
    }

    // Catch cells added to the row after initial layout (e.g. on first load).
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        updateSubviewColors()
    }

    private func updateSubviewColors() {
        // contentTintColor is reset to nil by AppKit's deferred backgroundStyle
        // propagation, so we use symbolConfiguration instead — a colour set there
        // overrides contentTintColor and cannot be cleared by AppKit.
        let color: NSColor = (isSelected && isEmphasized) ? .white : .labelColor
        let config = NSImage.SymbolConfiguration(textStyle: .body, scale: .small)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        for subview in subviews {
            guard let cell = subview as? NSTableCellView else { continue }
            cell.imageView?.symbolConfiguration = config
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let librarianIndexingStateChanged = Notification.Name("com.librarian.app.indexingStateChanged")
    static let librarianSidebarSelectionChanged = Notification.Name("com.librarian.app.sidebarSelectionChanged")
    static let librarianSelectionChanged = Notification.Name("com.librarian.app.selectionChanged")
    static let librarianLogUpdated = Notification.Name("com.librarian.app.logUpdated")
    static let librarianGalleryZoomChanged = Notification.Name("com.librarian.app.galleryZoomChanged")
    static let librarianArchiveQueueChanged = Notification.Name("com.librarian.app.archiveQueueChanged")
    static let librarianArchiveRootChanged = Notification.Name("com.librarian.app.archiveRootChanged")
    static let librarianAnalysisStateChanged = Notification.Name("com.librarian.app.analysisStateChanged")
}
