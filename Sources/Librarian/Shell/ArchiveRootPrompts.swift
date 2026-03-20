import AppKit

@MainActor
enum ArchiveRootPrompts {
    static func confirmArchiveSwitch(fromArchiveID: String, toArchiveID: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Switch to a Different Archive?"
        alert.informativeText =
            """
            The selected folder appears to be a different Librarian archive.

            Current archive ID: \(fromArchiveID)
            Selected archive ID: \(toArchiveID)

            If this folder is the moved location of your current archive, choose Cancel and select that folder instead.
            """
        alert.addButton(withTitle: "Switch Archive")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func confirmInitializeArchive(at url: URL) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Initialize New Archive Here?"
        alert.informativeText =
            """
            Librarian will create a hidden .librarian control folder in:
            \(url.path)

            This marks the location as a Librarian archive root.
            """
        alert.addButton(withTitle: "Initialize and Use")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
