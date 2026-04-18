import Cocoa
import MapKit
import OSLog
import Photos
import SwiftUI
import Combine
import UniformTypeIdentifiers
import SharedUI
import ImageIO

final class InspectorController: NSViewController {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Librarian", category: "inspector-trace")
    private var pendingEmptySelectionWorkItem: DispatchWorkItem?

    let model: AppModel
    private let viewModel: InspectorReadOnlyViewModel
    private var hostingController: NSHostingController<AnyView>?

    init(model: AppModel) {
        self.model = model
        self.viewModel = InspectorReadOnlyViewModel(model: model)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        let rootView = AnyView(
            InspectorRootView(model: model, viewModel: viewModel)
                .tint(AppTheme.accentColor)
        )
        let host = NSHostingController(rootView: rootView)
        host.sizingOptions = []
        addChild(host)
        let hostedView = host.view
        hostedView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hostedView)

        NSLayoutConstraint.activate([
            hostedView.topAnchor.constraint(equalTo: container.topAnchor),
            hostedView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostedView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hostedView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        hostingController = host

        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observeModel()
        refreshForSelection()
    }

    // MARK: - State

    func showEmpty() {
        viewModel.showEmpty()
    }

    func showMultiple(count: Int) {
        viewModel.showMultiple(count: count)
    }

    func showAsset(_ asset: IndexedAsset) {
        viewModel.showAsset(asset)
    }

    // MARK: - Model observation

    private func observeModel() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(selectionChanged),
            name: .librarianSelectionChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(selectionChanged),
            name: .librarianArchiveQueueChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(selectionChanged),
            name: .librarianInspectorFieldsChanged,
            object: nil
        )
    }

    @objc private func selectionChanged() {
        logger.debug("selectionChanged selectedAssetCount=\(self.model.selectedAssetCount, privacy: .public) selectedAsset=\(Self.shortAssetID(self.model.selectedAsset?.localIdentifier), privacy: .public) selectedArchived=\(Self.shortArchivedID(self.model.selectedArchivedItem?.relativePath), privacy: .public)")
        refreshForSelection()
    }

    private func refreshForSelection() {
        if model.selectedAssetCount > 1 {
            cancelPendingEmptySelection()
            logger.debug("refreshForSelection -> multiple count=\(self.model.selectedAssetCount, privacy: .public)")
            showMultiple(count: model.selectedAssetCount)
        } else if let asset = model.selectedAsset {
            cancelPendingEmptySelection()
            logger.debug("refreshForSelection -> asset \(Self.shortAssetID(asset.localIdentifier), privacy: .public)")
            showAsset(asset)
        } else if let archivedItem = model.selectedArchivedItem {
            cancelPendingEmptySelection()
            logger.debug("refreshForSelection -> archived \(Self.shortArchivedID(archivedItem.relativePath), privacy: .public)")
            viewModel.showArchivedItem(archivedItem)
        } else {
            scheduleEmptySelectionRefresh()
        }
    }

    private func scheduleEmptySelectionRefresh() {
        pendingEmptySelectionWorkItem?.cancel()
        logger.debug("refreshForSelection -> empty scheduled")

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingEmptySelectionWorkItem = nil
            guard self.model.selectedAssetCount == 0,
                  self.model.selectedAsset == nil,
                  self.model.selectedArchivedItem == nil
            else {
                self.logger.debug("refreshForSelection -> empty cancelled by newer selection")
                return
            }
            self.logger.debug("refreshForSelection -> empty committed")
            self.showEmpty()
        }

        pendingEmptySelectionWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    private func cancelPendingEmptySelection() {
        pendingEmptySelectionWorkItem?.cancel()
        pendingEmptySelectionWorkItem = nil
    }

    private static func shortAssetID(_ localIdentifier: String?) -> String {
        guard let localIdentifier else { return "nil" }
        return localIdentifier.split(separator: "/").first.map(String.init) ?? localIdentifier
    }

    private static func shortArchivedID(_ relativePath: String?) -> String {
        guard let relativePath else { return "nil" }
        return URL(fileURLWithPath: relativePath).lastPathComponent
    }
}

private struct InspectorRootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var viewModel: InspectorReadOnlyViewModel

    var body: some View {
        InspectorReadOnlyView(viewModel: viewModel)
            .sheet(item: $model.activeWelcomePresentation) { presentation in
                AppWelcomeSheetView(presentation: presentation)
            }
    }
}

@MainActor
private final class InspectorReadOnlyViewModel: ObservableObject {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Librarian", category: "inspector-trace")

    @Published private(set) var displayState = InspectorDisplayState.empty
    private(set) var selectedAsset: IndexedAsset?
    private(set) var selectedArchivedItem: ArchivedItem?
    private(set) var archiveCandidateInfo: ArchiveCandidateInfo?
    private(set) var previewImage: NSImage?
    private(set) var isPreviewLoading = false
    @Published private(set) var collapsedSections: Set<String>
    private(set) var originalFilename: String = ""
    private(set) var fileFormat: String = ""
    private(set) var fileSizeBytes: Int? = nil
    // Location
    private(set) var latitude: Double? = nil
    private(set) var longitude: Double? = nil
    private(set) var altitude: Double? = nil
    // Library
    private(set) var isBurst = false
    private(set) var isEdited = false
    private(set) var hasLivePhotoVideo = false
    private(set) var albums: [String] = []
    // Camera & Capture (EXIF, async)
    private(set) var exifMake: String = ""
    private(set) var exifModel: String = ""
    private(set) var exifLensModel: String = ""
    private(set) var exifAperture: String = ""
    private(set) var exifShutterSpeed: String = ""
    private(set) var exifISO: String = ""
    private(set) var exifFocalLength: String = ""
    private(set) var exifExposureProgram: String = ""
    private(set) var exifFlash: String = ""
    private(set) var exifMeteringMode: String = ""
    private(set) var exifExposureCompensation: String = ""
    // Analysis
    private(set) var photoTitle: String = ""
    private(set) var photoDescription: String = ""
    private(set) var photoKeywords: String = ""
    private(set) var dateAdded: Date? = nil
    private(set) var place: String = ""
    private(set) var overallScore: Double? = nil
    private(set) var aiCaption: String = ""
    private(set) var labels: String = ""
    private(set) var namedPersonCount: Int? = nil
    private(set) var detectedPersonCount: Int? = nil
    private(set) var extractedText: String = ""

    private let model: AppModel
    private var representedPreviewIdentifier: String?
    private var metadataRequestGeneration = 0
    private var pendingAssetSelection: IndexedAsset?
    private var pendingArchivedSelection: ArchivedItem?
    private var pendingCommitTimeoutItem: DispatchWorkItem?
    private var assetSnapshotCache: [String: AssetMetadataSnapshot] = [:]
    private var metadataCache: [String: ParsedMetadata] = [:]
    private var previewImageCache: [String: NSImage] = [:]
    private var displayStateCache: [String: InspectorDisplayState] = [:]

    // v2 key so old section-name collapse state doesn't carry over.
    private static let collapsedSectionsKey = "ui.librarian.inspector.collapsed.sections.v2"
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    init(model: AppModel) {
        self.model = model
        if let stored = UserDefaults.standard.stringArray(forKey: Self.collapsedSectionsKey) {
            self.collapsedSections = Set(stored)
        } else {
            // Camera, Capture, and Analysis are collapsed by default on first launch.
            self.collapsedSections = ["Camera", "Capture", "Analysis"]
        }
    }

    private enum DisplayStateUpdate<T> {
        case keep
        case set(T)
    }

    private func updateDisplayState(
        selectedAsset: DisplayStateUpdate<IndexedAsset?> = .keep,
        selectedArchivedItem: DisplayStateUpdate<ArchivedItem?> = .keep,
        multipleSelectionCount: DisplayStateUpdate<Int> = .keep,
        previewImage: DisplayStateUpdate<NSImage?> = .keep,
        isPreviewLoading: DisplayStateUpdate<Bool> = .keep,
        metadata: DisplayStateUpdate<InspectorMetadataState> = .keep,
        source: String = #function
    ) {
        let nextState = InspectorDisplayState(
            selectedAsset: resolvedUpdate(selectedAsset, current: displayState.selectedAsset),
            selectedArchivedItem: resolvedUpdate(selectedArchivedItem, current: displayState.selectedArchivedItem),
            multipleSelectionCount: resolvedUpdate(multipleSelectionCount, current: displayState.multipleSelectionCount),
            previewImage: resolvedUpdate(previewImage, current: displayState.previewImage),
            isPreviewLoading: resolvedUpdate(isPreviewLoading, current: displayState.isPreviewLoading),
            metadata: resolvedUpdate(metadata, current: displayState.metadata)
        )
        applyDisplayState(nextState, source: source)
    }

    private func resolvedUpdate<T>(_ update: DisplayStateUpdate<T>, current: T) -> T {
        switch update {
        case .keep:
            return current
        case .set(let value):
            return value
        }
    }

    private func applyDisplayState(_ state: InspectorDisplayState, source: String) {
        let previousState = displayState
        guard !displayStatesEqual(previousState, state) else {
            trace("displayState skipped source=\(source) summary=\(displayStateSummary(state))")
            return
        }
        displayState = state
        trace("displayState applied source=\(source) from=\(displayStateSummary(previousState)) to=\(displayStateSummary(state))")
        if let identifier = representedPreviewIdentifier {
            displayStateCache[identifier] = state
            trace("displayState cached identifier=\(shortIdentifier(identifier))")
        }
    }

    private func displayStatesEqual(_ lhs: InspectorDisplayState, _ rhs: InspectorDisplayState) -> Bool {
        lhs.selectedAsset?.localIdentifier == rhs.selectedAsset?.localIdentifier &&
        lhs.selectedArchivedItem?.relativePath == rhs.selectedArchivedItem?.relativePath &&
        lhs.multipleSelectionCount == rhs.multipleSelectionCount &&
        lhs.previewImage === rhs.previewImage &&
        lhs.isPreviewLoading == rhs.isPreviewLoading &&
        metadataStatesEqual(lhs.metadata, rhs.metadata)
    }

    private func metadataStatesEqual(_ lhs: InspectorMetadataState, _ rhs: InspectorMetadataState) -> Bool {
        lhs.originalFilename == rhs.originalFilename &&
        lhs.fileFormat == rhs.fileFormat &&
        lhs.fileSizeBytes == rhs.fileSizeBytes &&
        lhs.latitude == rhs.latitude &&
        lhs.longitude == rhs.longitude &&
        lhs.altitude == rhs.altitude &&
        lhs.isBurst == rhs.isBurst &&
        lhs.isEdited == rhs.isEdited &&
        lhs.hasLivePhotoVideo == rhs.hasLivePhotoVideo &&
        lhs.albums == rhs.albums &&
        lhs.exifMake == rhs.exifMake &&
        lhs.exifModel == rhs.exifModel &&
        lhs.exifLensModel == rhs.exifLensModel &&
        lhs.exifAperture == rhs.exifAperture &&
        lhs.exifShutterSpeed == rhs.exifShutterSpeed &&
        lhs.exifISO == rhs.exifISO &&
        lhs.exifFocalLength == rhs.exifFocalLength &&
        lhs.exifExposureProgram == rhs.exifExposureProgram &&
        lhs.exifFlash == rhs.exifFlash &&
        lhs.exifMeteringMode == rhs.exifMeteringMode &&
        lhs.exifExposureCompensation == rhs.exifExposureCompensation &&
        lhs.photoTitle == rhs.photoTitle &&
        lhs.photoDescription == rhs.photoDescription &&
        lhs.photoKeywords == rhs.photoKeywords &&
        lhs.dateAdded == rhs.dateAdded &&
        lhs.place == rhs.place &&
        lhs.overallScore == rhs.overallScore &&
        lhs.aiCaption == rhs.aiCaption &&
        lhs.labels == rhs.labels &&
        lhs.namedPersonCount == rhs.namedPersonCount &&
        lhs.detectedPersonCount == rhs.detectedPersonCount &&
        lhs.extractedText == rhs.extractedText &&
        archiveCandidateInfoEqual(lhs.archiveCandidateInfo, rhs.archiveCandidateInfo)
    }

    private func archiveCandidateInfoEqual(_ lhs: ArchiveCandidateInfo?, _ rhs: ArchiveCandidateInfo?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return lhs.status == rhs.status &&
            lhs.lastError == rhs.lastError &&
            lhs.queuedAt == rhs.queuedAt &&
            lhs.exportedAt == rhs.exportedAt &&
            lhs.deletedAt == rhs.deletedAt &&
            lhs.archivePath == rhs.archivePath
        default:
            return false
        }
    }

    private func hydrateFromDisplayState(_ state: InspectorDisplayState) {
        selectedAsset = state.selectedAsset
        selectedArchivedItem = state.selectedArchivedItem
        multipleSelectionCount = state.multipleSelectionCount
        previewImage = state.previewImage
        isPreviewLoading = state.isPreviewLoading
        applyMetadataState(state.metadata)
    }

    private func cancelPending() {
        pendingCommitTimeoutItem?.cancel()
        pendingCommitTimeoutItem = nil
        pendingAssetSelection = nil
        pendingArchivedSelection = nil
    }

    private func schedulePendingCommitTimeout() {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingCommitTimeoutItem = nil
            if self.pendingAssetSelection != nil {
                self.trace("commitPending timeout asset")
                self.commitPendingAsset(source: "timeout")
            } else if self.pendingArchivedSelection != nil {
                self.trace("commitPending timeout archived")
                self.commitPendingArchivedItem(source: "timeout")
            }
        }
        pendingCommitTimeoutItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: workItem)
    }

    private func commitPendingAsset(source: String) {
        guard let asset = pendingAssetSelection else { return }
        pendingAssetSelection = nil
        pendingArchivedSelection = nil
        pendingCommitTimeoutItem?.cancel()
        pendingCommitTimeoutItem = nil
        selectedAsset = asset
        selectedArchivedItem = nil
        multipleSelectionCount = 0
        trace("commitPendingAsset asset=\(shortIdentifier(asset.localIdentifier)) source=\(source)")
        updateDisplayState(
            selectedAsset: .set(asset),
            selectedArchivedItem: .set(nil),
            multipleSelectionCount: .set(0),
            previewImage: .set(previewImage),
            isPreviewLoading: .set(isPreviewLoading),
            metadata: .set(currentMetadataState),
            source: source
        )
    }

    private func commitPendingArchivedItem(source: String) {
        guard let item = pendingArchivedSelection else { return }
        pendingAssetSelection = nil
        pendingArchivedSelection = nil
        pendingCommitTimeoutItem?.cancel()
        pendingCommitTimeoutItem = nil
        selectedAsset = nil
        selectedArchivedItem = item
        multipleSelectionCount = 0
        trace("commitPendingArchivedItem item=\(shortIdentifier("archived:\(item.relativePath)")) source=\(source)")
        updateDisplayState(
            selectedAsset: .set(nil),
            selectedArchivedItem: .set(item),
            multipleSelectionCount: .set(0),
            previewImage: .set(previewImage),
            isPreviewLoading: .set(isPreviewLoading),
            metadata: .set(currentMetadataState),
            source: source
        )
    }

    private(set) var multipleSelectionCount: Int = 0

    func showEmpty() {
        trace("showEmpty")
        cancelPending()
        metadataRequestGeneration += 1
        selectedAsset = nil
        selectedArchivedItem = nil
        multipleSelectionCount = 0
        archiveCandidateInfo = nil
        previewImage = nil
        isPreviewLoading = false
        representedPreviewIdentifier = nil
        resetMetadata()
        updateDisplayState(
            selectedAsset: .set(nil),
            selectedArchivedItem: .set(nil),
            multipleSelectionCount: .set(0),
            previewImage: .set(nil),
            isPreviewLoading: .set(false),
            metadata: .set(.empty)
        )
    }

    func showMultiple(count: Int) {
        trace("showMultiple count=\(count)")
        cancelPending()
        metadataRequestGeneration += 1
        selectedAsset = nil
        selectedArchivedItem = nil
        multipleSelectionCount = count
        archiveCandidateInfo = nil
        previewImage = nil
        isPreviewLoading = false
        representedPreviewIdentifier = nil
        resetMetadata()
        updateDisplayState(
            selectedAsset: .set(nil),
            selectedArchivedItem: .set(nil),
            multipleSelectionCount: .set(count),
            previewImage: .set(nil),
            isPreviewLoading: .set(false),
            metadata: .set(.empty)
        )
    }

    func showAsset(_ asset: IndexedAsset) {
        trace("showAsset asset=\(shortIdentifier(asset.localIdentifier)) cachedState=\(displayStateCache[asset.localIdentifier] != nil) cachedPreview=\(previewImageCache[asset.localIdentifier] != nil) cachedSnapshot=\(assetSnapshotCache[asset.localIdentifier] != nil) cachedMetadata=\(metadataCache[asset.localIdentifier] != nil)")
        cancelPending()
        metadataRequestGeneration += 1
        representedPreviewIdentifier = asset.localIdentifier
        if let cachedState = displayStateCache[asset.localIdentifier] {
            hydrateFromDisplayState(cachedState)
            applyDisplayState(cachedState, source: "showAsset.cachedState")
        } else if let cachedPreview = previewImageCache[asset.localIdentifier] {
            selectedAsset = asset
            selectedArchivedItem = nil
            multipleSelectionCount = 0
            previewImage = cachedPreview
            isPreviewLoading = false
            resetMetadata()
            updateDisplayState(
                selectedAsset: .set(asset),
                selectedArchivedItem: .set(nil),
                multipleSelectionCount: .set(0),
                previewImage: .set(cachedPreview),
                isPreviewLoading: .set(false),
                metadata: .set(currentMetadataState),
                source: "showAsset.cachedPreview"
            )
        } else {
            pendingAssetSelection = asset
            previewImage = nil
            isPreviewLoading = false
            resetMetadata()
            schedulePendingCommitTimeout()
            trace("showAsset deferred pending=\(shortIdentifier(asset.localIdentifier))")
        }
        requestPreviewImage(for: asset.localIdentifier)
        requestAssetMetadata(for: asset.localIdentifier, generation: metadataRequestGeneration)
    }

    func showArchivedItem(_ item: ArchivedItem) {
        let identifier = "archived:\(item.relativePath)"
        trace("showArchivedItem item=\(shortIdentifier(identifier)) cachedState=\(displayStateCache[identifier] != nil) cachedPreview=\(previewImageCache[identifier] != nil) cachedMetadata=\(metadataCache[identifier] != nil)")
        cancelPending()
        metadataRequestGeneration += 1
        representedPreviewIdentifier = identifier
        if let cachedState = displayStateCache[identifier] {
            hydrateFromDisplayState(cachedState)
            applyDisplayState(cachedState, source: "showArchivedItem.cachedState")
        } else if let cachedPreview = previewImageCache[identifier] {
            selectedAsset = nil
            selectedArchivedItem = item
            multipleSelectionCount = 0
            previewImage = cachedPreview
            isPreviewLoading = false
            resetMetadata()
            updateDisplayState(
                selectedAsset: .set(nil),
                selectedArchivedItem: .set(item),
                multipleSelectionCount: .set(0),
                previewImage: .set(cachedPreview),
                isPreviewLoading: .set(false),
                metadata: .set(currentMetadataState),
                source: "showArchivedItem.cachedPreview"
            )
        } else {
            pendingArchivedSelection = item
            previewImage = nil
            isPreviewLoading = false
            resetMetadata()
            schedulePendingCommitTimeout()
            trace("showArchivedItem deferred pending=\(shortIdentifier(identifier))")
        }
        requestPreviewImage(forArchivedItem: item)
        requestArchivedItemMetadata(item)
    }

    private func resetMetadata() {
        originalFilename = ""; fileFormat = ""; fileSizeBytes = nil
        latitude = nil; longitude = nil; altitude = nil
        isBurst = false; isEdited = false; hasLivePhotoVideo = false
        albums = []
        exifMake = ""; exifModel = ""; exifLensModel = ""
        exifAperture = ""; exifShutterSpeed = ""; exifISO = ""; exifFocalLength = ""
        exifExposureProgram = ""; exifFlash = ""; exifMeteringMode = ""; exifExposureCompensation = ""
        photoTitle = ""; photoDescription = ""; photoKeywords = ""; dateAdded = nil; place = ""
        overallScore = nil; aiCaption = ""; labels = ""; namedPersonCount = nil; detectedPersonCount = nil; extractedText = ""
    }

    private var currentMetadataState: InspectorMetadataState {
        InspectorMetadataState(
            originalFilename: originalFilename,
            fileFormat: fileFormat,
            fileSizeBytes: fileSizeBytes,
            latitude: latitude,
            longitude: longitude,
            altitude: altitude,
            isBurst: isBurst,
            isEdited: isEdited,
            hasLivePhotoVideo: hasLivePhotoVideo,
            albums: albums,
            exifMake: exifMake,
            exifModel: exifModel,
            exifLensModel: exifLensModel,
            exifAperture: exifAperture,
            exifShutterSpeed: exifShutterSpeed,
            exifISO: exifISO,
            exifFocalLength: exifFocalLength,
            exifExposureProgram: exifExposureProgram,
            exifFlash: exifFlash,
            exifMeteringMode: exifMeteringMode,
            exifExposureCompensation: exifExposureCompensation,
            photoTitle: photoTitle,
            photoDescription: photoDescription,
            photoKeywords: photoKeywords,
            dateAdded: dateAdded,
            place: place,
            overallScore: overallScore,
            aiCaption: aiCaption,
            labels: labels,
            namedPersonCount: namedPersonCount,
            detectedPersonCount: detectedPersonCount,
            extractedText: extractedText,
            archiveCandidateInfo: archiveCandidateInfo
        )
    }

    private func applyMetadataState(_ metadata: InspectorMetadataState) {
        originalFilename = metadata.originalFilename
        fileFormat = metadata.fileFormat
        fileSizeBytes = metadata.fileSizeBytes
        latitude = metadata.latitude
        longitude = metadata.longitude
        altitude = metadata.altitude
        isBurst = metadata.isBurst
        isEdited = metadata.isEdited
        hasLivePhotoVideo = metadata.hasLivePhotoVideo
        albums = metadata.albums
        exifMake = metadata.exifMake
        exifModel = metadata.exifModel
        exifLensModel = metadata.exifLensModel
        exifAperture = metadata.exifAperture
        exifShutterSpeed = metadata.exifShutterSpeed
        exifISO = metadata.exifISO
        exifFocalLength = metadata.exifFocalLength
        exifExposureProgram = metadata.exifExposureProgram
        exifFlash = metadata.exifFlash
        exifMeteringMode = metadata.exifMeteringMode
        exifExposureCompensation = metadata.exifExposureCompensation
        photoTitle = metadata.photoTitle
        photoDescription = metadata.photoDescription
        photoKeywords = metadata.photoKeywords
        dateAdded = metadata.dateAdded
        place = metadata.place
        overallScore = metadata.overallScore
        aiCaption = metadata.aiCaption
        labels = metadata.labels
        namedPersonCount = metadata.namedPersonCount
        detectedPersonCount = metadata.detectedPersonCount
        extractedText = metadata.extractedText
        archiveCandidateInfo = metadata.archiveCandidateInfo
    }

    func toggleSection(_ title: String) {
        if collapsedSections.contains(title) {
            collapsedSections.remove(title)
        } else {
            collapsedSections.insert(title)
        }
        UserDefaults.standard.set(Array(collapsedSections), forKey: Self.collapsedSectionsKey)
    }

    func isSectionCollapsed(_ title: String) -> Bool {
        collapsedSections.contains(title)
    }

    func sections(for asset: IndexedAsset) -> [InspectorSection] {
        var result: [InspectorSection] = []

        let dateRows: [SectionRow] = [
            makeRow(id: "datetime-original", title: "Original", value: formattedDate(asset.creationDate)),
            makeRow(id: "datetime-modified", title: "Modified", value: formattedDate(asset.modificationDate)),
            makeRow(id: "datetime-added",    title: "Added",    value: formattedDate(dateAdded)),
        ].compactMap { $0 }
        if !dateRows.isEmpty {
            result.append(InspectorSection(title: "Date and Time", rows: dateRows))
        }

        let libraryRows: [SectionRow] = [
            makeRow(id: "descriptive-title",       title: "Title",       value: photoTitle.nonEmpty),
            makeRow(id: "descriptive-description", title: "Description", value: photoDescription.nonEmpty),
            makeRow(id: "descriptive-keywords",    title: "Keywords",    value: photoKeywords.nonEmpty),
            makeRow(id: "library-albums", title: "Albums", value: albums.isEmpty ? nil : albums.joined(separator: ", ")),
        ].compactMap { $0 }
        if !libraryRows.isEmpty {
            result.append(InspectorSection(title: "Library", rows: libraryRows))
        }

        let locationRows: [SectionRow] = [
            makeRow(id: "location-latitude",  title: "Latitude",  value: formatCoordinate(latitude)),
            makeRow(id: "location-longitude", title: "Longitude", value: formatCoordinate(longitude)),
            makeRow(id: "location-place",     title: "Place",     value: place.nonEmpty),
        ].compactMap { $0 }
        if !locationRows.isEmpty {
            result.append(InspectorSection(title: "Location", rows: locationRows))
        }

        let cameraRows: [SectionRow] = [
            makeRow(id: "camera-make",       title: "Make",  value: exifMake.nonEmpty),
            makeRow(id: "camera-model",      title: "Model", value: exifModel.nonEmpty),
            makeRow(id: "camera-lens-model", title: "Lens",  value: exifLensModel.nonEmpty),
        ].compactMap { $0 }
        if !cameraRows.isEmpty {
            result.append(InspectorSection(title: "Camera", rows: cameraRows))
        }

        let captureRows: [SectionRow] = [
            makeRow(id: "capture-aperture",              title: "Aperture",              value: exifAperture.nonEmpty),
            makeRow(id: "capture-shutter",               title: "Shutter Speed",         value: exifShutterSpeed.nonEmpty),
            makeRow(id: "capture-iso",                   title: "ISO",                   value: exifISO.nonEmpty),
            makeRow(id: "capture-focal-length",          title: "Focal Length",          value: exifFocalLength.nonEmpty),
            makeRow(id: "capture-exposure-program",      title: "Exposure Program",      value: exifExposureProgram.nonEmpty),
            makeRow(id: "capture-flash",                 title: "Flash",                 value: exifFlash.nonEmpty),
            makeRow(id: "capture-metering-mode",         title: "Metering Mode",         value: exifMeteringMode.nonEmpty),
            makeRow(id: "capture-exposure-compensation", title: "Exposure Compensation", value: exifExposureCompensation.nonEmpty),
        ].compactMap { $0 }
        if !captureRows.isEmpty {
            result.append(InspectorSection(title: "Capture", rows: captureRows))
        }

        var analysisRows: [SectionRow] = []
        if let score = overallScore {
            analysisRows.append(contentsOf: [
                makeRow(id: "analysis-quality", title: "Quality", value: qualityBand(for: score))
            ].compactMap { $0 })
        }
        analysisRows.append(contentsOf: [
            makeRow(id: "analysis-caption",         title: "Caption",         value: aiCaption.nonEmpty),
            makeRow(id: "analysis-labels",          title: "Labels",          value: labels.nonEmpty),
            makeRow(id: "analysis-people-detected", title: "People Detected", value: detectedPersonCount.map(String.init)),
            makeRow(id: "analysis-people-named",    title: "Named People",    value: namedPersonCount.map(String.init)),
            makeRow(id: "analysis-extracted-text",  title: "Extracted Text",  value: extractedText.nonEmpty),
        ].compactMap { $0 })
        if !analysisRows.isEmpty {
            result.append(InspectorSection(title: "Analysis", rows: analysisRows))
        }

        return result
    }

    func libraryStatusSymbols(for asset: IndexedAsset) -> [InspectorStatusSymbolRow.Item] {
        var items: [InspectorStatusSymbolRow.Item] = []

        if model.isInspectorFieldEnabled("library-icloud") {
            if asset.hasLocalOriginal {
                items.append(.init(
                    id: "library-icloud-downloaded",
                    symbolName: "checkmark.icloud",
                    accessibilityLabel: "iCloud downloaded",
                    toolTip: "Downloaded from iCloud"
                ))
            } else if asset.isCloudOnly {
                items.append(.init(
                    id: "library-icloud-cloud-only",
                    symbolName: "icloud",
                    accessibilityLabel: "iCloud cloud only",
                    toolTip: "Stored only in iCloud"
                ))
            }
        }
        if model.isInspectorFieldEnabled("library-shared"), asset.isCloudShared {
            items.append(.init(
                id: "library-shared",
                symbolName: "person.2.fill",
                accessibilityLabel: "Shared Library",
                toolTip: "In Shared Library"
            ))
        }
        if model.isInspectorFieldEnabled("library-favorite"), asset.isFavorite {
            items.append(.init(
                id: "library-favorite",
                symbolName: "heart.fill",
                accessibilityLabel: "Favourite",
                toolTip: "Marked as Favourite"
            ))
        }
        if model.isInspectorFieldEnabled("library-edited"), isEdited {
            items.append(.init(
                id: "library-edited",
                symbolName: "pencil",
                accessibilityLabel: "Edited",
                toolTip: "Edited in Photos"
            ))
        }
        if model.isInspectorFieldEnabled("library-live-photo"), hasLivePhotoVideo {
            items.append(.init(
                id: "library-live-photo",
                symbolName: "livephoto",
                accessibilityLabel: "Live Photo",
                toolTip: "Live Photo"
            ))
        }
        if model.isInspectorFieldEnabled("library-burst"), isBurst {
            items.append(.init(
                id: "library-burst",
                symbolName: "photo.stack",
                accessibilityLabel: "Burst Photo",
                toolTip: "Burst Photo"
            ))
        }
        if model.isInspectorFieldEnabled("library-hidden"), asset.isHidden {
            items.append(.init(
                id: "library-hidden",
                symbolName: "eye.slash",
                accessibilityLabel: "Hidden",
                toolTip: "Hidden in Photos"
            ))
        }

        return items
    }

    func sections(forArchivedItem item: ArchivedItem) -> [InspectorSection] {
        var result: [InspectorSection] = []

        let dateRows: [SectionRow] = [
            makeRow(id: "datetime-original", title: "Original", value: formattedDate(item.captureDate)),
            makeRow(id: "datetime-modified", title: "Modified", value: formattedDate(item.fileModificationDate)),
        ].compactMap { $0 }
        if !dateRows.isEmpty {
            result.append(InspectorSection(title: "Date and Time", rows: dateRows))
        }

        let cameraRows: [SectionRow] = [
            makeRow(id: "camera-make",       title: "Make",  value: exifMake.nonEmpty),
            makeRow(id: "camera-model",      title: "Model", value: exifModel.nonEmpty),
            makeRow(id: "camera-lens-model", title: "Lens",  value: exifLensModel.nonEmpty),
        ].compactMap { $0 }
        if !cameraRows.isEmpty {
            result.append(InspectorSection(title: "Camera", rows: cameraRows))
        }

        let captureRows: [SectionRow] = [
            makeRow(id: "capture-aperture",              title: "Aperture",              value: exifAperture.nonEmpty),
            makeRow(id: "capture-shutter",               title: "Shutter Speed",         value: exifShutterSpeed.nonEmpty),
            makeRow(id: "capture-iso",                   title: "ISO",                   value: exifISO.nonEmpty),
            makeRow(id: "capture-focal-length",          title: "Focal Length",          value: exifFocalLength.nonEmpty),
            makeRow(id: "capture-exposure-program",      title: "Exposure Program",      value: exifExposureProgram.nonEmpty),
            makeRow(id: "capture-flash",                 title: "Flash",                 value: exifFlash.nonEmpty),
            makeRow(id: "capture-metering-mode",         title: "Metering Mode",         value: exifMeteringMode.nonEmpty),
            makeRow(id: "capture-exposure-compensation", title: "Exposure Compensation", value: exifExposureCompensation.nonEmpty),
        ].compactMap { $0 }
        if !captureRows.isEmpty {
            result.append(InspectorSection(title: "Capture", rows: captureRows))
        }

        let locationRows: [SectionRow] = [
            makeRow(id: "location-latitude",  title: "Latitude",  value: formatCoordinate(latitude)),
            makeRow(id: "location-longitude", title: "Longitude", value: formatCoordinate(longitude)),
        ].compactMap { $0 }
        if !locationRows.isEmpty {
            result.append(InspectorSection(title: "Location", rows: locationRows))
        }

        return result
    }

    var locationCoordinate: CLLocationCoordinate2D? {
        guard let latitude = latitude,
              let longitude = longitude,
              (-90 ... 90).contains(latitude),
              (-180 ... 180).contains(longitude)
        else {
            return nil
        }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var title: String {
        if let archived = selectedArchivedItem {
            return URL(fileURLWithPath: archived.filename)
                .deletingPathExtension()
                .lastPathComponent
        }
        guard selectedAsset != nil else { return "" }
        let rawTitle = originalFilename.isEmpty
            ? (selectedAsset?.localIdentifier.split(separator: "/").first.map(String.init) ?? "")
            : originalFilename
        return URL(fileURLWithPath: rawTitle)
            .deletingPathExtension()
            .lastPathComponent
    }

    var subtitle: String {
        let width: Int
        let height: Int
        if let asset = selectedAsset {
            width = asset.pixelWidth
            height = asset.pixelHeight
        } else if let archived = selectedArchivedItem {
            width = archived.pixelWidth
            height = archived.pixelHeight
        } else {
            return ""
        }
        var parts: [String] = []
        if !fileFormat.isEmpty { parts.append(fileFormat) }
        if let bytes = fileSizeBytes, bytes > 0 {
            parts.append(fileSizeText(bytes))
        }
        let dim = dimensionsText(width: width, height: height)
        if dim != "Unknown" { parts.append(dim) }
        let mp = megapixelsText(width: width, height: height)
        if mp != "Unknown" { parts.append(mp) }
        return parts.joined(separator: " • ")
    }

    private func fileSizeText(_ bytes: Int) -> String {
        let mb = Double(bytes) / (1024 * 1024)
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        return String(format: "%.0f KB", Double(bytes) / 1024)
    }

    private func requestAssetMetadata(for localIdentifier: String, generation: Int) {
        trace("requestAssetMetadata start asset=\(shortIdentifier(localIdentifier)) generation=\(generation)")
        guard let phAsset = model.photosService.fetchAsset(localIdentifier: localIdentifier) else { return }

        if let cachedSnapshot = assetSnapshotCache[localIdentifier] {
            trace("requestAssetMetadata cachedSnapshot asset=\(shortIdentifier(localIdentifier))")
            applyAssetMetadataSnapshot(
                cachedSnapshot,
                representedIdentifier: localIdentifier,
                generation: generation
            )
        } else {
            let snapshot = Self.buildAssetMetadataSnapshot(
                localIdentifier: localIdentifier,
                phAsset: phAsset,
                database: model.database
            )
            assetSnapshotCache[localIdentifier] = snapshot
            applyAssetMetadataSnapshot(
                snapshot,
                representedIdentifier: localIdentifier,
                generation: generation
            )
        }

        let database = model.database
        Task.detached(priority: .userInitiated) { [weak self] in
            let snapshot = Self.buildAssetMetadataSnapshot(
                localIdentifier: localIdentifier,
                phAsset: phAsset,
                database: database
            )
            await self?.applyAssetMetadataSnapshot(
                snapshot,
                representedIdentifier: localIdentifier,
                generation: generation
            )
        }

        // EXIF — async, requires image data
        requestEXIF(for: phAsset, localIdentifier: localIdentifier, generation: generation)
    }

    private func applyAssetMetadataSnapshot(
        _ snapshot: AssetMetadataSnapshot,
        representedIdentifier: String,
        generation: Int
    ) {
        guard metadataRequestGeneration == generation else {
            trace("applyAssetMetadataSnapshot dropped generationMismatch asset=\(shortIdentifier(representedIdentifier)) generation=\(generation) current=\(metadataRequestGeneration)")
            return
        }
        guard representedPreviewIdentifier == representedIdentifier else {
            trace("applyAssetMetadataSnapshot dropped identifierMismatch asset=\(shortIdentifier(representedIdentifier)) current=\(shortIdentifier(representedPreviewIdentifier))")
            return
        }
        assetSnapshotCache[representedIdentifier] = snapshot
        trace("applyAssetMetadataSnapshot applied asset=\(shortIdentifier(representedIdentifier)) location=\(snapshot.latitude != nil && snapshot.longitude != nil) albums=\(snapshot.albums.count) analysis=\(snapshot.overallScore != nil)")

        originalFilename = snapshot.originalFilename
        fileFormat = snapshot.fileFormat
        fileSizeBytes = snapshot.fileSizeBytes
        latitude = snapshot.latitude
        longitude = snapshot.longitude
        altitude = snapshot.altitude
        isBurst = snapshot.isBurst
        isEdited = snapshot.isEdited
        hasLivePhotoVideo = snapshot.hasLivePhotoVideo
        albums = snapshot.albums
        photoTitle = snapshot.photoTitle
        photoDescription = snapshot.photoDescription
        photoKeywords = snapshot.photoKeywords
        dateAdded = snapshot.dateAdded
        place = snapshot.place
        overallScore = snapshot.overallScore
        aiCaption = snapshot.aiCaption
        labels = snapshot.labels
        namedPersonCount = snapshot.namedPersonCount
        detectedPersonCount = snapshot.detectedPersonCount
        extractedText = snapshot.extractedText
        archiveCandidateInfo = snapshot.archiveCandidateInfo
        guard pendingAssetSelection == nil else { return }
        updateDisplayState(metadata: .set(currentMetadataState), source: "applyAssetMetadataSnapshot")
    }

    private func requestEXIF(for phAsset: PHAsset, localIdentifier: String, generation: Int) {
        if let cached = metadataCache[localIdentifier] {
            trace("requestEXIF cached asset=\(shortIdentifier(localIdentifier))")
            applyParsedMetadata(cached, representedIdentifier: localIdentifier, generation: generation)
            return
        }

        trace("requestEXIF start asset=\(shortIdentifier(localIdentifier)) generation=\(generation)")
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .fastFormat
        options.isSynchronous = false
        PHImageManager.default().requestImageDataAndOrientation(for: phAsset, options: options) { [weak self] data, _, _, _ in
            guard let self, let data else { return }
            Task.detached(priority: .userInitiated) { [weak self] in
                guard let parsed = Self.parseMetadata(from: data) else { return }
                await self?.cacheAndApplyParsedMetadata(parsed, representedIdentifier: localIdentifier, generation: generation)
            }
        }
    }

    private func requestArchivedItemMetadata(_ item: ArchivedItem) {
        originalFilename = item.filename
        fileFormat = UTType(filenameExtension: item.fileExtension)?.localizedDescription ?? item.fileExtension.uppercased()
        fileSizeBytes = Int(item.fileSizeBytes)
        guard pendingArchivedSelection == nil else { return }
        updateDisplayState(metadata: .set(currentMetadataState), source: "requestArchivedItemMetadata.initial")

        let representedIdentifier = "archived:\(item.relativePath)"
        let generation = metadataRequestGeneration
        trace("requestArchivedItemMetadata start item=\(shortIdentifier(representedIdentifier)) generation=\(generation)")

        if let cached = metadataCache[representedIdentifier] {
            trace("requestArchivedItemMetadata cached item=\(shortIdentifier(representedIdentifier))")
            applyParsedMetadata(cached, representedIdentifier: representedIdentifier, generation: generation)
            return
        }

        let fileURL = URL(fileURLWithPath: item.absolutePath)
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let parsed = Self.parseMetadata(from: fileURL) else { return }
            await self?.cacheAndApplyParsedMetadata(parsed, representedIdentifier: representedIdentifier, generation: generation)
        }
    }

    private func cacheAndApplyParsedMetadata(_ parsed: ParsedMetadata, representedIdentifier: String, generation: Int) {
        metadataCache[representedIdentifier] = parsed
        trace("cacheAndApplyParsedMetadata identifier=\(shortIdentifier(representedIdentifier)) make=\(!parsed.make.isEmpty) model=\(!parsed.model.isEmpty) gps=\(parsed.latitude != nil && parsed.longitude != nil)")
        applyParsedMetadata(parsed, representedIdentifier: representedIdentifier, generation: generation)
    }

    private func applyParsedMetadata(_ parsed: ParsedMetadata, representedIdentifier: String, generation: Int) {
        guard metadataRequestGeneration == generation else {
            trace("applyParsedMetadata dropped generationMismatch identifier=\(shortIdentifier(representedIdentifier)) generation=\(generation) current=\(metadataRequestGeneration)")
            return
        }
        guard representedPreviewIdentifier == representedIdentifier else {
            trace("applyParsedMetadata dropped identifierMismatch identifier=\(shortIdentifier(representedIdentifier)) current=\(shortIdentifier(representedPreviewIdentifier))")
            return
        }
        trace("applyParsedMetadata applied identifier=\(shortIdentifier(representedIdentifier)) make=\(!parsed.make.isEmpty) model=\(!parsed.model.isEmpty) gps=\(parsed.latitude != nil && parsed.longitude != nil)")

        exifMake = parsed.make
        exifModel = parsed.model
        exifLensModel = parsed.lensModel
        exifAperture = parsed.aperture
        exifShutterSpeed = parsed.shutter
        exifISO = parsed.iso
        exifFocalLength = parsed.focal
        exifExposureProgram = parsed.exposureProgram
        exifFlash = parsed.flash
        exifMeteringMode = parsed.meteringMode
        exifExposureCompensation = parsed.exposureCompensation
        latitude = parsed.latitude ?? latitude
        longitude = parsed.longitude ?? longitude
        altitude = parsed.altitude ?? altitude
        guard pendingAssetSelection == nil, pendingArchivedSelection == nil else { return }
        updateDisplayState(metadata: .set(currentMetadataState), source: "applyParsedMetadata")
    }

    nonisolated private static func parseMetadata(from data: Data) -> ParsedMetadata? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else {
            return nil
        }
        return parseMetadataProperties(props)
    }

    nonisolated private static func parseMetadata(from fileURL: URL) -> ParsedMetadata? {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else {
            return nil
        }
        return parseMetadataProperties(props)
    }

    nonisolated private static func parseMetadataProperties(_ props: [CFString: Any]) -> ParsedMetadata {
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]

        var make = ""
        var model = ""
        var lensModel = ""
        var aperture = ""
        var shutter = ""
        var iso = ""
        var focal = ""
        var exposureProgram = ""
        var flash = ""
        var meteringMode = ""
        var exposureCompensation = ""
        var latitudeValue: Double?
        var longitudeValue: Double?
        var altitudeValue: Double?

        if let value = tiff[kCGImagePropertyTIFFMake] as? String { make = value }
        if let value = tiff[kCGImagePropertyTIFFModel] as? String { model = value }
        if let value = exif[kCGImagePropertyExifLensModel] as? String { lensModel = value }
        if let f = exif[kCGImagePropertyExifFNumber] as? Double { aperture = String(format: "f/%.1f", f) }
        if let t = exif[kCGImagePropertyExifExposureTime] as? Double, t > 0 {
            shutter = t >= 1 ? String(format: "%.1f s", t) : "1/\(Int((1.0 / t).rounded())) s"
        }
        if let speeds = exif[kCGImagePropertyExifISOSpeedRatings] as? [Int], let first = speeds.first { iso = "ISO \(first)" }
        if let fl = exif[kCGImagePropertyExifFocalLength] as? Double { focal = String(format: "%.0f mm", fl) }
        if let value = exif[kCGImagePropertyExifExposureProgram] as? Int {
            exposureProgram = ExifEnumLabels.exposureProgram(value)
        }
        if let value = exif[kCGImagePropertyExifFlash] as? Int {
            flash = ExifEnumLabels.flash(value)
        }
        if let value = exif[kCGImagePropertyExifMeteringMode] as? Int {
            meteringMode = ExifEnumLabels.meteringMode(value)
        }
        if let value = exif[kCGImagePropertyExifExposureBiasValue] as? Double { exposureCompensation = String(format: "%+.1f", value) }
        latitudeValue = parseGPSCoordinate(
            value: gps[kCGImagePropertyGPSLatitude],
            ref: gps[kCGImagePropertyGPSLatitudeRef] as? String
        )
        longitudeValue = parseGPSCoordinate(
            value: gps[kCGImagePropertyGPSLongitude],
            ref: gps[kCGImagePropertyGPSLongitudeRef] as? String
        )
        if let value = gps[kCGImagePropertyGPSAltitude] as? Double { altitudeValue = value }

        return ParsedMetadata(
            make: make,
            model: model,
            lensModel: lensModel,
            aperture: aperture,
            shutter: shutter,
            iso: iso,
            focal: focal,
            exposureProgram: exposureProgram,
            flash: flash,
            meteringMode: meteringMode,
            exposureCompensation: exposureCompensation,
            latitude: latitudeValue,
            longitude: longitudeValue,
            altitude: altitudeValue
        )
    }

    nonisolated private static func parseGPSCoordinate(value: Any?, ref: String?) -> Double? {
        guard let value else { return nil }
        let parsed: Double?
        if let number = value as? NSNumber {
            parsed = number.doubleValue
        } else if let text = value as? String {
            parsed = parseCoordinate(text)
        } else {
            parsed = nil
        }
        guard let parsed else { return nil }

        let normalizedRef = ref?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        switch normalizedRef {
        case "S", "W":
            return -abs(parsed)
        case "N", "E":
            return abs(parsed)
        default:
            return parsed
        }
    }

    nonisolated private static func parseCoordinate(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let direct = Double(trimmed), direct.isFinite {
            return direct
        }

        let ns = trimmed as NSString
        let regex = try? NSRegularExpression(pattern: "-?\\d+(?:\\.\\d+)?")
        let matches = regex?.matches(in: trimmed, range: NSRange(location: 0, length: ns.length)) ?? []
        guard let firstMatch = matches.first else { return nil }

        let numbers: [Double] = matches.compactMap { Double(ns.substring(with: $0.range)) }
        guard let first = numbers.first else { return nil }

        let hasExplicitNegative = ns.substring(with: firstMatch.range)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .hasPrefix("-")

        let magnitude: Double
        if numbers.count >= 3 {
            let degrees = abs(first)
            let minutes = abs(numbers[1])
            let seconds = abs(numbers[2])
            magnitude = degrees + (minutes / 60) + (seconds / 3600)
        } else {
            magnitude = abs(first)
        }

        let parsed = hasExplicitNegative ? -magnitude : magnitude
        if let direction = coordinateDirection(in: trimmed) {
            switch direction {
            case .south, .west:
                return -abs(parsed)
            case .north, .east:
                return abs(parsed)
            }
        }
        return parsed
    }

    private enum CoordinateDirection {
        case north
        case south
        case east
        case west
    }

    nonisolated private static func coordinateDirection(in raw: String) -> CoordinateDirection? {
        let tokens = raw
            .uppercased()
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
        for token in tokens.reversed() {
            switch token {
            case "N", "NORTH":
                return .north
            case "S", "SOUTH":
                return .south
            case "E", "EAST":
                return .east
            case "W", "WEST":
                return .west
            default:
                continue
            }
        }
        return nil
    }

    nonisolated private static func buildAssetMetadataSnapshot(
        localIdentifier: String,
        phAsset: PHAsset,
        database: DatabaseManager
    ) -> AssetMetadataSnapshot {
        let resources = PHAssetResource.assetResources(for: phAsset)
        let primary = resources.first(where: { $0.type == .photo })
            ?? resources.first(where: { $0.type == .fullSizePhoto })
            ?? resources.first

        let originalFilename = primary?.originalFilename ?? ""
        let fileFormat = primary.map { UTType($0.uniformTypeIdentifier)?.localizedDescription ?? "" } ?? ""
        let hasLivePhotoVideo = resources.contains(where: { $0.type == .pairedVideo })

        let latitude: Double?
        let longitude: Double?
        let altitude: Double?
        if let location = phAsset.location,
           CLLocationCoordinate2DIsValid(location.coordinate),
           (-90 ... 90).contains(location.coordinate.latitude),
           (-180 ... 180).contains(location.coordinate.longitude) {
            latitude = location.coordinate.latitude
            longitude = location.coordinate.longitude
            altitude = location.altitude.isFinite ? location.altitude : nil
        } else {
            latitude = nil
            longitude = nil
            altitude = nil
        }

        let albumFetch = PHAssetCollection.fetchAssetCollectionsContaining(
            phAsset, with: .album, options: nil
        )
        var albums: [String] = []
        albumFetch.enumerateObjects { collection, _, _ in
            if let title = collection.localizedTitle {
                albums.append(title)
            }
        }

        let analysis = try? database.assetRepository.fetchAnalysisFields(localIdentifier: localIdentifier)
        let archiveCandidateInfo = try? database.assetRepository.fetchArchiveCandidateInfo(localIdentifier: localIdentifier)

        return AssetMetadataSnapshot(
            originalFilename: originalFilename,
            fileFormat: fileFormat,
            fileSizeBytes: try? database.assetRepository.fetchFileSizeBytes(localIdentifier: localIdentifier),
            latitude: latitude,
            longitude: longitude,
            altitude: altitude,
            isBurst: phAsset.representsBurst,
            isEdited: phAsset.adjustmentFormatIdentifier != nil,
            hasLivePhotoVideo: hasLivePhotoVideo,
            albums: albums,
            photoTitle: analysis?.photoTitle ?? "",
            photoDescription: analysis?.photoDescription ?? "",
            photoKeywords: analysis?.photoKeywords ?? "",
            dateAdded: analysis?.dateAddedToLibrary,
            place: analysis?.place ?? "",
            overallScore: analysis?.overallScore,
            aiCaption: analysis?.aiCaption ?? "",
            labels: analysis?.formattedLabels ?? "",
            namedPersonCount: analysis?.namedPersonCount,
            detectedPersonCount: analysis?.detectedPersonCount,
            extractedText: analysis?.visionOcrText ?? "",
            archiveCandidateInfo: archiveCandidateInfo
        )
    }

    private func requestPreviewImage(for localIdentifier: String) {
        guard let asset = model.photosService.fetchAsset(localIdentifier: localIdentifier) else {
            isPreviewLoading = false
            trace("requestPreviewImage missingAsset asset=\(shortIdentifier(localIdentifier))")
            if pendingAssetSelection?.localIdentifier == localIdentifier {
                commitPendingAsset(source: "requestPreviewImage.missingAsset")
            } else {
                updateDisplayState(isPreviewLoading: .set(false), source: "requestPreviewImage.missingAsset")
            }
            return
        }

        trace("requestPreviewImage start asset=\(shortIdentifier(localIdentifier))")
        isPreviewLoading = true
        if pendingAssetSelection?.localIdentifier != localIdentifier {
            updateDisplayState(isPreviewLoading: .set(true), source: "requestPreviewImage.start")
        }
        _ = model.photosService.requestThumbnail(
            for: asset,
            targetSize: CGSize(width: 520, height: 520),
            deliveryMode: .highQualityFormat
        ) { [weak self] image in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.representedPreviewIdentifier == localIdentifier else {
                    self.trace("requestPreviewImage dropped identifierMismatch asset=\(self.shortIdentifier(localIdentifier)) current=\(self.shortIdentifier(self.representedPreviewIdentifier))")
                    return
                }
                if let image {
                    self.previewImageCache[localIdentifier] = image
                }
                self.previewImage = image
                self.isPreviewLoading = false
                self.trace("requestPreviewImage completed asset=\(self.shortIdentifier(localIdentifier)) image=\(image != nil)")
                if self.pendingAssetSelection?.localIdentifier == localIdentifier {
                    self.commitPendingAsset(source: "requestPreviewImage.completed")
                } else {
                    self.updateDisplayState(previewImage: .set(image), isPreviewLoading: .set(false), source: "requestPreviewImage.completed")
                }
            }
        }
    }

    private func requestPreviewImage(forArchivedItem item: ArchivedItem) {
        trace("requestPreviewImage archived start item=\(shortIdentifier(item.relativePath))")
        isPreviewLoading = true
        let identifier = "archived:\(item.relativePath)"
        if pendingArchivedSelection.map({ "archived:\($0.relativePath)" }) != identifier {
            updateDisplayState(isPreviewLoading: .set(true), source: "requestPreviewImage.archived.start")
        }
        Task { [weak self] in
            let image = await Task.detached(priority: .userInitiated) {
                NSImage(contentsOfFile: item.absolutePath)
            }.value
            guard let self, self.representedPreviewIdentifier == identifier else {
                self?.trace("requestPreviewImage archived dropped identifierMismatch item=\(self?.shortIdentifier(identifier) ?? "nil") current=\(self?.shortIdentifier(self?.representedPreviewIdentifier) ?? "nil")")
                return
            }
            if let image {
                self.previewImageCache[identifier] = image
            }
            self.previewImage = image
            self.isPreviewLoading = false
            self.trace("requestPreviewImage archived completed item=\(self.shortIdentifier(identifier)) image=\(image != nil)")
            if self.pendingArchivedSelection.map({ "archived:\($0.relativePath)" }) == identifier {
                self.commitPendingArchivedItem(source: "requestPreviewImage.archived.completed")
            } else {
                self.updateDisplayState(previewImage: .set(image), isPreviewLoading: .set(false), source: "requestPreviewImage.archived.completed")
            }
        }
    }

    func traceRenderedState(_ state: InspectorDisplayState) {
        let renderMode: String
        let sectionTitles: [String]
        if let asset = selectedAsset {
            renderMode = "asset"
            sectionTitles = sections(for: asset).map(\.title)
        } else if let archivedItem = selectedArchivedItem {
            renderMode = "archived"
            sectionTitles = sections(forArchivedItem: archivedItem).map(\.title)
        } else if multipleSelectionCount > 1 {
            renderMode = "multiple"
            sectionTitles = []
        } else {
            renderMode = "empty"
            sectionTitles = []
        }
        trace("view rendered mode=\(renderMode) summary=\(displayStateSummary(state)) sections=\(sectionTitles.joined(separator: "|")) hasMap=\(locationCoordinate != nil)")
    }

    private func trace(_ message: String) {
        Self.logger.debug("\(message, privacy: .public)")
    }

    private func shortIdentifier(_ identifier: String?) -> String {
        guard let identifier else { return "nil" }
        if identifier.hasPrefix("archived:") {
            let path = String(identifier.dropFirst("archived:".count))
            return URL(fileURLWithPath: path).lastPathComponent
        }
        return identifier.split(separator: "/").first.map(String.init) ?? identifier
    }

    private func displayStateSummary(_ state: InspectorDisplayState) -> String {
        let metadata = state.metadata
        return "asset=\(shortIdentifier(state.selectedAsset?.localIdentifier)) archived=\(shortIdentifier(state.selectedArchivedItem?.relativePath)) multiple=\(state.multipleSelectionCount) preview=\(state.previewImage != nil) loading=\(state.isPreviewLoading) title=\(!metadata.originalFilename.isEmpty) camera=\(!metadata.exifMake.isEmpty || !metadata.exifModel.isEmpty) capture=\(!metadata.exifAperture.isEmpty || !metadata.exifShutterSpeed.isEmpty || !metadata.exifISO.isEmpty) location=\(metadata.latitude != nil && metadata.longitude != nil) analysis=\(metadata.overallScore != nil || !metadata.aiCaption.isEmpty || metadata.detectedPersonCount != nil || metadata.namedPersonCount != nil || !metadata.extractedText.isEmpty)"
    }

    private func formattedDate(_ date: Date?) -> String {
        guard let date else { return "Unknown" }
        return Self.dateFormatter.string(from: date)
    }

    private func dimensionsText(width: Int, height: Int) -> String {
        guard width > 0, height > 0 else { return "Unknown" }
        return "\(width) × \(height)"
    }

    private func megapixelsText(width: Int, height: Int) -> String {
        guard width > 0, height > 0 else { return "Unknown" }
        let megapixels = (Double(width) * Double(height)) / 1_000_000
        return String(format: "%.1f MP", megapixels)
    }

    private func makeRow(id: String, title: String, value: String?) -> SectionRow? {
        guard model.isInspectorFieldEnabled(id), let resolvedValue = value?.nonEmpty else { return nil }
        return SectionRow(title: title, value: resolvedValue)
    }

    private func formatCoordinate(_ value: Double?) -> String? {
        guard let value else { return nil }
        return String(format: "%.6f", value)
    }

    private func qualityBand(for score: Double) -> String {
        if score < 0.3 { return "Low" }
        if score < 0.7 { return "Medium" }
        return "High"
    }

    private func archiveStatusLabel(_ status: ArchiveCandidateStatus) -> String {
        switch status {
        case .pending: return "Pending"
        case .exporting: return "Exporting"
        case .exported: return "Exported"
        case .deleted: return "Deleted"
        case .failed: return "Failed"
        }
    }

    private func mediaTypeLabel(for value: Int) -> String {
        switch value {
        case 1: return "Image"
        case 2: return "Video"
        case 3: return "Audio"
        default: return "Unknown (\(value))"
        }
    }
}

private struct ParsedMetadata {
    let make: String
    let model: String
    let lensModel: String
    let aperture: String
    let shutter: String
    let iso: String
    let focal: String
    let exposureProgram: String
    let flash: String
    let meteringMode: String
    let exposureCompensation: String
    let latitude: Double?
    let longitude: Double?
    let altitude: Double?
}

private struct AssetMetadataSnapshot {
    let originalFilename: String
    let fileFormat: String
    let fileSizeBytes: Int?
    let latitude: Double?
    let longitude: Double?
    let altitude: Double?
    let isBurst: Bool
    let isEdited: Bool
    let hasLivePhotoVideo: Bool
    let albums: [String]
    let photoTitle: String
    let photoDescription: String
    let photoKeywords: String
    let dateAdded: Date?
    let place: String
    let overallScore: Double?
    let aiCaption: String
    let labels: String
    let namedPersonCount: Int?
    let detectedPersonCount: Int?
    let extractedText: String
    let archiveCandidateInfo: ArchiveCandidateInfo?
}

private struct InspectorDisplayState {
    let selectedAsset: IndexedAsset?
    let selectedArchivedItem: ArchivedItem?
    let multipleSelectionCount: Int
    let previewImage: NSImage?
    let isPreviewLoading: Bool
    let metadata: InspectorMetadataState

    static let empty = InspectorDisplayState(
        selectedAsset: nil,
        selectedArchivedItem: nil,
        multipleSelectionCount: 0,
        previewImage: nil,
        isPreviewLoading: false,
        metadata: .empty
    )
}

private struct InspectorMetadataState {
    let originalFilename: String
    let fileFormat: String
    let fileSizeBytes: Int?
    let latitude: Double?
    let longitude: Double?
    let altitude: Double?
    let isBurst: Bool
    let isEdited: Bool
    let hasLivePhotoVideo: Bool
    let albums: [String]
    let exifMake: String
    let exifModel: String
    let exifLensModel: String
    let exifAperture: String
    let exifShutterSpeed: String
    let exifISO: String
    let exifFocalLength: String
    let exifExposureProgram: String
    let exifFlash: String
    let exifMeteringMode: String
    let exifExposureCompensation: String
    let photoTitle: String
    let photoDescription: String
    let photoKeywords: String
    let dateAdded: Date?
    let place: String
    let overallScore: Double?
    let aiCaption: String
    let labels: String
    let namedPersonCount: Int?
    let detectedPersonCount: Int?
    let extractedText: String
    let archiveCandidateInfo: ArchiveCandidateInfo?

    static let empty = InspectorMetadataState(
        originalFilename: "",
        fileFormat: "",
        fileSizeBytes: nil,
        latitude: nil,
        longitude: nil,
        altitude: nil,
        isBurst: false,
        isEdited: false,
        hasLivePhotoVideo: false,
        albums: [],
        exifMake: "",
        exifModel: "",
        exifLensModel: "",
        exifAperture: "",
        exifShutterSpeed: "",
        exifISO: "",
        exifFocalLength: "",
        exifExposureProgram: "",
        exifFlash: "",
        exifMeteringMode: "",
        exifExposureCompensation: "",
        photoTitle: "",
        photoDescription: "",
        photoKeywords: "",
        dateAdded: nil,
        place: "",
        overallScore: nil,
        aiCaption: "",
        labels: "",
        namedPersonCount: nil,
        detectedPersonCount: nil,
        extractedText: "",
        archiveCandidateInfo: nil
    )
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct InspectorSection: Identifiable {
    let title: String
    let rows: [SectionRow]

    var id: String { title }
}

private struct SectionRow: Identifiable {
    let title: String
    let value: String

    var id: String { title }
}

private struct InspectorReadOnlyView: View {
    @ObservedObject var viewModel: InspectorReadOnlyViewModel

    var body: some View {
        ScrollView {
            if let asset = viewModel.selectedAsset {
                VStack(alignment: .leading, spacing: 16) {
                    InspectorHeaderView(title: viewModel.title, subtitle: viewModel.subtitle.isEmpty ? nil : viewModel.subtitle)

                    InspectorStatusSymbolRow(items: viewModel.libraryStatusSymbols(for: asset))

                    InspectorSectionContainer(
                        "Preview",
                        isExpanded: Binding(
                            get: { !viewModel.isSectionCollapsed("Preview") },
                            set: { _ in viewModel.toggleSection("Preview") }
                        )
                    ) {
                        InspectorPreviewCard(image: viewModel.previewImage, isLoading: viewModel.isPreviewLoading)
                    }

                    ForEach(viewModel.sections(for: asset)) { section in
                        InspectorSectionContainer(
                            section.title,
                            isExpanded: Binding(
                                get: { !viewModel.isSectionCollapsed(section.title) },
                                set: { _ in viewModel.toggleSection(section.title) }
                            )
                        ) {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(section.rows) { row in
                                    InspectorFieldRow {
                                        InspectorFieldLabel(row.title)
                                    } value: {
                                        Text(row.value)
                                            .font(.body.monospaced())
                                            .foregroundStyle(.primary)
                                            .lineLimit(2)
                                            .truncationMode(.middle)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                                if section.title == "Location", let coordinate = viewModel.locationCoordinate {
                                    locationMapView(for: coordinate)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.vertical, 12)
            } else if let archivedItem = viewModel.selectedArchivedItem {
                VStack(alignment: .leading, spacing: 16) {
                    InspectorHeaderView(title: viewModel.title, subtitle: viewModel.subtitle.isEmpty ? nil : viewModel.subtitle)

                    InspectorSectionContainer(
                        "Preview",
                        isExpanded: Binding(
                            get: { !viewModel.isSectionCollapsed("Preview") },
                            set: { _ in viewModel.toggleSection("Preview") }
                        )
                    ) {
                        InspectorPreviewCard(image: viewModel.previewImage, isLoading: viewModel.isPreviewLoading)
                    }

                    ForEach(viewModel.sections(forArchivedItem: archivedItem)) { section in
                        InspectorSectionContainer(
                            section.title,
                            isExpanded: Binding(
                                get: { !viewModel.isSectionCollapsed(section.title) },
                                set: { _ in viewModel.toggleSection(section.title) }
                            )
                        ) {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(section.rows) { row in
                                    InspectorFieldRow {
                                        InspectorFieldLabel(row.title)
                                    } value: {
                                        Text(row.value)
                                            .font(.body.monospaced())
                                            .foregroundStyle(.primary)
                                            .lineLimit(2)
                                            .truncationMode(.middle)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                                if section.title == "Location", let coordinate = viewModel.locationCoordinate {
                                    locationMapView(for: coordinate)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.vertical, 12)
            } else if viewModel.multipleSelectionCount > 1 {
                PlaceholderView(
                    symbolName: "photo.stack",
                    title: "\(viewModel.multipleSelectionCount) Items Selected",
                    description: "Select a single item to view metadata."
                )
                .frame(maxWidth: .infinity)
                .containerRelativeFrame(.vertical, alignment: .center)
            } else {
                PlaceholderView(
                    symbolName: "slider.horizontal.3",
                    title: "No Selection",
                    description: "Select an item to view metadata."
                )
                .frame(maxWidth: .infinity)
                .containerRelativeFrame(.vertical, alignment: .center)
            }
        }
        .inspectorScrollSetup()
        .animation(.easeInOut(duration: 0.2), value: viewModel.collapsedSections)
        .onAppear {
            viewModel.traceRenderedState(viewModel.displayState)
        }
        .onReceive(viewModel.$displayState.dropFirst()) { state in
            viewModel.traceRenderedState(state)
        }
    }

    @ViewBuilder
    private func locationMapView(for coordinate: CLLocationCoordinate2D) -> some View {
        SharedUI.InspectorLocationMapView(coordinate: coordinate)
            .frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

}
