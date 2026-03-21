import AppKit
import SharedUI

final class BoxesSettingsViewController: SettingsGridViewController {
    private let model: AppModel

    /// All boxes that support keep decisions, derived from the sidebar's canonical item list.
    /// Adding a new box to `SidebarItem.baseItems` with a non-nil `keepDecisionKind`
    /// automatically adds a reset row here — no further changes required.
    private static var boxes: [(title: String, keepDecisionKind: String)] {
        SidebarItem.items(in: .queues).compactMap { item in
            guard let kind = item.keepDecisionKind else { return nil }
            return (title: item.title, keepDecisionKind: kind)
        }
    }

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func makeRows() -> [[NSView]] {
        var rows: [[NSView]] = []

        let headerNote = makeDescriptionLabel("Reset which items have been marked Keep in each box.")
        rows.append([makeCategoryLabel(title: "Keep decisions:"), headerNote, NSView()])

        for (index, box) in Self.boxes.enumerated() {
            let count = (try? model.database.assetRepository?.countKeepDecisions(for: box.keepDecisionKind)) ?? 0
            let countLabel = makeDescriptionLabel(count == 0 ? "No items kept" : "\(count) kept")
            let button = makeActionButton(title: "Reset", action: #selector(resetKeepDecisions(_:)))
            button.tag = index
            button.isEnabled = count > 0
            rows.append([makeCategoryLabel(title: "\(box.title):"), countLabel, button])
        }

        return rows
    }

    @objc private func resetKeepDecisions(_ sender: NSButton) {
        let boxes = Self.boxes
        guard sender.tag < boxes.count else { return }
        let kind = boxes[sender.tag].keepDecisionKind
        do {
            try model.database.assetRepository.clearKeepDecisions(for: kind)
            NotificationCenter.default.post(name: .librarianIndexingStateChanged, object: nil)
            rebuildGrid()
        } catch {
            AppLog.shared.error("Failed to reset keep decisions for \(kind): \(error.localizedDescription)")
        }
    }
}
