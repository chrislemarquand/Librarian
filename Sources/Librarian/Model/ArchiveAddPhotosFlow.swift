import AppKit
import SharedUI

/// Runs the full "Add Photos to Archive" flow:
/// source folder picker → preflight → confirmation → import → completion.
/// Requires an archive root to already be configured. Safe to call from
/// any @MainActor context; handles its own busy-guard via model.isImportingArchive.
@MainActor
func runAddPhotosToArchiveFlow(model: AppModel, presentingWindow: NSWindow?) async {
    guard !model.isImportingArchive else { return }

    guard let archiveRoot = ArchiveSettings.restoreArchiveRootURL() else {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "No Archive Configured"
        alert.informativeText = "Choose an archive location in Settings before adding photos."
        alert.addButton(withTitle: "OK")
        await alert.runSheetOrModal(for: presentingWindow)
        return
    }

    // 1. Source folder picker
    let panel = NSOpenPanel()
    panel.title = "Choose Source Folders"
    panel.message = "Choose one or more folders whose photos will be copied into the archive. These folders will not be modified."
    panel.prompt = "Choose Folders"
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = true
    panel.canCreateDirectories = false
    panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
    guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
    let sourceFolders = panel.urls

    // 2. Preflight
    let coordinator = ArchiveImportCoordinator(
        archiveRoot: archiveRoot,
        sourceFolders: sourceFolders,
        database: model.database,
        photosService: model.photosService
    )
    let preflight: ArchiveImportPreflightResult
    do {
        preflight = try await Task.detached(priority: .utility) {
            try await coordinator.runPreflight()
        }.value
    } catch {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Scan Failed"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        await alert.runSheetOrModal(for: presentingWindow)
        return
    }

    // 3. Preflight confirmation
    guard await showAddPhotosPreflightConfirmation(preflight: preflight, window: presentingWindow) else { return }
    guard preflight.toImport > 0 else { return }

    // 4. Import
    let summary: ArchiveImportRunSummary
    do {
        summary = try await model.runArchiveImport(sourceFolders: sourceFolders, preflight: preflight)
    } catch {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Import Failed"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        await alert.runSheetOrModal(for: presentingWindow)
        return
    }

    // 5. Completion
    showAddPhotosCompletion(summary: summary, window: presentingWindow)
}

@MainActor
private func showAddPhotosPreflightConfirmation(
    preflight: ArchiveImportPreflightResult,
    window: NSWindow?
) async -> Bool {
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = "Add Photos to Archive?"

    var lines: [String] = ["\(preflight.totalDiscovered.formatted()) photos discovered."]
    if preflight.duplicatesInSource > 0 {
        lines.append("• \(preflight.duplicatesInSource.formatted()) duplicate photos within source folders will be skipped.")
    }
    if preflight.existsInPhotoKit > 0 {
        lines.append("• \(preflight.existsInPhotoKit.formatted()) photos already in your Photos library will be skipped.")
    }
    lines.append("")
    lines.append(preflight.toImport > 0
        ? "\(preflight.toImport.formatted()) photos will be copied into the archive."
        : "Nothing to import — all photos are duplicates or already in Photos.")
    alert.informativeText = lines.joined(separator: "\n")
    alert.addButton(withTitle: preflight.toImport > 0 ? "Add Photos" : "OK")
    if preflight.toImport > 0 { alert.addButton(withTitle: "Cancel") }

    let response = await alert.runSheetOrModal(for: window)
    return response == .alertFirstButtonReturn && preflight.toImport > 0
}

@MainActor
private func showAddPhotosCompletion(summary: ArchiveImportRunSummary, window: NSWindow?) {
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = "Photos Added"

    var lines: [String] = ["\(summary.imported.formatted()) photos copied into the archive."]
    if summary.skippedDuplicateInSource > 0 {
        lines.append("• \(summary.skippedDuplicateInSource.formatted()) duplicates in source folders skipped.")
    }
    if summary.skippedExistsInPhotoKit > 0 {
        lines.append("• \(summary.skippedExistsInPhotoKit.formatted()) photos already in Photos skipped.")
    }
    if summary.failed > 0 {
        lines.append("• \(summary.failed.formatted()) photos failed — check the log for details.")
    }
    alert.informativeText = lines.joined(separator: "\n")
    alert.addButton(withTitle: "Done")
    alert.runSheetOrModal(for: window) { _ in }
}
