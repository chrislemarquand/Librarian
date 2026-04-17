import Cocoa
import MapKit
import Photos
import SwiftUI
import Combine
import UniformTypeIdentifiers
import SharedUI
import ImageIO

final class InspectorController: NSViewController {

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
        refreshForSelection()
    }

    private func refreshForSelection() {
        if model.selectedAssetCount > 1 {
            showMultiple(count: model.selectedAssetCount)
        } else if let asset = model.selectedAsset {
            showAsset(asset)
        } else if let archivedItem = model.selectedArchivedItem {
            viewModel.showArchivedItem(archivedItem)
        } else {
            showEmpty()
        }
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
    @Published private(set) var selectedAsset: IndexedAsset?
    @Published private(set) var selectedArchivedItem: ArchivedItem?
    @Published private(set) var archiveCandidateInfo: ArchiveCandidateInfo?
    @Published private(set) var previewImage: NSImage?
    @Published private(set) var isPreviewLoading = false
    @Published private(set) var collapsedSections: Set<String>
    @Published private(set) var originalFilename: String = ""
    @Published private(set) var fileFormat: String = ""
    @Published private(set) var fileSizeBytes: Int? = nil
    // Location
    @Published private(set) var latitude: Double? = nil
    @Published private(set) var longitude: Double? = nil
    @Published private(set) var altitude: Double? = nil
    // Library
    @Published private(set) var isBurst = false
    @Published private(set) var isEdited = false
    @Published private(set) var hasLivePhotoVideo = false
    @Published private(set) var albums: [String] = []
    // Camera & Capture (EXIF, async)
    @Published private(set) var exifMake: String = ""
    @Published private(set) var exifModel: String = ""
    @Published private(set) var exifSerialNumber: String = ""
    @Published private(set) var exifLensModel: String = ""
    @Published private(set) var exifAperture: String = ""
    @Published private(set) var exifShutterSpeed: String = ""
    @Published private(set) var exifISO: String = ""
    @Published private(set) var exifFocalLength: String = ""
    @Published private(set) var exifExposureProgram: String = ""
    @Published private(set) var exifFlash: String = ""
    @Published private(set) var exifMeteringMode: String = ""
    @Published private(set) var exifExposureCompensation: String = ""
    // Analysis
    @Published private(set) var overallScore: Double? = nil
    @Published private(set) var aiCaption: String = ""
    @Published private(set) var namedPersonCount: Int? = nil
    @Published private(set) var detectedPersonCount: Int? = nil
    @Published private(set) var extractedText: String = ""

    private let model: AppModel
    private var representedPreviewIdentifier: String?
    private var metadataRequestGeneration = 0
    private var metadataCache: [String: ParsedMetadata] = [:]

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

    @Published private(set) var multipleSelectionCount: Int = 0

    func showEmpty() {
        metadataRequestGeneration += 1
        selectedAsset = nil
        selectedArchivedItem = nil
        multipleSelectionCount = 0
        archiveCandidateInfo = nil
        previewImage = nil
        isPreviewLoading = false
        representedPreviewIdentifier = nil
        resetMetadata()
    }

    func showMultiple(count: Int) {
        metadataRequestGeneration += 1
        selectedAsset = nil
        selectedArchivedItem = nil
        multipleSelectionCount = count
        archiveCandidateInfo = nil
        previewImage = nil
        isPreviewLoading = false
        representedPreviewIdentifier = nil
        resetMetadata()
    }

    func showAsset(_ asset: IndexedAsset) {
        metadataRequestGeneration += 1
        selectedAsset = asset
        selectedArchivedItem = nil
        archiveCandidateInfo = model.archiveCandidateInfo(for: asset.localIdentifier)
        previewImage = nil
        resetMetadata()
        representedPreviewIdentifier = asset.localIdentifier
        requestPreviewImage(for: asset.localIdentifier)
        requestAssetMetadata(for: asset.localIdentifier)
    }

    func showArchivedItem(_ item: ArchivedItem) {
        metadataRequestGeneration += 1
        selectedAsset = nil
        selectedArchivedItem = item
        archiveCandidateInfo = nil
        previewImage = nil
        resetMetadata()
        representedPreviewIdentifier = "archived:\(item.relativePath)"
        requestPreviewImage(forArchivedItem: item)
        requestArchivedItemMetadata(item)
    }

    private func resetMetadata() {
        originalFilename = ""; fileFormat = ""; fileSizeBytes = nil
        latitude = nil; longitude = nil; altitude = nil
        isBurst = false; isEdited = false; hasLivePhotoVideo = false
        albums = []
        exifMake = ""; exifModel = ""; exifSerialNumber = ""; exifLensModel = ""
        exifAperture = ""; exifShutterSpeed = ""; exifISO = ""; exifFocalLength = ""
        exifExposureProgram = ""; exifFlash = ""; exifMeteringMode = ""; exifExposureCompensation = ""
        overallScore = nil; aiCaption = ""; namedPersonCount = nil; detectedPersonCount = nil; extractedText = ""
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

        let cloudLabel: String
        if asset.hasLocalOriginal { cloudLabel = "Downloaded" }
        else if asset.isCloudOnly { cloudLabel = "Cloud only" }
        else { cloudLabel = asset.iCloudDownloadState }

        let dateRows: [SectionRow] = [
            makeRow(id: "datetime-original", title: "Date Time Original", value: formattedDate(asset.creationDate)),
            makeRow(id: "datetime-digitized", title: "Date Time Digitized", value: nil),
            makeRow(id: "datetime-modified", title: "Date Time", value: formattedDate(asset.modificationDate)),
        ].compactMap { $0 }
        if !dateRows.isEmpty {
            result.append(InspectorSection(title: "Date and Time", rows: dateRows))
        }

        let cameraRows: [SectionRow] = [
            makeRow(id: "camera-make", title: "Make", value: exifMake.nonEmpty),
            makeRow(id: "camera-model", title: "Model", value: exifModel.nonEmpty),
            makeRow(id: "camera-serial", title: "Serial Number", value: exifSerialNumber.nonEmpty),
            makeRow(id: "camera-lens-model", title: "Lens Model", value: exifLensModel.nonEmpty),
        ].compactMap { $0 }
        if !cameraRows.isEmpty {
            result.append(InspectorSection(title: "Camera", rows: cameraRows))
        }

        let captureRows: [SectionRow] = [
            makeRow(id: "capture-aperture", title: "Aperture", value: exifAperture.nonEmpty),
            makeRow(id: "capture-shutter", title: "Shutter Speed", value: exifShutterSpeed.nonEmpty),
            makeRow(id: "capture-iso", title: "ISO", value: exifISO.nonEmpty),
            makeRow(id: "capture-focal-length", title: "Focal Length", value: exifFocalLength.nonEmpty),
            makeRow(id: "capture-exposure-program", title: "Exposure Program", value: exifExposureProgram.nonEmpty),
            makeRow(id: "capture-flash", title: "Flash", value: exifFlash.nonEmpty),
            makeRow(id: "capture-metering-mode", title: "Metering Mode", value: exifMeteringMode.nonEmpty),
            makeRow(id: "capture-exposure-compensation", title: "Exposure Compensation", value: exifExposureCompensation.nonEmpty),
        ].compactMap { $0 }
        if !captureRows.isEmpty {
            result.append(InspectorSection(title: "Capture", rows: captureRows))
        }

        let locationRows: [SectionRow] = [
            makeRow(id: "location-latitude", title: "Latitude", value: formatCoordinate(latitude)),
            makeRow(id: "location-longitude", title: "Longitude", value: formatCoordinate(longitude)),
            makeRow(id: "location-direction", title: "Direction", value: nil),
        ].compactMap { $0 }
        if !locationRows.isEmpty {
            result.append(InspectorSection(title: "Location", rows: locationRows))
        }

        let libraryRows: [SectionRow] = [
            makeRow(id: "library-favorite", title: "Favorite", value: yesNo(asset.isFavorite)),
            makeRow(id: "library-hidden", title: "Hidden", value: yesNo(asset.isHidden)),
            makeRow(id: "library-edited", title: "Edited", value: yesNo(isEdited)),
            makeRow(id: "library-burst", title: "Burst Photo", value: yesNo(isBurst)),
            makeRow(id: "library-live-photo", title: "Live Photo", value: yesNo(hasLivePhotoVideo)),
            makeRow(id: "library-icloud", title: "iCloud", value: cloudLabel),
            makeRow(id: "library-albums", title: "Albums", value: albums.isEmpty ? nil : albums.joined(separator: ", ")),
            makeRow(id: "library-shared", title: "Shared Library", value: yesNo(asset.isCloudShared)),
        ].compactMap { $0 }
        if !libraryRows.isEmpty {
            result.append(InspectorSection(title: "Library", rows: libraryRows))
        }

        var analysisRows: [SectionRow] = []
        if let score = overallScore {
            analysisRows.append(contentsOf: [
                makeRow(id: "analysis-quality", title: "Quality", value: qualityBand(for: score))
            ].compactMap { $0 })
        }
        analysisRows.append(contentsOf: [
            makeRow(id: "analysis-caption", title: "Caption", value: aiCaption.nonEmpty),
            makeRow(id: "analysis-people-detected", title: "People Detected", value: detectedPersonCount.map(String.init)),
            makeRow(id: "analysis-people-named", title: "Named People", value: namedPersonCount.map(String.init)),
            makeRow(id: "analysis-extracted-text", title: "Extracted Text", value: extractedText.nonEmpty),
        ].compactMap { $0 })
        if !analysisRows.isEmpty {
            result.append(InspectorSection(title: "Analysis", rows: analysisRows))
        }

        if let info = archiveCandidateInfo {
            let archiveRows: [SectionRow] = [
                makeRow(id: "archive-status", title: "Status", value: archiveStatusLabel(info.status)),
                makeRow(id: "archive-queued", title: "Queued", value: formattedDate(info.queuedAt)),
                makeRow(id: "archive-exported", title: "Exported", value: info.exportedAt.map { formattedDate($0) }),
                makeRow(id: "archive-deleted", title: "Deleted", value: info.deletedAt.map { formattedDate($0) }),
                makeRow(id: "archive-path", title: "Archive Path", value: info.archivePath?.nonEmpty),
                makeRow(id: "archive-last-error", title: "Last Error", value: info.lastError?.nonEmpty),
            ].compactMap { $0 }
            if !archiveRows.isEmpty {
                result.append(InspectorSection(title: "Archive Status", rows: archiveRows))
            }
        }

        return result
    }

    func sections(forArchivedItem item: ArchivedItem) -> [InspectorSection] {
        var result: [InspectorSection] = []

        let dateRows: [SectionRow] = [
            makeRow(id: "datetime-original", title: "Date Time Original", value: formattedDate(item.captureDate)),
            makeRow(id: "datetime-digitized", title: "Date Time Digitized", value: nil),
            makeRow(id: "datetime-modified", title: "Date Time", value: formattedDate(item.fileModificationDate)),
        ].compactMap { $0 }
        if !dateRows.isEmpty {
            result.append(InspectorSection(title: "Date and Time", rows: dateRows))
        }

        let cameraRows: [SectionRow] = [
            makeRow(id: "camera-make", title: "Make", value: exifMake.nonEmpty),
            makeRow(id: "camera-model", title: "Model", value: exifModel.nonEmpty),
            makeRow(id: "camera-serial", title: "Serial Number", value: exifSerialNumber.nonEmpty),
            makeRow(id: "camera-lens-model", title: "Lens Model", value: exifLensModel.nonEmpty),
        ].compactMap { $0 }
        if !cameraRows.isEmpty {
            result.append(InspectorSection(title: "Camera", rows: cameraRows))
        }

        let captureRows: [SectionRow] = [
            makeRow(id: "capture-aperture", title: "Aperture", value: exifAperture.nonEmpty),
            makeRow(id: "capture-shutter", title: "Shutter Speed", value: exifShutterSpeed.nonEmpty),
            makeRow(id: "capture-iso", title: "ISO", value: exifISO.nonEmpty),
            makeRow(id: "capture-focal-length", title: "Focal Length", value: exifFocalLength.nonEmpty),
            makeRow(id: "capture-exposure-program", title: "Exposure Program", value: exifExposureProgram.nonEmpty),
            makeRow(id: "capture-flash", title: "Flash", value: exifFlash.nonEmpty),
            makeRow(id: "capture-metering-mode", title: "Metering Mode", value: exifMeteringMode.nonEmpty),
            makeRow(id: "capture-exposure-compensation", title: "Exposure Compensation", value: exifExposureCompensation.nonEmpty),
        ].compactMap { $0 }
        if !captureRows.isEmpty {
            result.append(InspectorSection(title: "Capture", rows: captureRows))
        }

        let locationRows: [SectionRow] = [
            makeRow(id: "location-latitude", title: "Latitude", value: formatCoordinate(latitude)),
            makeRow(id: "location-longitude", title: "Longitude", value: formatCoordinate(longitude)),
            makeRow(id: "location-direction", title: "Direction", value: nil),
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

    private func requestAssetMetadata(for localIdentifier: String) {
        if let phAsset = model.photosService.fetchAsset(localIdentifier: localIdentifier) {
            // File info
            let resources = PHAssetResource.assetResources(for: phAsset)
            let primary = resources.first(where: { $0.type == .photo })
                ?? resources.first(where: { $0.type == .fullSizePhoto })
                ?? resources.first
            if let resource = primary {
                originalFilename = resource.originalFilename
                fileFormat = UTType(resource.uniformTypeIdentifier)?.localizedDescription ?? ""
            }
            hasLivePhotoVideo = resources.contains(where: { $0.type == .pairedVideo })

            // PHAsset location validity:
            // Core Location can carry coordinate/altitude values even when accuracy is invalid.
            // Treat invalid accuracy as "no data" so inspector does not show misleading zeros.
            if let location = phAsset.location {
                if location.horizontalAccuracy >= 0 {
                    latitude = location.coordinate.latitude
                    longitude = location.coordinate.longitude
                } else {
                    latitude = nil
                    longitude = nil
                }

                if location.verticalAccuracy >= 0 {
                    altitude = location.altitude
                } else {
                    altitude = nil
                }
            } else {
                latitude = nil
                longitude = nil
                altitude = nil
            }
            isBurst = phAsset.representsBurst
            isEdited = phAsset.adjustmentFormatIdentifier != nil

            // Albums (synchronous Photos fetch)
            let albumFetch = PHAssetCollection.fetchAssetCollectionsContaining(
                phAsset, with: .album, options: nil
            )
            var names: [String] = []
            albumFetch.enumerateObjects { collection, _, _ in
                if let title = collection.localizedTitle { names.append(title) }
            }
            albums = names

            // EXIF — async, requires image data
            requestEXIF(for: phAsset, localIdentifier: localIdentifier, generation: metadataRequestGeneration)
        }

        // DB reads
        fileSizeBytes = try? model.database.assetRepository.fetchFileSizeBytes(localIdentifier: localIdentifier)
        if let analysis = try? model.database.assetRepository.fetchAnalysisFields(localIdentifier: localIdentifier) {
            overallScore = analysis.overallScore
            aiCaption = analysis.aiCaption ?? ""
            namedPersonCount = analysis.namedPersonCount
            detectedPersonCount = analysis.detectedPersonCount
            extractedText = analysis.visionOcrText ?? ""
        }
    }

    private func requestEXIF(for phAsset: PHAsset, localIdentifier: String, generation: Int) {
        if let cached = metadataCache[localIdentifier] {
            applyParsedMetadata(cached, representedIdentifier: localIdentifier, generation: generation)
            return
        }

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

        let representedIdentifier = "archived:\(item.relativePath)"
        let generation = metadataRequestGeneration

        if let cached = metadataCache[representedIdentifier] {
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
        applyParsedMetadata(parsed, representedIdentifier: representedIdentifier, generation: generation)
    }

    private func applyParsedMetadata(_ parsed: ParsedMetadata, representedIdentifier: String, generation: Int) {
        guard metadataRequestGeneration == generation else { return }
        guard representedPreviewIdentifier == representedIdentifier else { return }

        exifMake = parsed.make
        exifModel = parsed.model
        exifSerialNumber = parsed.serial
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
        var serial = ""
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
        if let value = exif[kCGImagePropertyExifBodySerialNumber] as? String { serial = value }
        if let value = exif[kCGImagePropertyExifLensModel] as? String { lensModel = value }
        if let f = exif[kCGImagePropertyExifFNumber] as? Double { aperture = String(format: "f/%.1f", f) }
        if let t = exif[kCGImagePropertyExifExposureTime] as? Double, t > 0 {
            shutter = t >= 1 ? String(format: "%.1f s", t) : "1/\(Int((1.0 / t).rounded())) s"
        }
        if let speeds = exif[kCGImagePropertyExifISOSpeedRatings] as? [Int], let first = speeds.first { iso = "ISO \(first)" }
        if let fl = exif[kCGImagePropertyExifFocalLength] as? Double { focal = String(format: "%.0f mm", fl) }
        if let value = exif[kCGImagePropertyExifExposureProgram] as? Int { exposureProgram = "\(value)" }
        if let value = exif[kCGImagePropertyExifFlash] as? Int { flash = "\(value)" }
        if let value = exif[kCGImagePropertyExifMeteringMode] as? Int { meteringMode = "\(value)" }
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
            serial: serial,
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

    private func requestPreviewImage(for localIdentifier: String) {
        guard let asset = model.photosService.fetchAsset(localIdentifier: localIdentifier) else {
            isPreviewLoading = false
            return
        }

        isPreviewLoading = true
        _ = model.photosService.requestThumbnail(
            for: asset,
            targetSize: CGSize(width: 520, height: 520),
            deliveryMode: .highQualityFormat
        ) { [weak self] image in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.representedPreviewIdentifier == localIdentifier else { return }
                self.previewImage = image
                self.isPreviewLoading = false
            }
        }
    }

    private func requestPreviewImage(forArchivedItem item: ArchivedItem) {
        isPreviewLoading = true
        let identifier = "archived:\(item.relativePath)"
        Task { [weak self] in
            let image = await Task.detached(priority: .userInitiated) {
                NSImage(contentsOfFile: item.absolutePath)
            }.value
            guard let self, self.representedPreviewIdentifier == identifier else { return }
            self.previewImage = image
            self.isPreviewLoading = false
        }
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

    private func yesNo(_ value: Bool) -> String {
        value ? "Yes" : "No"
    }

    private func makeRow(id: String, title: String, value: String?) -> SectionRow? {
        guard model.isInspectorFieldEnabled(id) else { return nil }
        let resolvedValue = value?.nonEmpty ?? "—"
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
    let serial: String
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
    }

    @ViewBuilder
    private func locationMapView(for coordinate: CLLocationCoordinate2D) -> some View {
        SharedUI.InspectorLocationMapView(coordinate: coordinate)
            .frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

}
