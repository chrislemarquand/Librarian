import AppKit

enum ArchiveFolderIcon {

    /// The icon image from the asset catalogue. Nil only if the asset is missing (development error).
    static var image: NSImage? { NSImage(named: "ArchiveFolderIcon") }

    /// Applies the custom archive folder icon to `url`.
    /// `bookmarkURL` is the security-scoped bookmark URL that grants write access to `url`
    /// (typically the archive root, the parent of `url`).
    static func apply(to url: URL, accessedVia bookmarkURL: URL) {
        guard let image else {
            AppLog.shared.error("ArchiveFolderIcon: asset missing — cannot apply icon")
            return
        }
        let didAccess = bookmarkURL.startAccessingSecurityScopedResource()
        defer { if didAccess { bookmarkURL.stopAccessingSecurityScopedResource() } }
        if !NSWorkspace.shared.setIcon(image, forFile: url.path, options: []) {
            AppLog.shared.error("ArchiveFolderIcon: setIcon failed for \(url.path)")
        }
    }

    /// Removes any custom icon from `url`, restoring the default folder appearance.
    /// `bookmarkURL` is the security-scoped bookmark URL that grants write access to `url`.
    /// If the bookmark URL is unreachable (e.g. external drive not mounted), fails silently.
    static func remove(from url: URL, accessedVia bookmarkURL: URL) {
        let didAccess = bookmarkURL.startAccessingSecurityScopedResource()
        defer { if didAccess { bookmarkURL.stopAccessingSecurityScopedResource() } }
        NSWorkspace.shared.setIcon(nil, forFile: url.path, options: [])
    }
}
