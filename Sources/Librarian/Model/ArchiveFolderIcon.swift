import AppKit

enum ArchiveFolderIcon {

    /// The icon image from the asset catalogue. Nil only if the asset is missing (development error).
    static var image: NSImage? {
        guard let raw = NSImage(named: "ArchiveFolderIcon") else { return nil }
        return normalizedFileIconImage(from: raw)
    }

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

    /// IconServices rejects some oversized image reps for file icons.
    /// Normalize to a square bitmap no larger than 512x512 before `setIcon`.
    private static func normalizedFileIconImage(from source: NSImage) -> NSImage {
        let maxSide: CGFloat = 512
        let sourceSize = source.size
        let side = max(1, min(max(sourceSize.width, sourceSize.height), maxSide))
        let targetSize = NSSize(width: side, height: side)

        let output = NSImage(size: targetSize)
        output.lockFocus()
        source.draw(
            in: NSRect(origin: .zero, size: targetSize),
            from: NSRect(origin: .zero, size: sourceSize),
            operation: .copy,
            fraction: 1.0
        )
        output.unlockFocus()
        return output
    }
}
