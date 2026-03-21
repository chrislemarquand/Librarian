import AppKit
import SwiftUI

@MainActor
final class ArchiveImportSheetPresenter {
    private let model: AppModel
    private let parentWindowProvider: () -> NSWindow?
    private let onDismiss: () -> Void
    private var sheetWindow: NSWindow?

    init(
        model: AppModel,
        parentWindowProvider: @escaping () -> NSWindow?,
        onDismiss: @escaping () -> Void
    ) {
        self.model = model
        self.parentWindowProvider = parentWindowProvider
        self.onDismiss = onDismiss
    }

    func present(mode: ArchiveImportSheetMode) {
        guard sheetWindow == nil else { return }
        guard let parent = parentWindowProvider() else { return }
        let gate = model.evaluateArchiveWriteGate(for: .importIntoArchive)
        guard gate.isAllowed else {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let resolved = await ArchiveLibraryMismatchPrompt.resolveWriteGateIfPossible(
                    model: self.model,
                    decision: gate,
                    operation: .importIntoArchive,
                    parentWindow: parent
                )
                guard resolved else { return }
                self.present(mode: mode)
            }
            return
        }

        let sheetView = ArchiveImportSheetView(model: model, mode: mode) { [weak self] in
            self?.dismiss()
        }
        let hostingController = NSHostingController(rootView: sheetView)
        let window = NSWindow(contentViewController: hostingController)
        window.styleMask = [.titled, .closable]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isReleasedWhenClosed = false

        sheetWindow = window
        parent.beginSheet(window)
    }

    func dismiss() {
        guard let parent = parentWindowProvider(), let sheetWindow else { return }
        parent.endSheet(sheetWindow)
        self.sheetWindow = nil
        onDismiss()
    }
}
