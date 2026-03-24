import AppKit
import ImageIO
import UniformTypeIdentifiers

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

        if fileManager.fileExists(atPath: thumbnailURL.path), let cachedImage = NSImage(contentsOf: thumbnailURL) {
            return cachedImage
        }

        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maxPixelSize, 64)
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let directoryURL = thumbnailURL.deletingLastPathComponent()
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        if let destination = CGImageDestinationCreateWithURL(thumbnailURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
            _ = CGImageDestinationFinalize(destination)
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
