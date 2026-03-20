import Cocoa
import SharedUI

// MARK: - Sidebar data model

enum SidebarSection: String, CaseIterable, AppKitSidebarSectionType {
    case library = "Library"
    case queues  = "Boxes"
    case archive = "Archive"
    case tasks   = "Tasks"

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
        case indexing
        case log
    }

    let section: SidebarSection
    let kind: Kind
    var title: String
    var symbolName: String
    var badgeText: String?

    static let baseItems: [SidebarItem] = [
        SidebarItem(section: .library, kind: .allPhotos,             title: "All Photos",  symbolName: "photo.on.rectangle.angled", badgeText: nil),
        SidebarItem(section: .library, kind: .recents,               title: "Recents",     symbolName: "clock", badgeText: nil),
        SidebarItem(section: .library, kind: .favourites,            title: "Favourites",  symbolName: "heart", badgeText: nil),
        SidebarItem(section: .queues,  kind: .screenshots,           title: "Screenshots", symbolName: "camera.viewfinder", badgeText: nil),
        SidebarItem(section: .queues,  kind: .duplicates,            title: "Duplicates",  symbolName: "doc.on.doc", badgeText: nil),
        SidebarItem(section: .queues,  kind: .lowQuality,            title: "Low Quality", symbolName: "wand.and.stars.inverse", badgeText: nil),
        SidebarItem(section: .queues,  kind: .receiptsAndDocuments,  title: "Documents",   symbolName: "doc.text", badgeText: nil),
        SidebarItem(section: .archive, kind: .setAsideForArchive,    title: "Set Aside",   symbolName: "tray.full", badgeText: nil),
        SidebarItem(section: .archive, kind: .archived,              title: "Archive",     symbolName: "archivebox", badgeText: nil),
        SidebarItem(section: .tasks,   kind: .log,                   title: "Log",         symbolName: "list.bullet.rectangle", badgeText: nil),
    ]

    static var allItems: [SidebarItem] { baseItems }

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
}
