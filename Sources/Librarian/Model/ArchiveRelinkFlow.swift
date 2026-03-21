import AppKit
import SharedUI

/// Runs the archive relink flow: alert → folder picker → root resolution → update.
/// Called when the app detects at launch that the configured archive root is unavailable.
@MainActor
func runArchiveRelinkFlow(model: AppModel, presentingWindow: NSWindow?) async {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Archive Not Found"
    alert.informativeText = "Librarian can’t find your archive in its last known location. It may have been moved, renamed, deleted, or disconnected.\n\nLocate it, or create a new archive."
    alert.addButton(withTitle: "Locate Archive…")
    alert.addButton(withTitle: "Create New Archive…")
    alert.addButton(withTitle: "Not Now")
    let response = await alert.runSheetOrModal(for: presentingWindow)
    if response == .alertSecondButtonReturn {
        await runNewArchiveFlow(model: model, presentingWindow: presentingWindow)
        return
    }
    guard response == .alertFirstButtonReturn else { return }

    let panel = NSOpenPanel()
    panel.title = "Locate Archive"
    panel.message = "Select your archive folder, or the folder that contains it."
    panel.prompt = "Choose Folder"
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false
    panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser

    guard panel.runModal() == .OK, let selectedURL = panel.url else { return }

    guard let resolvedRoot = ArchiveSettings.resolveArchiveRoot(fromUserSelection: selectedURL) else {
        let errorAlert = NSAlert()
        errorAlert.alertStyle = .warning
        errorAlert.messageText = "Archive Not Recognized"
        errorAlert.informativeText = "The selected folder does not appear to contain a Librarian archive. Select the archive folder itself, or its parent folder."
        errorAlert.addButton(withTitle: "OK")
        _ = await errorAlert.runSheetOrModal(for: presentingWindow)
        return
    }

    guard model.updateArchiveRoot(resolvedRoot) else {
        let errorAlert = NSAlert()
        errorAlert.alertStyle = .warning
        errorAlert.messageText = "Couldn’t Link Archive"
        errorAlert.informativeText = "Librarian was unable to save the new archive location."
        errorAlert.addButton(withTitle: "OK")
        _ = await errorAlert.runSheetOrModal(for: presentingWindow)
        return
    }
}

@MainActor
private func runNewArchiveFlow(model: AppModel, presentingWindow: NSWindow?) async {
    let panel = NSOpenPanel()
    panel.title = "Create New Archive"
    panel.message = "Choose a folder for a new Librarian archive."
    panel.prompt = "Choose Folder"
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser

    guard panel.runModal() == .OK, let selectedURL = panel.url?.standardizedFileURL else { return }
    let rootURL = normalizeRootForNewArchiveSelection(selectedURL)

    if ArchiveSettings.archiveID(for: rootURL) == nil,
       !ArchiveRootPrompts.confirmInitializeArchive(at: rootURL) {
        return
    }

    guard model.updateArchiveRoot(rootURL) else {
        let errorAlert = NSAlert()
        errorAlert.alertStyle = .warning
        errorAlert.messageText = "Couldn’t Create Archive"
        errorAlert.informativeText = "Librarian was unable to save the new archive location."
        errorAlert.addButton(withTitle: "OK")
        _ = await errorAlert.runSheetOrModal(for: presentingWindow)
        return
    }
}

private func normalizeRootForNewArchiveSelection(_ selected: URL) -> URL {
    guard selected.lastPathComponent == ArchiveSettings.archiveFolderName else {
        return selected
    }
    return selected.deletingLastPathComponent().standardizedFileURL
}
