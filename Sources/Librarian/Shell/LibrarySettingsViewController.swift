import AppKit
import SharedUI

final class LibrarySettingsViewController: SettingsGridViewController {
    private let model: AppModel

    // Persistent controls — reused across grid rebuilds so notification handlers
    // can update them without rebuilding the whole grid.
    private lazy var rebuildButton = makeActionButton(title: "Update Catalogue", action: #selector(rebuildIndex))
    private lazy var rebuildStatusLabel = makeDescriptionLabel("Scans your Photos Library and updates your Catalogue.")
    private lazy var analyseButton = makeActionButton(title: "Analyse Library", action: #selector(analyseLibrary))
    private lazy var analyseStatusLabel = makeDescriptionLabel("Finds documents, low quality photos and duplicates in your library.")
    private lazy var showInFinderButton = makeActionButton(title: "Show in Finder", action: #selector(showLibraryInFinder))

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(
            self, selector: #selector(indexingStateChanged),
            name: .librarianIndexingStateChanged, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(analysisStateChanged),
            name: .librarianAnalysisStateChanged, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(systemLibraryChanged),
            name: .librarianSystemPhotoLibraryChanged, object: nil
        )
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        refreshRebuildButtonState()
        refreshAnalyseButtonState()
        model.scheduleSystemPhotoLibraryRefresh(reason: "settingsOpened", debounceMilliseconds: 0)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func makeRows() -> [[NSView]] {
        var rows: [[NSView]] = []

        if let libraryURL = model.currentSystemPhotoLibraryURL ?? Self.findPhotosLibraryURL() {
            rows.append([makeCategoryLabel(title: "Library Location:"), makePathControl(url: libraryURL), NSView()])
            rows.append([NSView(), showInFinderButton, NSView()])
        } else {
            rows.append([
                makeCategoryLabel(title: "Library Location:"),
                makeDescriptionLabel("Current System Library"),
                NSView()
            ])
        }

        rows += [
            [makeCategoryLabel(title: "Catalogue:"),        rebuildStatusLabel,  rebuildButton],
            [makeCategoryLabel(title: "Analysis:"),         analyseStatusLabel,  analyseButton],
        ]

        return rows
    }

    // MARK: - Library location

    private static func findPhotosLibraryURL() -> URL? {
        guard let picturesURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first,
              let contents = try? FileManager.default.contentsOfDirectory(
                at: picturesURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
              ) else { return nil }
        return contents.first { $0.pathExtension == "photoslibrary" }
    }

    // MARK: - Actions

    @objc private func showLibraryInFinder() {
        guard let url = model.currentSystemPhotoLibraryURL ?? Self.findPhotosLibraryURL() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func rebuildIndex() {
        refreshRebuildButtonState()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.model.rebuildIndexManually()
            self.refreshRebuildButtonState()
        }
    }

    @objc private func analyseLibrary() {
        refreshAnalyseButtonState()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.model.runLibraryAnalysis()
            self.refreshAnalyseButtonState()
        }
    }

    // MARK: - Notification handlers

    @objc private func indexingStateChanged() { refreshRebuildButtonState() }
    @objc private func analysisStateChanged()  { refreshAnalyseButtonState() }
    @objc private func systemLibraryChanged()  { rebuildGrid() }

    // MARK: - State refresh

    private func refreshRebuildButtonState() {
        rebuildButton.isEnabled = !model.isIndexing
        rebuildButton.title = model.isIndexing ? "Updating Catalogue…" : "Update Catalogue"
        rebuildStatusLabel.stringValue = model.isIndexing
            ? (model.indexingProgress.statusText.isEmpty ? "Updating…" : model.indexingProgress.statusText)
            : "Scans your Photos Library and updates your Catalogue."
    }

    private func refreshAnalyseButtonState() {
        analyseButton.isEnabled = !model.isAnalysing
        analyseButton.title = model.isAnalysing ? "Analysing…" : "Analyse Library"
        if model.isAnalysing {
            analyseStatusLabel.stringValue = model.analysisStatusText.isEmpty ? "Analysing…" : model.analysisStatusText
        } else {
            let base = "Finds documents, low quality photos and duplicates in your library"
            if model.pendingAnalysisCount > 0 {
                analyseStatusLabel.stringValue = "\(base) · \(model.pendingAnalysisCount.formatted()) pending"
            } else if model.analysisHasRunBefore {
                let dateSuffix = lastAnalysedDateString().map { " · Last run \($0)" } ?? ""
                analyseStatusLabel.stringValue = "\(base)\(dateSuffix)"
            } else {
                analyseStatusLabel.stringValue = base
            }
        }
    }

    private func lastAnalysedDateString() -> String? {
        guard let date = try? model.database.assetRepository?.lastAnalysedDate() else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
