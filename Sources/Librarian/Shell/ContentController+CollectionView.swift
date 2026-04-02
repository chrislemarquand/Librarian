import Cocoa
import Photos
import SharedUI

// MARK: - NSCollectionViewDataSource

extension ContentController: NSCollectionViewDataSource {
    func numberOfSections(in collectionView: NSCollectionView) -> Int {
        1
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        displayAssets.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        guard let item = collectionView.makeItem(withIdentifier: .assetGridItem, for: indexPath) as? AssetGridItem else {
            return NSCollectionViewItem()
        }

        let asset = displayAssets[indexPath.item]
        let preferredAspectRatio: CGFloat? = {
            guard asset.pixelWidth > 0, asset.pixelHeight > 0 else { return nil }
            return CGFloat(asset.pixelWidth) / CGFloat(asset.pixelHeight)
        }()
        item.prepare(
            localIdentifier: asset.id,
            preferredAspectRatio: preferredAspectRatio,
            tileSide: thumbnailTileSide(),
            showsSharedLibraryBadge: asset.photoAsset?.isCloudShared == true
        )

        switch asset {
        case .photos(let photoAsset):
            guard let phAsset = model.photosService.fetchAsset(localIdentifier: photoAsset.localIdentifier) else {
                item.applyImage(nil, forLocalIdentifier: asset.id)
                return item
            }

            let targetSize = thumbnailTargetSize()
            _ = model.photosService.requestThumbnail(for: phAsset, targetSize: targetSize) { [weak item] image in
                guard let item else { return }
                item.applyImage(image, forLocalIdentifier: asset.id)
            }
        case .archived(let archivedItem):
            let targetSize = thumbnailTargetSize()
            archivedThumbnailService.requestThumbnail(for: archivedItem, targetSize: targetSize) { [weak item] image in
                guard let item else { return }
                Task { @MainActor in
                    item.applyImage(image, forLocalIdentifier: asset.id)
                }
            }
        }

        return item
    }
}

// MARK: - NSCollectionViewDelegate

extension ContentController: NSCollectionViewDelegate {}
extension ContentController: NSCollectionViewPrefetching {
    func collectionView(_ collectionView: NSCollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        let identifiers = indexPaths.compactMap { indexPath -> String? in
            guard indexPath.item >= 0, indexPath.item < displayAssets.count else { return nil }
            return displayAssets[indexPath.item].photoIdentifier
        }
        let assets = Array(model.photosService.fetchAssetsKeyed(localIdentifiers: identifiers).values)
        model.photosService.startCachingThumbnails(for: assets, targetSize: thumbnailTargetSize())
    }

    func collectionView(_ collectionView: NSCollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        let identifiers = indexPaths.compactMap { indexPath -> String? in
            guard indexPath.item >= 0, indexPath.item < displayAssets.count else { return nil }
            return displayAssets[indexPath.item].photoIdentifier
        }
        let assets = Array(model.photosService.fetchAssetsKeyed(localIdentifiers: identifiers).values)
        model.photosService.stopCachingThumbnails(for: assets, targetSize: thumbnailTargetSize())
    }
}

extension ContentController {
    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        syncModelSelectionFromCollection()
        updateQuickLookArtifacts()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        syncModelSelectionFromCollection()
        updateQuickLookArtifacts()
    }

    func syncModelSelectionFromCollection() {
        let count = collectionView.selectionIndexPaths.count
        guard let selectedIndex = collectionView.selectionIndexPaths.first?.item,
              selectedIndex >= 0,
              selectedIndex < displayAssets.count else {
            model.setSelectedAsset(nil, count: 0)
            return
        }
        if let selectedAsset = displayAssets[selectedIndex].photoAsset {
            model.setSelectedAsset(selectedAsset, count: count)
        } else if let selectedArchivedItem = displayAssets[selectedIndex].archivedItem {
            model.setSelectedArchivedItem(selectedArchivedItem, count: count)
        } else {
            model.setSelectedAsset(nil, count: 0)
        }
    }

    func updateQuickLookArtifacts() {
        guard let window = collectionView.window else { return }
        var updatedFrames: [String: NSRect] = [:]
        for indexPath in collectionView.selectionIndexPaths {
            guard indexPath.item >= 0, indexPath.item < displayAssets.count else { continue }
            guard let item = collectionView.item(at: indexPath) as? AssetGridItem else { continue }
            let imageView = item.thumbnailImageView
            let rectInCollection = imageView.convert(imageView.bounds, to: collectionView)
            let rectInWindow = collectionView.convert(rectInCollection, to: nil)
            let rectOnScreen = window.convertToScreen(rectInWindow)
            updatedFrames[displayAssets[indexPath.item].id] = rectOnScreen
        }
        quickLookSourceFrames = updatedFrames
    }

    func moveSelection(_ direction: SharedUI.MoveCommandDirection, extendingSelection: Bool) {
        guard !displayAssets.isEmpty else { return }
        let current = collectionView.selectionIndexPaths.map(\.item).sorted()
        let focus = current.last ?? 0
        let columns = max(model.galleryColumnCount, 1)

        let candidate: Int
        switch direction {
        case .left:
            candidate = focus - 1
        case .right:
            candidate = focus + 1
        case .up:
            candidate = focus - columns
        case .down:
            candidate = focus + columns
        }
        let next = max(0, min(displayAssets.count - 1, candidate))
        guard next != focus || current.isEmpty else { return }

        if extendingSelection {
            let anchor = selectionAnchorIndex ?? focus
            selectionAnchorIndex = anchor
            let range = min(anchor, next)...max(anchor, next)
            let nextSelection = Set(range.map { IndexPath(item: $0, section: 0) })
            collectionView.selectionIndexPaths = nextSelection
        } else {
            selectionAnchorIndex = next
            collectionView.selectionIndexPaths = [IndexPath(item: next, section: 0)]
        }

        collectionView.scrollToItems(at: [IndexPath(item: next, section: 0)], scrollPosition: .nearestVerticalEdge)
        syncModelSelectionFromCollection()
        updateQuickLookArtifacts()
    }

    func handleModifiedItemClick(indexPath: IndexPath, modifiers: NSEvent.ModifierFlags) {
        guard indexPath.item >= 0, indexPath.item < displayAssets.count else { return }

        if modifiers.contains(.shift) {
            let anchor = selectionAnchorIndex ?? (collectionView.selectionIndexPaths.map(\.item).min() ?? indexPath.item)
            let range = min(anchor, indexPath.item)...max(anchor, indexPath.item)
            collectionView.selectionIndexPaths = Set(range.map { IndexPath(item: $0, section: 0) })
        } else if modifiers.contains(.command) {
            var current = collectionView.selectionIndexPaths
            if current.contains(indexPath) {
                current.remove(indexPath)
            } else {
                current.insert(indexPath)
                selectionAnchorIndex = indexPath.item
            }
            collectionView.selectionIndexPaths = current
        }

        syncModelSelectionFromCollection()
        updateQuickLookArtifacts()
    }
}
