import AppKit
import SharedUI

@MainActor
final class WelcomeScreenCoordinator {

    private let model: AppModel
    private let onComplete: () -> Void

    init(model: AppModel, onComplete: @escaping () -> Void) {
        self.model = model
        self.onComplete = onComplete
    }

    func makePresentation() -> AppWelcomePresentation {
        AppWelcomePresentation(
            appName: AppBrand.displayName,
            features: Self.features,
            primaryButtonTitle: "Get Started",
            secondaryButtonTitle: "Choose Archive Location…",
            onPrimaryAction: { [weak self] in self?.handleGetStarted() },
            onSecondaryAction: { [weak self] in self?.chooseArchiveLocation() }
        )
    }

    // MARK: - Features

    private static let features: [AppWelcomeFeature] = [
        AppWelcomeFeature(
            symbolName: "square.grid.2x2.fill",
            title: "Sorted review boxes",
            subtitle: "Duplicates, screenshots, WhatsApp photos, documents, and more — automatically identified and grouped so you know what needs attention."
        ),
        AppWelcomeFeature(
            symbolName: "checkmark.shield.fill",
            title: "Archive, don't delete",
            subtitle: "Photos are exported to your Archive and verified before leaving your library. Nothing is removed without your say-so."
        ),
        AppWelcomeFeature(
            symbolName: "tray.and.arrow.down.fill",
            title: "Work at your own pace",
            subtitle: "Set photos aside as you browse, then send them to your Archive in one go whenever you're ready."
        ),
        AppWelcomeFeature(
            symbolName: "wand.and.sparkles",
            title: "Library analysis",
            subtitle: "Run an analysis pass to score photo quality, detect near-duplicates, and unlock the Low Quality box."
        ),
    ]

    // MARK: - Actions

    private func chooseArchiveLocation() {
        let panel = NSOpenPanel()
        panel.prompt = "Choose Folder"
        panel.message = "Choose where Librarian should export archived photos."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        guard panel.runModal() == .OK, let url = panel.url?.standardizedFileURL else { return }
        let resolved = ArchiveSettings.resolveArchiveRoot(fromUserSelection: url) ?? url
        _ = model.updateArchiveRoot(resolved)
    }

    private func handleGetStarted() {
        AppDelegate.markWelcomeScreenComplete()
        model.scheduleAnalysisAfterInitialIndex()
        onComplete()
    }
}
