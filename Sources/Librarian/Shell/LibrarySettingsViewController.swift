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

    private static let queues: [(title: String, kind: String)] = [
        ("Screenshots", "screenshots"),
        ("Low Quality", "lowQuality"),
        ("Documents", "receiptsAndDocuments"),
        ("Duplicates", "duplicates"),
    ]

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
        var rows: [[NSView]] = [
            [makeCategoryLabel(title: "Index:"),            rebuildStatusLabel,  rebuildButton],
            [makeCategoryLabel(title: "Library analysis:"), analyseStatusLabel,  analyseButton],
        ]

        let keepsNote = makeDescriptionLabel("Reset which items have been marked Keep in each box.")
        rows.append([makeCategoryLabel(title: "Box keep decisions:"), keepsNote, NSView()])

        for (index, queue) in Self.queues.enumerated() {
            let count = (try? model.database.assetRepository?.countKeepDecisions(for: queue.kind)) ?? 0
            let countLabel = makeDescriptionLabel(count == 0 ? "No items kept" : "\(count) kept")
            let button = makeActionButton(title: "Reset", action: #selector(resetKeepDecisions(_:)))
            button.tag = index
            button.isEnabled = count > 0
            rows.append([makeCategoryLabel(title: "\(queue.title):"), countLabel, button])
        }

        return rows
    }

    // MARK: - Actions

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

    @objc private func resetKeepDecisions(_ sender: NSButton) {
        guard sender.tag < Self.queues.count else { return }
        let kind = Self.queues[sender.tag].kind
        do {
            try model.database.assetRepository.clearKeepDecisions(for: kind)
            NotificationCenter.default.post(name: .librarianIndexingStateChanged, object: nil)
            rebuildGrid()
        } catch {
            AppLog.shared.error("Failed to reset keep decisions for \(kind): \(error.localizedDescription)")
        }
    }

    // MARK: - Notification handlers

    @objc private func indexingStateChanged() { refreshRebuildButtonState() }
    @objc private func analysisStateChanged()  { refreshAnalyseButtonState() }

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
