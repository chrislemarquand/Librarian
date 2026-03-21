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

            If this is the moved location of your current archive, choose Cancel and select that folder instead.

            Current archive reference: \(fromArchiveID)
            Selected archive reference: \(toArchiveID)
            """
        alert.addButton(withTitle: "Switch Archive")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func confirmInitializeArchive(at url: URL) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Create New Archive Here?"
        alert.informativeText =
            """
            Librarian will create its hidden support files in:
            \(url.path)

            This marks the location as a Librarian archive.
            """
        alert.addButton(withTitle: "Create and Use")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
