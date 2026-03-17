import Cocoa

// MARK: - Sidebar data model

enum SidebarSection: String, CaseIterable {
    case library = "Library"
    case tasks   = "Tasks"
}

struct SidebarItem: Equatable {
    enum Kind: Equatable {
        case allPhotos
        case recents
        case favourites
        case screenshots
        case indexing
        case log
    }

    let section: SidebarSection
    let kind: Kind
    var title: String
    var symbolName: String
    var badge: String?

    static let allItems: [SidebarItem] = [
        SidebarItem(section: .library, kind: .allPhotos,   title: "All Photos",  symbolName: "photo.on.rectangle.angled"),
        SidebarItem(section: .library, kind: .recents,     title: "Recents",     symbolName: "clock"),
        SidebarItem(section: .library, kind: .favourites,  title: "Favourites",  symbolName: "heart"),
        SidebarItem(section: .library, kind: .screenshots, title: "Screenshots", symbolName: "camera.viewfinder"),
        SidebarItem(section: .tasks,   kind: .log,         title: "Log",         symbolName: "list.bullet.rectangle"),
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
        case .indexing: return "indexing"
        case .log: return "log"
        }
    }
}

// MARK: - Outline row wrappers

private enum OutlineRow {
    case section(SidebarSection)
    case item(SidebarItem)
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
        outlineView.selectionHighlightStyle = .sourceList
        outlineView.headerView = nil
        outlineView.floatsGroupRows = false
        outlineView.allowsEmptySelection = false
        outlineView.allowsMultipleSelection = false
        outlineView.indentationPerLevel = 0
        outlineView.rowHeight = 26
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
            outlineView.expandItem(section.rawValue)
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
            outlineView.expandItem(section.rawValue)
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
        if let sectionKey = item as? String, let section = SidebarSection(rawValue: sectionKey) {
            return SidebarItem.items(in: section).count
        }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return sections[index].rawValue
        }
        if let sectionKey = item as? String, let section = SidebarSection(rawValue: sectionKey) {
            return SidebarItem.items(in: section)[index]
        }
        return ""
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is String // section keys are expandable
    }
}

// MARK: - NSOutlineViewDelegate

extension SidebarController: NSOutlineViewDelegate {

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let sectionKey = item as? String {
            return makeSectionHeaderView(title: sectionKey)
        }
        if let sidebarItem = item as? SidebarItem {
            return makeItemView(sidebarItem)
        }
        return nil
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        item is String
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        item is SidebarItem
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = outlineView.selectedRow
        guard row >= 0, let sidebarItem = outlineView.item(atRow: row) as? SidebarItem else { return }
        model.setSelectedSidebarItem(sidebarItem)
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        item is String ? 22 : 26
    }

    // MARK: - Cell views

    private func makeSectionHeaderView(title: String) -> NSView {
        let id = NSUserInterfaceItemIdentifier("SectionHeader")
        if let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
            cell.textField?.stringValue = title.uppercased()
            return cell
        }
        let cell = NSTableCellView()
        cell.identifier = id
        let label = NSTextField(labelWithString: title.uppercased())
        label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func makeItemView(_ sidebarItem: SidebarItem) -> NSView {
        let id = NSUserInterfaceItemIdentifier("SidebarCell")
        let cell: SidebarCellView
        if let reused = outlineView.makeView(withIdentifier: id, owner: nil) as? SidebarCellView {
            cell = reused
        } else {
            cell = SidebarCellView(identifier: id)
        }
        cell.configure(with: sidebarItem, model: model)
        return cell
    }
}

// MARK: - SidebarCellView

private final class SidebarCellView: NSTableCellView {

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        buildLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func buildLayout() {
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail

        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        badgeLabel.textColor = .secondaryLabelColor
        badgeLabel.alignment = .right
        badgeLabel.isHidden = true

        [icon, label, badgeLabel].forEach { addSubview($0) }
        imageView = icon
        textField = label

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: badgeLabel.leadingAnchor, constant: -4),

            badgeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            badgeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            badgeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 20),
        ])
    }

    func configure(with item: SidebarItem, model: AppModel) {
        label.stringValue = item.title
        icon.image = NSImage(systemSymbolName: item.symbolName, accessibilityDescription: item.title)

        if let badge = item.badge {
            badgeLabel.stringValue = badge
            badgeLabel.isHidden = false
        } else if item.kind == .allPhotos, model.indexedAssetCount > 0 {
            badgeLabel.stringValue = model.indexedAssetCount.formatted()
            badgeLabel.isHidden = false
        } else {
            badgeLabel.isHidden = true
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let librarianIndexingStateChanged = Notification.Name("com.librarian.app.indexingStateChanged")
    static let librarianSidebarSelectionChanged = Notification.Name("com.librarian.app.sidebarSelectionChanged")
    static let librarianSelectionChanged = Notification.Name("com.librarian.app.selectionChanged")
    static let librarianLogUpdated = Notification.Name("com.librarian.app.logUpdated")
}
