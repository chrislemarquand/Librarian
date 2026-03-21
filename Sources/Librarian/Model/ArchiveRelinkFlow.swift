import AppKit
import SharedUI

/// Runs the archive relink flow: alert → folder picker → root resolution → update.
/// Called when the app detects at launch that the configured archive root is unavailable.
@MainActor
func runArchiveRelinkFlow(model: AppModel, presentingWindow: NSWindow?) async {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Archive Not Found"
    alert.informativeText = "Librarian can't find your archive at its last known location. It may have been moved or renamed.\n\nLocate it to continue using your archive."
    alert.addButton(withTitle: "Locate Archive…")
    alert.addButton(withTitle: "Not Now")
    let response = await alert.runSheetOrModal(for: presentingWindow)
    guard response == .alertFirstButtonReturn else { return }

    let panel = NSOpenPanel()
    panel.title = "Locate Archive"
    panel.message = "Select your archive folder, or the folder containing it."
    panel.prompt = "Locate"
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false
    panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser

    guard panel.runModal() == .OK, let selectedURL = panel.url else { return }

    guard let resolvedRoot = resolveArchiveRoot(from: selectedURL) else {
        let errorAlert = NSAlert()
        errorAlert.alertStyle = .warning
        errorAlert.messageText = "Archive Not Recognised"
        errorAlert.informativeText = "The selected folder doesn't appear to contain a Librarian archive. Select the archive folder itself, or its parent folder."
        errorAlert.addButton(withTitle: "OK")
        _ = await errorAlert.runSheetOrModal(for: presentingWindow)
        return
    }

    guard model.updateArchiveRoot(resolvedRoot) else {
        let errorAlert = NSAlert()
        errorAlert.alertStyle = .warning
        errorAlert.messageText = "Could Not Relink Archive"
        errorAlert.informativeText = "Librarian was unable to save the new archive location."
        errorAlert.addButton(withTitle: "OK")
        _ = await errorAlert.runSheetOrModal(for: presentingWindow)
        return
    }
}

/// Resolves the archive root URL from a user-selected folder.
/// Accepts either the parent folder (e.g. `Testing/`) or the `Archive/` subfolder directly.
private func resolveArchiveRoot(from selectedURL: URL) -> URL? {
    // Case 1: user selected the parent (Testing/) — archiveID looks inside Testing/Archive/.librarian/
    if ArchiveSettings.archiveID(for: selectedURL) != nil {
        return selectedURL
    }
    // Case 2: user selected the Archive/ subfolder directly — check its parent
    let parent = selectedURL.deletingLastPathComponent()
    if selectedURL.lastPathComponent == ArchiveSettings.archiveFolderName,
       ArchiveSettings.archiveID(for: parent) != nil {
        return parent
    }
    return nil
}
