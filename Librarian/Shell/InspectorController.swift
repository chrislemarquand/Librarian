import Cocoa
import Photos
import SwiftUI
import Combine
import UniformTypeIdentifiers
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
            InspectorReadOnlyView(viewModel: viewModel)
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
    }

    @objc private func selectionChanged() {
        refreshForSelection()
    }

    private func refreshForSelection() {
        if model.selectedAssetCount > 1 {
            showMultiple(count: model.selectedAssetCount)
        } else if let asset = model.selectedAsset {
            showAsset(asset)
        } else {
            showEmpty()
        }
    }
}

@MainActor
private final class InspectorReadOnlyViewModel: ObservableObject {
    @Published private(set) var selectedAsset: IndexedAsset?
    @Published private(set) var archiveCandidateInfo: ArchiveCandidateInfo?
    @Published private(set) var previewImage: NSImage?
    @Published private(set) var isPreviewLoading = false
    @Published private(set) var collapsedSections: Set<String>
    @Published private(set) var originalFilename: String = ""
    @Published private(set) var fileFormat: String = ""
    @Published private(set) var fileSizeBytes: Int? = nil
    // Library
    @Published private(set) var hasLocation = false
    @Published private(set) var isBurst = false
    @Published private(set) var isEdited = false
    @Published private(set) var hasLivePhotoVideo = false
    @Published private(set) var albums: [String] = []
    // Camera & Capture (EXIF, async)
    @Published private(set) var exifAperture: String = ""
    @Published private(set) var exifShutterSpeed: String = ""
    @Published private(set) var exifISO: String = ""
    @Published private(set) var exifFocalLength: String = ""
    // Analysis
    @Published private(set) var overallScore: Double? = nil
    @Published private(set) var aiCaption: String = ""
    @Published private(set) var namedPersonCount: Int? = nil
    @Published private(set) var detectedPersonCount: Int? = nil

    private let model: AppModel
    private var representedPreviewIdentifier: String?

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
            // Camera & Capture, Resources, and Analysis are collapsed by default on first launch.
            self.collapsedSections = ["Camera & Capture", "Resources", "Analysis"]
        }
    }

    @Published private(set) var multipleSelectionCount: Int = 0

    func showEmpty() {
        selectedAsset = nil
        multipleSelectionCount = 0
        archiveCandidateInfo = nil
        previewImage = nil
        isPreviewLoading = false
        representedPreviewIdentifier = nil
        resetMetadata()
    }

    func showMultiple(count: Int) {
        selectedAsset = nil
        multipleSelectionCount = count
        archiveCandidateInfo = nil
        previewImage = nil
        isPreviewLoading = false
        representedPreviewIdentifier = nil
        resetMetadata()
    }

    func showAsset(_ asset: IndexedAsset) {
        selectedAsset = asset
        archiveCandidateInfo = model.archiveCandidateInfo(for: asset.localIdentifier)
        previewImage = nil
        resetMetadata()
        representedPreviewIdentifier = asset.localIdentifier
        requestPreviewImage(for: asset.localIdentifier)
        requestAssetMetadata(for: asset.localIdentifier)
    }

    private func resetMetadata() {
        originalFilename = ""; fileFormat = ""; fileSizeBytes = nil
        hasLocation = false; isBurst = false; isEdited = false; hasLivePhotoVideo = false
        albums = []
        exifAperture = ""; exifShutterSpeed = ""; exifISO = ""; exifFocalLength = ""
        overallScore = nil; aiCaption = ""; namedPersonCount = nil; detectedPersonCount = nil
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

        // Date & Location
        result.append(InspectorSection(title: "Date & Location", rows: [
            InspectorFieldRow(title: "Captured", value: formattedDate(asset.creationDate)),
            InspectorFieldRow(title: "Modified", value: formattedDate(asset.modificationDate)),
            InspectorFieldRow(title: "Location", value: hasLocation ? "Yes" : "No"),
        ]))

        // Library
        let cloudLabel: String
        if asset.hasLocalOriginal { cloudLabel = "Downloaded" }
        else if asset.isCloudOnly { cloudLabel = "Cloud only" }
        else { cloudLabel = asset.iCloudDownloadState }
        result.append(InspectorSection(title: "Library", rows: [
            InspectorFieldRow(title: "Favourite", value: yesNo(asset.isFavorite)),
            InspectorFieldRow(title: "Hidden", value: yesNo(asset.isHidden)),
            InspectorFieldRow(title: "Edited", value: yesNo(isEdited)),
            InspectorFieldRow(title: "Burst Photo", value: yesNo(isBurst)),
            InspectorFieldRow(title: "iCloud", value: cloudLabel),
            InspectorFieldRow(title: "Albums", value: albums.isEmpty ? "None" : albums.joined(separator: ", ")),
        ]))

        // Camera & Capture (EXIF — only shown when data arrives, collapsed by default)
        let captureRows: [InspectorFieldRow] = [
            exifAperture.isEmpty    ? nil : InspectorFieldRow(title: "Aperture",      value: exifAperture),
            exifShutterSpeed.isEmpty ? nil : InspectorFieldRow(title: "Shutter Speed", value: exifShutterSpeed),
            exifISO.isEmpty         ? nil : InspectorFieldRow(title: "ISO",           value: exifISO),
            exifFocalLength.isEmpty ? nil : InspectorFieldRow(title: "Focal Length",  value: exifFocalLength),
        ].compactMap { $0 }
        if !captureRows.isEmpty {
            result.append(InspectorSection(title: "Camera & Capture", rows: captureRows))
        }

        // Resources (collapsed by default)
        result.append(InspectorSection(title: "Resources", rows: [
            InspectorFieldRow(title: "Original",       value: yesNo(asset.hasLocalOriginal)),
            InspectorFieldRow(title: "Edited Version", value: yesNo(isEdited)),
            InspectorFieldRow(title: "Live Photo",     value: yesNo(hasLivePhotoVideo)),
        ]))

        // Analysis — only if quality score available (analysis has been run); collapsed by default
        if let score = overallScore {
            var rows: [InspectorFieldRow] = [
                InspectorFieldRow(title: "Quality Score", value: String(format: "%.2f", score)),
            ]
            if !aiCaption.isEmpty {
                rows.append(InspectorFieldRow(title: "Caption", value: aiCaption))
            }
            let detected = detectedPersonCount ?? 0
            if detected > 0 {
                let named = namedPersonCount ?? 0
                rows.append(InspectorFieldRow(title: "People", value: "\(detected) detected, \(named) named"))
            }
            result.append(InspectorSection(title: "Analysis", rows: rows))
        }

        // Archive — only if asset is in the archive queue
        if let info = archiveCandidateInfo {
            var rows: [InspectorFieldRow] = [
                InspectorFieldRow(title: "Status", value: archiveStatusLabel(info.status)),
                InspectorFieldRow(title: "Queued", value: formattedDate(info.queuedAt)),
            ]
            if let d = info.exportedAt { rows.append(InspectorFieldRow(title: "Exported", value: formattedDate(d))) }
            if let d = info.deletedAt  { rows.append(InspectorFieldRow(title: "Deleted",  value: formattedDate(d))) }
            if let p = info.archivePath, !p.isEmpty { rows.append(InspectorFieldRow(title: "Archive Path", value: p)) }
            if let e = info.lastError,  !e.isEmpty  { rows.append(InspectorFieldRow(title: "Last Error",   value: e)) }
            result.append(InspectorSection(title: "Archive", rows: rows))
        }

        return result
    }

    var title: String {
        guard selectedAsset != nil else { return "" }
        return originalFilename.isEmpty
            ? (selectedAsset?.localIdentifier.split(separator: "/").first.map(String.init) ?? "")
            : originalFilename
    }

    var subtitle: String {
        guard let asset = selectedAsset else { return "" }
        var parts: [String] = []
        if !fileFormat.isEmpty { parts.append(fileFormat) }
        if let bytes = fileSizeBytes, bytes > 0 {
            parts.append(fileSizeText(bytes))
        }
        let dim = dimensionsText(width: asset.pixelWidth, height: asset.pixelHeight)
        if dim != "Unknown" { parts.append(dim) }
        let mp = megapixelsText(width: asset.pixelWidth, height: asset.pixelHeight)
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

            // PHAsset properties
            hasLocation = phAsset.location != nil
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
            requestEXIF(for: phAsset, localIdentifier: localIdentifier)
        }

        // DB reads
        fileSizeBytes = try? model.database.assetRepository.fetchFileSizeBytes(localIdentifier: localIdentifier)
        if let analysis = try? model.database.assetRepository.fetchAnalysisFields(localIdentifier: localIdentifier) {
            overallScore = analysis.overallScore
            aiCaption = analysis.aiCaption ?? ""
            namedPersonCount = analysis.namedPersonCount
            detectedPersonCount = analysis.detectedPersonCount
        }
    }

    private func requestEXIF(for phAsset: PHAsset, localIdentifier: String) {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .fastFormat
        options.isSynchronous = false
        PHImageManager.default().requestImageDataAndOrientation(for: phAsset, options: options) { [weak self] data, _, _, _ in
            guard let self, let data else { return }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
            else { return }

            var aperture = ""
            var shutter = ""
            var iso = ""
            var focal = ""

            if let f = exif[kCGImagePropertyExifFNumber] as? Double {
                aperture = String(format: "f/%.1f", f)
            }
            if let t = exif[kCGImagePropertyExifExposureTime] as? Double, t > 0 {
                shutter = t >= 1 ? String(format: "%.1f s", t) : "1/\(Int((1.0 / t).rounded())) s"
            }
            if let speeds = exif[kCGImagePropertyExifISOSpeedRatings] as? [Int], let first = speeds.first {
                iso = "ISO \(first)"
            }
            if let fl = exif[kCGImagePropertyExifFocalLength] as? Double {
                focal = String(format: "%.0f mm", fl)
            }

            DispatchQueue.main.async { [weak self] in
                guard let self, self.representedPreviewIdentifier == localIdentifier else { return }
                self.exifAperture = aperture
                self.exifShutterSpeed = shutter
                self.exifISO = iso
                self.exifFocalLength = focal
            }
        }
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

private struct InspectorSection: Identifiable {
    let title: String
    let rows: [InspectorFieldRow]

    var id: String { title }
}

private struct InspectorFieldRow: Identifiable {
    let title: String
    let value: String

    var id: String { title }
}

private struct InspectorReadOnlyView: View {
    @ObservedObject var viewModel: InspectorReadOnlyViewModel

    private let topScrollStartInset: CGFloat = 56
    private let contentHorizontalInset: CGFloat = 16
    private let sectionInnerInset: CGFloat = 12

    var body: some View {
        ScrollView {
            if let asset = viewModel.selectedAsset {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(viewModel.title)
                            .font(.title3.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(viewModel.subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, contentHorizontalInset)

                    DisclosureGroup(
                        isExpanded: Binding(
                            get: { !viewModel.isSectionCollapsed("Preview") },
                            set: { _ in viewModel.toggleSection("Preview") }
                        )
                    ) {
                        previewCard
                            .padding(sectionInnerInset)
                            .background(sectionCardBackground)
                    } label: {
                        sectionHeader("Preview")
                    }
                    .padding(.horizontal, contentHorizontalInset)

                    ForEach(viewModel.sections(for: asset)) { section in
                        DisclosureGroup(
                            isExpanded: Binding(
                                get: { !viewModel.isSectionCollapsed(section.title) },
                                set: { _ in viewModel.toggleSection(section.title) }
                            )
                        ) {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(section.rows) { row in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(row.title.uppercased())
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text(row.value)
                                            .font(.body.monospaced())
                                            .foregroundStyle(.primary)
                                            .lineLimit(2)
                                            .truncationMode(.middle)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(sectionInnerInset)
                            .background(sectionCardBackground)
                        } label: {
                            sectionHeader(section.title)
                        }
                        .padding(.horizontal, contentHorizontalInset)
                    }
                }
                .padding(.vertical, 12)
            } else if viewModel.multipleSelectionCount > 1 {
                ContentUnavailableView(
                    "\(viewModel.multipleSelectionCount) Photos Selected",
                    systemImage: "photo.stack",
                    description: Text("Select a single photo to view its metadata.")
                )
                .frame(maxWidth: .infinity)
                .containerRelativeFrame(.vertical, alignment: .center)
            } else {
                ContentUnavailableView(
                    "No Selection",
                    systemImage: "slider.horizontal.3",
                    description: Text("Select a photo to view metadata.")
                )
                .frame(maxWidth: .infinity)
                .containerRelativeFrame(.vertical, alignment: .center)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .contentMargins(.top, topScrollStartInset, for: .scrollContent)
    }

    private var previewCard: some View {
        ZStack {
            if let image = viewModel.previewImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.quaternary.opacity(0.22))
            }
        }
        .frame(height: 220)
        .overlay {
            if viewModel.isPreviewLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var sectionCardBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(.quaternary.opacity(0.35))
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(AppTheme.accentColor)
            .tracking(0.4)
    }
}
