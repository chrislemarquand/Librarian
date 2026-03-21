import AppKit
import SharedUI

@MainActor
enum ArchiveLibraryMismatchPrompt {
    static func resolveWriteGateIfPossible(
        model: AppModel,
        decision: ArchiveWriteGateDecision,
        operation: ArchiveWriteOperation,
        parentWindow: NSWindow?
    ) async -> Bool {
        guard decision.status != .allowed else { return true }

        if await offerKnownCouplingSwitchIfNeeded(model: model, parentWindow: parentWindow) {
            return model.evaluateArchiveWriteGate(for: operation).isAllowed
        }

        if await offerCreateOrSelectIfNoCoupling(model: model, parentWindow: parentWindow) {
            return model.evaluateArchiveWriteGate(for: operation).isAllowed
        }

        return await presentMismatchResolutionPrompt(model: model, operation: operation, parentWindow: parentWindow)
    }

    private static func offerKnownCouplingSwitchIfNeeded(
        model: AppModel,
        parentWindow: NSWindow?
    ) async -> Bool {
        guard let coupledRoot = model.knownCoupledArchiveRootURLForCurrentSystemLibrary() else { return false }
        let currentRoot = ArchiveSettings.restoreArchiveRootURL()
        if currentRoot?.standardizedFileURL == coupledRoot.standardizedFileURL { return false }

        let libraryName = model.currentSystemPhotoLibraryURL?.lastPathComponent ?? "Current Library"
        let archiveName = ArchiveSettings.archiveTreeRootURL(from: coupledRoot).lastPathComponent

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Switched to \(libraryName)"
        alert.informativeText = "Librarian found the archive linked to this library: \"\(archiveName)\".\n\nWould you like to switch to it now?"
        alert.addButton(withTitle: "Switch to Linked Archive")
        alert.addButton(withTitle: "Stay on Current Archive")
        let response = await alert.runSheetOrModal(for: parentWindow)
        guard response == .alertFirstButtonReturn else { return false }

        guard model.updateArchiveRoot(coupledRoot) else { return false }
        model.scheduleSystemPhotoLibraryRefresh(reason: "knownCouplingSwitched", debounceMilliseconds: 0)
        return true
    }

    private static func offerCreateOrSelectIfNoCoupling(
        model: AppModel,
        parentWindow: NSWindow?
    ) async -> Bool {
        guard model.currentSystemPhotoLibraryFingerprint != nil else { return false }
        guard model.knownCouplingForCurrentSystemLibrary() == nil else { return false }

        let libraryName = model.currentSystemPhotoLibraryURL?.lastPathComponent ?? "Current Library"
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "No Archive Linked to This Photo Library"
        alert.informativeText = "You switched to \"\(libraryName)\", but no linked archive was found.\n\nChoose how you want to continue."
        alert.addButton(withTitle: "Create New Archive")
        alert.addButton(withTitle: "Choose Existing Archive")
        alert.addButton(withTitle: "Cancel")

        let response = await alert.runSheetOrModal(for: parentWindow)
        switch response {
        case .alertFirstButtonReturn:
            guard let selected = promptForArchiveRoot(
                title: "Choose New Archive Location",
                message: "Choose a folder for a new Librarian archive.",
                prompt: "Use Location"
            ) else { return false }
            if ArchiveSettings.archiveID(for: selected) == nil,
               !ArchiveRootPrompts.confirmInitializeArchive(at: selected) {
                return false
            }
            guard model.updateArchiveRoot(selected) else { return false }
            return rebindCurrentArchiveToCurrentLibrary(model: model)

        case .alertSecondButtonReturn:
            guard let selected = promptForArchiveRoot(
                title: "Choose Existing Archive",
                message: "Choose the folder for the archive linked to this photo library.",
                prompt: "Use Archive"
            ) else { return false }
            guard model.updateArchiveRoot(selected) else { return false }
            return rebindCurrentArchiveToCurrentLibrary(model: model)

        default:
            return false
        }
    }

    private static func presentMismatchResolutionPrompt(
        model: AppModel,
        operation: ArchiveWriteOperation,
        parentWindow: NSWindow?
    ) async -> Bool {
        let evaluation = model.latestArchiveLibraryBindingEvaluation
        let boundName = displayLibraryName(fromPath: evaluation?.boundLibraryPathHint) ?? "Linked Photo Library"
        let currentName = displayLibraryName(fromPath: model.currentSystemPhotoLibraryURL?.path) ?? "Current System Library"
        let archiveName = displayArchiveName(model: model) ?? "Current Archive"

        let alert = NSAlert()
        switch evaluation?.state {
        case .mismatch:
            alert.alertStyle = .warning
            alert.messageText = "Archive Linked to Different Photo Library"
            alert.informativeText = """
            \(archiveName) is currently linked to:
            \(boundName)

            Current system photo library:
            \(currentName)

            \(operation.displayName.capitalized) is paused to prevent incorrect duplicate handling.
            """
            alert.addButton(withTitle: "Rebind Archive to Current Library")
            alert.addButton(withTitle: "Choose Different Archive")
            alert.addButton(withTitle: "Cancel")

            let response = await alert.runSheetOrModal(for: parentWindow)
            switch response {
            case .alertFirstButtonReturn:
                return rebindCurrentArchiveToCurrentLibrary(model: model)
            case .alertSecondButtonReturn:
                guard let selected = promptForArchiveRoot(
                    title: "Choose Archive",
                    message: "Choose the archive location to use with the current photo library.",
                    prompt: "Use Archive"
                ) else { return false }
                guard model.updateArchiveRoot(selected) else { return false }
                return rebindCurrentArchiveToCurrentLibrary(model: model)
            default:
                return false
            }
        case .unbound:
            alert.alertStyle = .informational
            alert.messageText = "Link Archive to This Photo Library"
            alert.informativeText = """
            \(archiveName) is not yet linked to a photo library.

            Current system photo library:
            \(currentName)
            """
            alert.addButton(withTitle: "Link Now")
            alert.addButton(withTitle: "Choose Different Archive")
            alert.addButton(withTitle: "Cancel")
            let response = await alert.runSheetOrModal(for: parentWindow)
            switch response {
            case .alertFirstButtonReturn:
                return rebindCurrentArchiveToCurrentLibrary(model: model)
            case .alertSecondButtonReturn:
                guard let selected = promptForArchiveRoot(
                    title: "Choose Archive",
                    message: "Choose the archive location to use with the current photo library.",
                    prompt: "Use Archive"
                ) else { return false }
                guard model.updateArchiveRoot(selected) else { return false }
                return rebindCurrentArchiveToCurrentLibrary(model: model)
            default:
                return false
            }
        case .unknown:
            alert.alertStyle = .warning
            alert.messageText = "Couldn’t Verify Active Photo Library"
            alert.informativeText = "Librarian couldn’t verify the active system photo library. \(operation.displayName.capitalized) is paused until this is resolved."
            alert.addButton(withTitle: "OK")
            _ = await alert.runSheetOrModal(for: parentWindow)
            return false
        default:
            return false
        }
    }

    private static func rebindCurrentArchiveToCurrentLibrary(model: AppModel) -> Bool {
        guard let archiveRoot = ArchiveSettings.restoreArchiveRootURL() else { return false }
        guard let library = try? ArchiveSettings.currentPhotoLibraryFingerprint() else { return false }

        let confirm = NSAlert()
        confirm.alertStyle = .warning
        confirm.messageText = "Rebind Archive?"
        confirm.informativeText = "Rebinding changes duplicate detection for future imports. Existing archived files will not be moved or deleted automatically."
        confirm.addButton(withTitle: "Rebind")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return false }

        let updated = ArchiveSettings.updateControlConfig(at: archiveRoot) { config in
            config.photoLibraryBinding = ArchiveSettings.ArchiveControlConfig.PhotoLibraryBinding(
                libraryFingerprint: library.fingerprint,
                libraryIDSource: library.source,
                libraryPathHint: library.pathHint,
                boundAt: Date(),
                bindingMode: .strict,
                lastSeenMatchAt: Date()
            )
            if config.schemaVersion < ArchiveSettings.configSchemaVersion {
                config.schemaVersion = ArchiveSettings.configSchemaVersion
            }
        }
        if updated {
            model.scheduleSystemPhotoLibraryRefresh(reason: "rebindArchive", debounceMilliseconds: 0)
        }
        return updated
    }

    private static func promptForArchiveRoot(title: String, message: String, prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.prompt = prompt
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = ArchiveSettings.restoreArchiveRootURL() ?? FileManager.default.homeDirectoryForCurrentUser
        guard panel.runModal() == .OK else { return nil }
        return panel.url?.standardizedFileURL
    }

    private static func displayLibraryName(fromPath path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return name.isEmpty ? nil : name
    }

    private static func displayArchiveName(model: AppModel) -> String? {
        if let root = ArchiveSettings.restoreArchiveRootURL() {
            let base = root.lastPathComponent
            if !base.isEmpty { return base }
        }
        return ArchiveSettings.currentArchiveTreeRootURL()?.lastPathComponent
    }
}
