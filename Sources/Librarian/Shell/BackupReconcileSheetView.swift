import AppKit
import Combine
import SwiftUI
import SharedUI

// MARK: - Session

@MainActor
final class BackupReconcileSession: ObservableObject {
    @Published var backupFolder: URL?
    @Published var isBusy = false
    @Published var runError: String?
    @Published var preflight: BackupReconcilePreflightResult?
    @Published var summary: BackupReconcileRunSummary?

    var folderDisplayText: String {
        backupFolder?.path ?? "No backup folder selected."
    }

    var detailsText: String {
        var lines: [String] = ["Backup Reconcile"]
        if let backupFolder {
            lines.append("Backup folder: \(backupFolder.path)")
        }
        if let preflight {
            lines.append("")
            lines.append("Preflight")
            lines.append("- Discovered: \(preflight.totalDiscovered)")
            lines.append("- Still in Photos Library: \(preflight.stillInLibrary)")
            lines.append("- Already in Archive: \(preflight.alreadyInArchive)")
            lines.append("- No UUID record: \(preflight.noUUIDCount)")
            lines.append("- To archive: \(preflight.toArchive)")
            if !preflight.hasExportDatabase {
                lines.append("- Warning: no .osxphotos_export.db found; matched by file content only")
            }
        }
        if let summary {
            lines.append("")
            lines.append("Run Summary")
            lines.append("- Archived: \(summary.archived)")
            lines.append("- Skipped (still in library): \(summary.skippedInLibrary)")
            lines.append("- Skipped (already in archive): \(summary.skippedInArchive)")
            lines.append("- Failed: \(summary.failed)")
            if !summary.failures.isEmpty {
                lines.append("")
                lines.append("Failures")
                lines.append(contentsOf: summary.failures.map { "- \($0.path): \($0.reason)" })
            }
        }
        if let runError {
            lines.append("")
            lines.append("Error")
            lines.append(runError)
        }
        return lines.count > 1 ? lines.joined(separator: "\n") : ""
    }

    func chooseBackupFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Backup Folder"
        panel.message = "Choose an osxphotos backup folder to reconcile against your Photos library."
        panel.prompt = "Choose Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        guard panel.runModal() == .OK, let url = panel.url else { return }
        backupFolder = url
        preflight = nil
        summary = nil
        runError = nil
    }

    func run(model: AppModel) async {
        guard !isBusy else { return }
        guard let backupFolder else {
            runError = "Choose a backup folder first."
            return
        }

        isBusy = true
        runError = nil
        preflight = nil
        summary = nil
        defer { isBusy = false }

        guard let archiveRoot = ArchiveSettings.restoreArchiveRootURL() else {
            runError = "No Archive location is configured."
            return
        }

        let coordinator = BackupReconcileCoordinator(
            backupFolder: backupFolder,
            archiveRoot: archiveRoot,
            photosService: model.photosService,
            database: model.database
        )

        let preflightResult: BackupReconcilePreflightResult
        do {
            preflightResult = try await Task.detached(priority: .utility) {
                try await coordinator.runPreflight()
            }.value
            self.preflight = preflightResult
        } catch {
            runError = error.localizedDescription
            model.setStatusMessage("Reconcile preflight failed. \(error.localizedDescription)")
            return
        }

        if !preflightResult.hasExportDatabase {
            AppLog.shared.info("BackupReconcile: no .osxphotos_export.db found in \(backupFolder.path); falling back to content-based matching.")
        }

        guard preflightResult.toArchive > 0 else {
            model.setStatusMessage("Nothing to move — all photos are still in your library or already in the Archive.", autoClearAfterSuccess: true)
            return
        }

        do {
            let result = try await model.runBackupReconcile(backupFolder: backupFolder, preflight: preflightResult)
            self.summary = result
            if result.failed > 0 {
                model.setStatusMessage("Reconcile completed with \(result.failed.formatted()) failures.")
            } else {
                model.setStatusMessage("Reconcile complete: \(result.archived.formatted()) photos archived.", autoClearAfterSuccess: true)
            }
        } catch {
            runError = error.localizedDescription
            model.setStatusMessage("Reconcile failed. \(error.localizedDescription)")
        }
    }
}

// MARK: - Sheet view

struct BackupReconcileSheetView: View {
    @ObservedObject var model: AppModel
    let onClose: () -> Void

    @StateObject private var session = BackupReconcileSession()
    @State private var showDetails = false
    private static let sectionSpacing = WorkflowSheetSectionSpacing.uniform(20)

    var body: some View {
        WorkflowSheetContainer(
            title: "Import Photos into Archive from Backup",
            infoText: "Choose an osxphotos backup folder. Photos no longer in your Photos Library will be moved into the Archive. Photos still in your library are left untouched.",
            sectionSpacing: Self.sectionSpacing
        ) {
            VStack(alignment: .leading, spacing: 0) {
                // Folder section
                HStack {
                    TextField("", text: Binding(
                        get: { session.folderDisplayText },
                        set: { _ in }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .disabled(true)

                    Button("Choose…") {
                        session.chooseBackupFolder()
                    }
                    .disabled(session.isBusy)
                }
                .padding(.bottom, Self.sectionSpacing.topToMain)

                // Status section
                VStack(alignment: .leading, spacing: 12) {
                    if let banner = activeBanner {
                        WorkflowInlineMessageBanner(messages: banner)
                    }

                    ProgressView()
                        .progressViewStyle(.linear)
                        .opacity(session.isBusy ? 1 : 0)
                }
                .padding(.bottom, Self.sectionSpacing.mainToFooter)

                // Footer section
                HStack {
                    Button("Details…") {
                        showDetails = true
                    }
                    .disabled(session.detailsText.isEmpty)
                    .popover(isPresented: $showDetails) {
                        WorkflowDetailsPopover(text: session.detailsText)
                    }

                    Spacer()

                    if !isComplete {
                        Button("Cancel") {
                            onClose()
                        }
                        .keyboardShortcut(.cancelAction)
                    }

                    Button(isComplete ? "Close" : "Reconcile") {
                        if isComplete {
                            onClose()
                        } else {
                            Task { await session.run(model: model) }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(session.isBusy || (!isComplete && session.backupFolder == nil))
                }
            }
        }
    }

    private var isComplete: Bool {
        session.summary != nil
            || session.runError != nil
            || (session.preflight?.toArchive == 0 && session.preflight != nil)
    }

    private var activeBanner: [String]? {
        if let runError = session.runError {
            return [runError]
        }
        if let preflight = session.preflight {
            if preflight.toArchive == 0 {
                return ["Nothing to move — all photos are still in your library or already in the Archive."]
            }
            if !preflight.hasExportDatabase {
                return ["No osxphotos database found. Matching by file content only — this may be slower and less accurate."]
            }
        }
        if let summary = session.summary {
            if summary.failed > 0 {
                return ["Archived \(summary.archived). \(summary.failed) failed — review Details for paths."]
            }
            return ["Archived \(summary.archived) photos into the Archive."]
        }
        return nil
    }
}

// MARK: - Presenter

@MainActor
final class BackupReconcileSheetPresenter {
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

    func present() {
        guard sheetWindow == nil else { return }
        guard let parent = parentWindowProvider() else { return }
        guard model.archiveRootAvailability == .available else { return }

        let sheetView = BackupReconcileSheetView(model: model) { [weak self] in
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
