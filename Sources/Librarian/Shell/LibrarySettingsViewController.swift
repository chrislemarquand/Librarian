import AppKit
import SharedUI

final class LibrarySettingsViewController: SettingsGridViewController {
    private let model: AppModel

    // Persistent controls — reused across grid rebuilds so notification handlers
    // can update them without rebuilding the whole grid.
    private lazy var rebuildButton = makeActionButton(title: "Rebuild Index", action: #selector(rebuildIndex))
    private lazy var rebuildStatusLabel = makeDescriptionLabel("Runs a full library scan and refreshes the local index.")
    private lazy var analyseButton = makeActionButton(title: "Analyse Library", action: #selector(analyseLibrary))
    private lazy var analyseStatusLabel = makeDescriptionLabel("Imports quality scores, file sizes, labels, and duplicate fingerprints.")
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
            [makeCategoryLabel(title: "Index:"),            rebuildStatusLabel,  rebuildButton],
            [makeCategoryLabel(title: "Library analysis:"), analyseStatusLabel,  analyseButton],
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
        rebuildButton.title = model.isIndexing ? "Rebuilding…" : "Rebuild Index"
        rebuildStatusLabel.stringValue = model.isIndexing
            ? (model.indexingProgress.statusText.isEmpty ? "Running…" : model.indexingProgress.statusText)
            : "Runs a full library scan and refreshes the local index."
    }

    private func refreshAnalyseButtonState() {
        analyseButton.isEnabled = !model.isAnalysing
        analyseButton.title = model.isAnalysing ? "Analysing…" : "Analyse Library"
        analyseStatusLabel.stringValue = model.isAnalysing
            ? (model.analysisStatusText.isEmpty ? "Running…" : model.analysisStatusText)
            : "Imports quality scores, file sizes, labels, and duplicate fingerprints."
    }
}
