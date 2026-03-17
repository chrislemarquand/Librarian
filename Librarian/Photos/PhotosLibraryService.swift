import Cocoa
import Photos

/// Wraps PhotoKit authorization and library access.
/// All mutations to Photos in v1 are deletion-only and live behind a separate controller (Phase 4).
final class PhotosLibraryService {

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
        let options = PHImageRequestOptions()
        options.deliveryMode = deliveryMode
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false // Never trigger iCloud download from grid
        options.isSynchronous = false

        return PHImageManager.default().requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        ) { image, _ in
            completion(image)
        }
    }
}
