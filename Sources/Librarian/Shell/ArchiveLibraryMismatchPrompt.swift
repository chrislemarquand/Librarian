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
        let state = decision.evaluation?.state

        // Coupling-switch/create-select prompts are only valid when we have a real
        // mismatch to resolve. Do not show them for unbound/unknown bootstrap states.
        if state == .mismatch {
            if await offerKnownCouplingSwitchIfNeeded(model: model, parentWindow: parentWindow) {
                return model.evaluateArchiveWriteGate(for: operation).isAllowed
            }

            if await offerCreateOrSelectIfNoCoupling(model: model, parentWindow: parentWindow) {
                return model.evaluateArchiveWriteGate(for: operation).isAllowed
            }
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

        let libraryName = displayLibraryName(fromURL: model.currentSystemPhotoLibraryURL)
        let archiveName = ArchiveSettings.archiveTreeRootURL(from: coupledRoot).lastPathComponent

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = libraryName.map { "Switched to \($0)" } ?? "System Photo Library Changed"
        alert.informativeText = "Librarian found the archive linked to this library: \"\(archiveName)\".\n\nSwitch to it now?"
        alert.addButton(withTitle: "Switch to Linked Archive")
        alert.addButton(withTitle: "Keep Current Archive")
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

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "No Archive Linked to This Library"
        if let libraryName = displayLibraryName(fromURL: model.currentSystemPhotoLibraryURL) {
            alert.informativeText = "You switched to \"\(libraryName)\", but no linked archive was found.\n\nChoose how to continue."
        } else {
            alert.informativeText = "No linked archive was found for the active system photo library.\n\nChoose how to continue."
        }
        alert.addButton(withTitle: "Create New Archive")
        alert.addButton(withTitle: "Choose Existing Archive")
        alert.addButton(withTitle: "Cancel")

        let response = await alert.runSheetOrModal(for: parentWindow)
        switch response {
        case .alertFirstButtonReturn:
            guard let selected = promptForArchiveRoot(
                title: "Choose New Archive Location",
                message: "Choose a folder for a new Librarian archive.",
                prompt: "Use Location",
                mode: .newLocation
            ) else { return false }
            if ArchiveSettings.archiveID(for: selected) == nil,
               !ArchiveRootPrompts.confirmInitializeArchive(at: selected) {
                return false
            }
            guard model.updateArchiveRoot(selected) else { return false }
            return linkCurrentArchiveToCurrentLibrary(model: model)

        case .alertSecondButtonReturn:
            guard let selected = promptForArchiveRoot(
                title: "Choose Existing Archive",
                message: "Choose the folder for the archive linked to this photo library.",
                prompt: "Use Archive",
                mode: .existingOnly
            ) else { return false }
            guard model.updateArchiveRoot(selected) else { return false }
            return linkCurrentArchiveToCurrentLibrary(model: model)

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
        let boundName = displayLibraryName(fromPath: evaluation?.boundLibraryPathHint)
        let currentName = displayLibraryName(fromURL: model.currentSystemPhotoLibraryURL)
        let archiveName = displayArchiveName(model: model) ?? "Current Archive"

        let alert = NSAlert()
        switch evaluation?.state {
        case .mismatch:
            alert.alertStyle = .warning
            alert.messageText = "Archive Linked to Different Photo Library"
            alert.informativeText = mismatchInformativeText(
                archiveName: archiveName,
                boundLibraryName: boundName,
                currentLibraryName: currentName,
                operation: operation
            )
            alert.addButton(withTitle: "Link Archive to Current Library")
            alert.addButton(withTitle: "Choose Different Archive")
            alert.addButton(withTitle: "Cancel")

            let response = await alert.runSheetOrModal(for: parentWindow)
            switch response {
            case .alertFirstButtonReturn:
                return linkCurrentArchiveToCurrentLibrary(model: model)
            case .alertSecondButtonReturn:
                guard let selected = promptForArchiveRoot(
                    title: "Choose Archive",
                    message: "Choose the archive location to use with the current photo library.",
                    prompt: "Use Archive",
                    mode: .existingOnly
                ) else { return false }
                guard model.updateArchiveRoot(selected) else { return false }
                return linkCurrentArchiveToCurrentLibrary(model: model)
            default:
                return false
            }
        case .unbound:
            alert.alertStyle = .informational
            alert.messageText = "Link Archive to This Photo Library"
            if let currentName {
                alert.informativeText = "\(archiveName) is not yet linked to a photo library.\n\nCurrent system photo library:\n\(currentName)"
            } else {
                alert.informativeText = "\(archiveName) is not yet linked to a photo library.\n\nLibrarian can’t identify the current system photo library name."
            }
            alert.addButton(withTitle: "Link Now")
            alert.addButton(withTitle: "Choose Different Archive")
            alert.addButton(withTitle: "Cancel")
            let response = await alert.runSheetOrModal(for: parentWindow)
            switch response {
            case .alertFirstButtonReturn:
                return linkCurrentArchiveToCurrentLibrary(model: model)
            case .alertSecondButtonReturn:
                guard let selected = promptForArchiveRoot(
                    title: "Choose Archive",
                    message: "Choose the archive location to use with the current photo library.",
                    prompt: "Use Archive",
                    mode: .existingOnly
                ) else { return false }
                guard model.updateArchiveRoot(selected) else { return false }
                return linkCurrentArchiveToCurrentLibrary(model: model)
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

    private static func linkCurrentArchiveToCurrentLibrary(model: AppModel) -> Bool {
        guard let archiveRoot = ArchiveSettings.restoreArchiveRootURL() else { return false }
        guard let library = try? ArchiveSettings.currentPhotoLibraryFingerprint() else { return false }

        let confirm = NSAlert()
        confirm.alertStyle = .warning
        confirm.messageText = "Link Archive to Current Library?"
        confirm.informativeText = "Changing this link affects duplicate detection for future imports. Photos already in the archive will not be moved or deleted."
        confirm.addButton(withTitle: "Link Archive")
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
            model.scheduleSystemPhotoLibraryRefresh(reason: "linkArchive", debounceMilliseconds: 0)
        }
        return updated
    }

    private enum ArchivePromptMode {
        case existingOnly
        case newLocation
    }

    private static func promptForArchiveRoot(
        title: String,
        message: String,
        prompt: String,
        mode: ArchivePromptMode
    ) -> URL? {
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
        guard let selected = panel.url?.standardizedFileURL else { return nil }
        if let resolved = ArchiveSettings.resolveArchiveRoot(fromUserSelection: selected) {
            return resolved
        }
        switch mode {
        case .existingOnly:
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Archive Not Recognized"
            alert.informativeText = "The selected folder does not contain a Librarian archive."
            alert.addButton(withTitle: "OK")
            _ = alert.runModal()
            return nil
        case .newLocation:
            return normalizeRootForNewArchiveSelection(selected)
        }
    }

    private static func displayLibraryName(fromPath path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        guard path.hasPrefix("/") else { return nil }
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return name.isEmpty ? nil : name
    }

    private static func displayLibraryName(fromURL url: URL?) -> String? {
        guard let url else { return nil }
        return displayLibraryName(fromPath: url.path)
    }

    private static func mismatchInformativeText(
        archiveName: String,
        boundLibraryName: String?,
        currentLibraryName: String?,
        operation: ArchiveWriteOperation
    ) -> String {
        let bindingLine: String
        if let boundLibraryName {
            bindingLine = "\(archiveName) is currently linked to:\n\(boundLibraryName)"
        } else {
            bindingLine = "\(archiveName) is linked to a different photo library."
        }

        let currentLine: String
        if let currentLibraryName {
            currentLine = "Current system photo library:\n\(currentLibraryName)"
        } else {
            currentLine = "Librarian can’t identify the current system photo library name."
        }

        return "\(bindingLine)\n\n\(currentLine)\n\n\(operation.displayName.capitalized) is paused to avoid incorrect duplicate handling."
    }

    private static func normalizeRootForNewArchiveSelection(_ selected: URL) -> URL {
        let standardized = selected.standardizedFileURL
        guard standardized.lastPathComponent == ArchiveSettings.archiveFolderName else {
            return standardized
        }
        return standardized.deletingLastPathComponent().standardizedFileURL
    }

    private static func displayArchiveName(model: AppModel) -> String? {
        if let root = ArchiveSettings.restoreArchiveRootURL() {
            let base = root.lastPathComponent
            if !base.isEmpty { return base }
        }
        return ArchiveSettings.currentArchiveTreeRootURL()?.lastPathComponent
    }
}
