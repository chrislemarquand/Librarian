import AppKit
import SharedUI

final class ArchivedThumbnailService: @unchecked Sendable {
    private let queue = DispatchQueue(label: "\(AppBrand.identifierPrefix).archived-thumbnails", qos: .utility)
    private let cache = NSCache<NSString, NSImage>()
    private let fileManager = FileManager.default

    func requestThumbnail(for item: ArchivedItem, targetSize: CGSize, completion: @escaping @Sendable (NSImage?) -> Void) {
        let cacheKey = "\(item.relativePath)#\(Int(max(targetSize.width, targetSize.height)))"
        if let cached = cache.object(forKey: cacheKey as NSString) {
            completion(cached)
            return
        }

        queue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            let image = self.loadOrGenerateThumbnail(for: item, maxPixelSize: Int(max(targetSize.width, targetSize.height)))
            if let image {
                self.cache.setObject(image, forKey: cacheKey as NSString)
            }
            DispatchQueue.main.async {
                completion(image)
            }
        }
    }

    private func loadOrGenerateThumbnail(for item: ArchivedItem, maxPixelSize: Int) -> NSImage? {
        guard let archiveTreeRoot = ArchiveSettings.currentArchiveTreeRootURL() else {
            return nil
        }
        let didAccess = archiveTreeRoot.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                archiveTreeRoot.stopAccessingSecurityScopedResource()
            }
        }

        let sourceURL = URL(fileURLWithPath: item.absolutePath)
        let thumbnailURL = archiveTreeRoot.appendingPathComponent(item.thumbnailRelativePath, isDirectory: false)

        // Return disk-cached thumbnail if available and not stale.
        if fileManager.fileExists(atPath: thumbnailURL.path),
           !ThumbnailGenerator.isDiskCacheStale(sourceURL: sourceURL, cacheURL: thumbnailURL),
           let cachedImage = NSImage(contentsOf: thumbnailURL) {
            return cachedImage
        }

        // Generate fresh thumbnail via SharedUI.
        guard let image = ThumbnailGenerator.generateOrientedThumbnail(
            fileURL: sourceURL,
            maxPixelSize: CGFloat(max(maxPixelSize, 64))
        ) else {
            return nil
        }

        // Persist to archive-relative disk cache.
        let directoryURL = thumbnailURL.deletingLastPathComponent()
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        if let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) {
            try? jpeg.write(to: thumbnailURL, options: .atomic)
        }

        return image
    }
}
