import Cocoa
import SharedUI

// MARK: - Sidebar data model

enum SidebarSection: String, CaseIterable, AppKitSidebarSectionType {
    case library = "Library"
    case queues  = "Boxes"
    case archive = "Archive"

    var title: String { rawValue }
}

struct SidebarItem: Hashable, AppKitSidebarItemType {
    enum Kind: Hashable {
        case allPhotos
        case recents
        case favourites
        case screenshots
        case setAsideForArchive
        case archived
        case duplicates
        case lowQuality
        case receiptsAndDocuments
        case whatsapp
        case indexing
    }

    let section: SidebarSection
    let kind: Kind
    var title: String
    var symbolName: String
    var badgeText: String?
    var sidebarReorderID: String? { kind.orderToken }
    var isSidebarReorderable: Bool { section == .queues }

    static let baseItems: [SidebarItem] = [
        SidebarItem(section: .library, kind: .allPhotos,            title: "All Photos",  symbolName: "photo.on.rectangle.angled", badgeText: nil),
        SidebarItem(section: .library, kind: .recents,              title: "Recents",     symbolName: "clock",                     badgeText: nil),
        SidebarItem(section: .library, kind: .favourites,           title: "Favourites",  symbolName: "heart",                     badgeText: nil),
        SidebarItem(section: .queues,  kind: .receiptsAndDocuments, title: "Documents",   symbolName: "doc.text",             badgeText: nil),
        SidebarItem(section: .queues,  kind: .duplicates,           title: "Duplicates",  symbolName: "photo.on.rectangle",   badgeText: nil),
        SidebarItem(section: .queues,  kind: .lowQuality,           title: "Low Quality", symbolName: "wand.and.stars.inverse", badgeText: nil),
        SidebarItem(section: .queues,  kind: .screenshots,          title: "Screenshots", symbolName: "camera.viewfinder",     badgeText: nil),
        SidebarItem(section: .queues,  kind: .whatsapp,             title: "WhatsApp",    symbolName: "message",               badgeText: nil),
        SidebarItem(section: .archive, kind: .setAsideForArchive,   title: "Set Aside",   symbolName: "tray.full",                 badgeText: nil),
        SidebarItem(section: .archive, kind: .archived,             title: "Archive",     symbolName: "archivebox",                badgeText: nil),
    ]

    private static let queueOrderDefaultsKey = "\(AppBrand.identifierPrefix).Sidebar.QueuesOrder.v1"

    static var allItems: [SidebarItem] { orderedItemsApplyingPersistedQueueOrder(baseItems) }

    static func items(in section: SidebarSection) -> [SidebarItem] {
        allItems.filter { $0.section == section }
    }

    static func persistQueueOrder(from items: [SidebarItem]) {
        let orderedQueueTokens = items
            .filter { $0.section == .queues && $0.isSidebarReorderable }
            .map { $0.kind.orderToken }
        guard !orderedQueueTokens.isEmpty else { return }
        UserDefaults.standard.set(orderedQueueTokens, forKey: queueOrderDefaultsKey)
    }

    private static func orderedItemsApplyingPersistedQueueOrder(_ items: [SidebarItem]) -> [SidebarItem] {
        let savedTokens = UserDefaults.standard.stringArray(forKey: queueOrderDefaultsKey) ?? []
        guard !savedTokens.isEmpty else { return items }

        var queueItemsByToken: [String: SidebarItem] = [:]
        for item in items where item.section == .queues && item.isSidebarReorderable {
            queueItemsByToken[item.kind.orderToken] = item
        }
        guard !queueItemsByToken.isEmpty else { return items }

        let orderedQueues = savedTokens.compactMap { queueItemsByToken.removeValue(forKey: $0) }
        let trailingQueues = items.filter { item in
            item.section == .queues && item.isSidebarReorderable && queueItemsByToken[item.kind.orderToken] != nil
        }
        let finalQueueItems = orderedQueues + trailingQueues

        var queueIterator = finalQueueItems.makeIterator()
        return items.map { item in
            if item.section == .queues, item.isSidebarReorderable {
                return queueIterator.next() ?? item
            }
            return item
        }
    }
}

extension SidebarItem.Kind {
    var orderToken: String {
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
        case .whatsapp: return "whatsapp"
        case .indexing: return "indexing"
        }
    }

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
        case .whatsapp: return "whatsapp"
        case .indexing: return "indexing"
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    private static var prefix: String { AppBrand.identifierPrefix }
    static let librarianIndexingStateChanged = Notification.Name("\(prefix).indexingStateChanged")
    static let librarianSidebarSelectionChanged = Notification.Name("\(prefix).sidebarSelectionChanged")
    static let librarianSelectionChanged = Notification.Name("\(prefix).selectionChanged")
    static let librarianLogUpdated = Notification.Name("\(prefix).logUpdated")
    static let librarianGalleryZoomChanged = Notification.Name("\(prefix).galleryZoomChanged")
    static let librarianArchiveQueueChanged = Notification.Name("\(prefix).archiveQueueChanged")
    static let librarianArchiveRootChanged = Notification.Name("\(prefix).archiveRootChanged")
    static let librarianAnalysisStateChanged = Notification.Name("\(prefix).analysisStateChanged")
    static let librarianContentDataChanged = Notification.Name("\(prefix).contentDataChanged")
    static let librarianInspectorFieldsChanged = Notification.Name("\(prefix).inspectorFieldsChanged")
    static let librarianArchiveNeedsRelink = Notification.Name("\(prefix).archiveNeedsRelink")
    static let librarianSystemPhotoLibraryChanged = Notification.Name("\(prefix).systemPhotoLibraryChanged")
    static let librarianArchiveLibraryBindingChanged = Notification.Name("\(prefix).archiveLibraryBindingChanged")
}
