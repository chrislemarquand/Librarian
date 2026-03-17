import Cocoa
import Photos
import os.log

/// Wraps PhotoKit authorization and library access.
/// All mutations to Photos in v1 are deletion-only and live behind a separate controller (Phase 4).
final class PhotosLibraryService {
    private let logger = Logger(subsystem: "com.librarian.app", category: "photos")
    private let imageManager = PHCachingImageManager()

    // MARK: - Authorization

    var currentAuthorizationStatus: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    func requestAuthorization() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    // MARK: - Asset fetches

    /// Returns all non-deleted assets ordered by creation date descending.
    func fetchAllAssets() -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.includeHiddenAssets = true
        options.includeAllBurstAssets = false // Burst representative only at index time
        return PHAsset.fetchAssets(with: options)
    }

    /// Fetches a single asset by localIdentifier.
    func fetchAsset(localIdentifier: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject
    }

    // MARK: - Thumbnail

    func requestThumbnail(
        for asset: PHAsset,
        targetSize: CGSize,
        deliveryMode: PHImageRequestOptionsDeliveryMode = .opportunistic,
        completion: @escaping (NSImage?) -> Void
    ) -> PHImageRequestID {
        let options = makeThumbnailOptions(deliveryMode: deliveryMode)
        return imageManager.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        ) { image, _ in
            completion(image)
        }
    }

    func startCachingThumbnails(for assets: [PHAsset], targetSize: CGSize) {
        guard !assets.isEmpty else { return }
        imageManager.startCachingImages(
            for: assets,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: makeThumbnailOptions(deliveryMode: .opportunistic)
        )
    }

    func stopCachingThumbnails(for assets: [PHAsset], targetSize: CGSize) {
        guard !assets.isEmpty else { return }
        imageManager.stopCachingImages(
            for: assets,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: makeThumbnailOptions(deliveryMode: .opportunistic)
        )
    }

    func stopAllThumbnailCaching() {
        imageManager.stopCachingImagesForAllAssets()
    }

    // MARK: - Open in Photos

    func openInPhotos(localIdentifier: String) {
        let shortIdentifier = localIdentifier.split(separator: "/").first.map(String.init) ?? localIdentifier
        let escapedIdentifier = localIdentifier
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let escapedShortIdentifier = shortIdentifier
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        tell application "Photos"
            activate
            try
                spotlight (first media item whose id is "\(escapedIdentifier)")
            on error
                spotlight (first media item whose id is "\(escapedShortIdentifier)")
            end try
        end tell
        """

        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error {
            logger.error("Failed to reveal asset in Photos: \(String(describing: error), privacy: .public)")
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Photos.app"), configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        }
    }

    private func makeThumbnailOptions(deliveryMode: PHImageRequestOptionsDeliveryMode) -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.deliveryMode = deliveryMode
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        options.isSynchronous = false
        return options
    }
}
