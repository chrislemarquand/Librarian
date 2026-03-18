import Foundation
import Photos

struct PhotosLibraryDelta {
    let upsertedAssets: [IndexedAsset]
    let deletedLocalIdentifiers: [String]
}

enum PhotosLibraryChangeEvent {
    case delta(PhotosLibraryDelta)
    case unknown
}

/// Registers for PHPhotoLibrary change notifications and triggers incremental sync.
final class PhotosChangeTracker: NSObject, PHPhotoLibraryChangeObserver {

    private let onChangesDetected: (PhotosLibraryChangeEvent) -> Void
    private var trackedFetchResult: PHFetchResult<PHAsset>?

    init(onChangesDetected: @escaping (PhotosLibraryChangeEvent) -> Void) {
        self.onChangesDetected = onChangesDetected
        super.init()
    }

    func register() {
        trackedFetchResult = PHAsset.fetchAssets(with: Self.fetchOptions())
        PHPhotoLibrary.shared().register(self)
    }

    func unregister() {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
        trackedFetchResult = nil
    }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    // MARK: - PHPhotoLibraryChangeObserver

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        guard let currentResult = trackedFetchResult else {
            DispatchQueue.main.async { [weak self] in
                self?.onChangesDetected(.unknown)
            }
            return
        }
        guard let details = changeInstance.changeDetails(for: currentResult) else {
            DispatchQueue.main.async { [weak self] in
                self?.onChangesDetected(.unknown)
            }
            return
        }

        trackedFetchResult = details.fetchResultAfterChanges
        let now = Date()
        var upsertMap: [String: IndexedAsset] = [:]
        for asset in details.insertedObjects {
            upsertMap[asset.localIdentifier] = IndexedAsset(from: asset, lastSeenAt: now)
        }
        for asset in details.changedObjects {
            upsertMap[asset.localIdentifier] = IndexedAsset(from: asset, lastSeenAt: now)
        }
        let deletedIdentifiers = details.removedObjects.map { $0.localIdentifier }
        let delta = PhotosLibraryDelta(
            upsertedAssets: Array(upsertMap.values),
            deletedLocalIdentifiers: deletedIdentifiers
        )

        DispatchQueue.main.async { [weak self] in
            self?.onChangesDetected(.delta(delta))
        }
    }

    private static func fetchOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.includeHiddenAssets = true
        options.includeAllBurstAssets = false
        return options
    }
}
