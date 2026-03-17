import Foundation
import Photos

/// Registers for PHPhotoLibrary change notifications and triggers incremental sync.
final class PhotosChangeTracker: NSObject, PHPhotoLibraryChangeObserver {

    private let onChangesDetected: () -> Void

    init(onChangesDetected: @escaping () -> Void) {
        self.onChangesDetected = onChangesDetected
        super.init()
    }

    func register() {
        PHPhotoLibrary.shared().register(self)
    }

    func unregister() {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    // MARK: - PHPhotoLibraryChangeObserver

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        // Coalesce notifications — signal once, let the indexer decide what changed
        DispatchQueue.main.async { [weak self] in
            self?.onChangesDetected()
        }
    }
}
