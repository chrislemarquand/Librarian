# User-Facing Strings Inventory

Generated: 2026-03-21 20:31:14 GMT

Source: Swift code in Sources/Librarian

## Candidate User-Facing Strings (path:line)

Sources/Librarian/Shell/SidebarController.swift:43:        SidebarItem(section: .library, kind: .allPhotos,            title: "All Photos",  symbolName: "photo.on.rectangle.angled", badgeText: nil),
Sources/Librarian/Shell/SidebarController.swift:44:        SidebarItem(section: .library, kind: .recents,              title: "Recents",     symbolName: "clock",                     badgeText: nil),
Sources/Librarian/Shell/SidebarController.swift:45:        SidebarItem(section: .library, kind: .favourites,           title: "Favourites",  symbolName: "heart",                     badgeText: nil),
Sources/Librarian/Shell/SidebarController.swift:46:        SidebarItem(section: .queues,  kind: .screenshots,          title: "Screenshots", symbolName: "camera.viewfinder",         badgeText: nil, keepDecisionKind: "screenshots"),
Sources/Librarian/Shell/SidebarController.swift:47:        SidebarItem(section: .queues,  kind: .duplicates,           title: "Duplicates",  symbolName: "photo.on.rectangle",        badgeText: nil, keepDecisionKind: "duplicates"),
Sources/Librarian/Shell/SidebarController.swift:48:        SidebarItem(section: .queues,  kind: .lowQuality,           title: "Low Quality", symbolName: "wand.and.stars.inverse",    badgeText: nil, keepDecisionKind: "lowQuality"),
Sources/Librarian/Shell/SidebarController.swift:49:        SidebarItem(section: .queues,  kind: .receiptsAndDocuments, title: "Documents",   symbolName: "doc.text",                  badgeText: nil, keepDecisionKind: "receiptsAndDocuments"),
Sources/Librarian/Shell/SidebarController.swift:50:        SidebarItem(section: .queues,  kind: .whatsapp,             title: "WhatsApp",    symbolName: "message",                   badgeText: nil, keepDecisionKind: "whatsapp"),
Sources/Librarian/Shell/SidebarController.swift:51:        SidebarItem(section: .queues,  kind: .accidental,           title: "Accidental",  symbolName: "photo.badge.exclamationmark", badgeText: nil, keepDecisionKind: "accidental"),
Sources/Librarian/Shell/SidebarController.swift:52:        SidebarItem(section: .archive, kind: .setAsideForArchive,   title: "Set Aside",   symbolName: "tray.full",                 badgeText: nil),
Sources/Librarian/Shell/SidebarController.swift:53:        SidebarItem(section: .archive, kind: .archived,             title: "Archive",     symbolName: "archivebox",                badgeText: nil),
Sources/Librarian/Shell/SidebarController.swift:54:        SidebarItem(section: .tasks,   kind: .log,                  title: "Log",         symbolName: "list.bullet.rectangle",     badgeText: nil),
Sources/Librarian/Photos/PhotosLibraryService.swift:153:                        NSLocalizedDescriptionKey: "Deletion request failed."
Sources/Librarian/Indexing/LibraryAnalyser.swift:61:                            NSLocalizedDescriptionKey: "JSON decode failed: \(detail)"
Sources/Librarian/Indexing/LibraryAnalyser.swift:385:            NSLocalizedDescriptionKey: "The library scan process ended unexpectedly (code \(osxProcess.terminationStatus))."
Sources/Librarian/Indexing/LibraryAnalyser.swift:419:            NSLocalizedDescriptionKey: "Python extraction step failed with code \(pyProcess.terminationStatus)."
Sources/Librarian/Indexing/LibraryAnalyser.swift:426:            NSLocalizedDescriptionKey: "Python extraction produced no output."
Sources/Librarian/Indexing/LibraryAnalyser.swift:450:        NSLocalizedDescriptionKey: "Required library scan components are missing from the app."
Sources/Librarian/AppDelegate.swift:115:        alert.messageText = "An operation is still in progress."
Sources/Librarian/AppDelegate.swift:116:        alert.informativeText = "Quit now? The operation will be interrupted."
Sources/Librarian/Shell/ArchiveExportSheetView.swift:66:        panel.prompt = "Choose Folder"
Sources/Librarian/Shell/ArchiveExportSheetView.swift:67:        panel.message = "Choose where Librarian should export archived photos."
Sources/Librarian/Shell/ArchiveExportSheetView.swift:113:        WorkflowSheetContainer(
Sources/Librarian/Shell/ArchiveExportSheetView.swift:136:                        Text("On").tag(ArchiveExportSession.ToggleChoice.on)
Sources/Librarian/Shell/ArchiveExportSheetView.swift:137:                        Text("Off").tag(ArchiveExportSession.ToggleChoice.off)
Sources/Librarian/Shell/ArchiveExportSheetView.swift:146:                        Text("On").tag(ArchiveExportSession.ToggleChoice.on)
Sources/Librarian/Shell/ArchiveExportSheetView.swift:147:                        Text("Off").tag(ArchiveExportSession.ToggleChoice.off)
Sources/Librarian/Model/ArchiveRelinkFlow.swift:10:    alert.messageText = "Archive Not Found"
Sources/Librarian/Model/ArchiveRelinkFlow.swift:11:    alert.informativeText = "Librarian can’t find your archive in its last known location. It may have been moved, renamed, deleted, or disconnected.\n\nLocate it, or create a new archive."
Sources/Librarian/Model/ArchiveRelinkFlow.swift:23:    panel.title = "Locate Archive"
Sources/Librarian/Model/ArchiveRelinkFlow.swift:24:    panel.message = "Select your archive folder, or the folder that contains it."
Sources/Librarian/Model/ArchiveRelinkFlow.swift:25:    panel.prompt = "Choose Folder"
Sources/Librarian/Model/ArchiveRelinkFlow.swift:37:        errorAlert.messageText = "Archive Not Recognized"
Sources/Librarian/Model/ArchiveRelinkFlow.swift:38:        errorAlert.informativeText = "The selected folder does not appear to contain a Librarian archive. Select the archive folder itself, or its parent folder."
Sources/Librarian/Model/ArchiveRelinkFlow.swift:47:        errorAlert.messageText = "Couldn’t Link Archive"
Sources/Librarian/Model/ArchiveRelinkFlow.swift:48:        errorAlert.informativeText = "Librarian was unable to save the new archive location."
Sources/Librarian/Model/ArchiveRelinkFlow.swift:58:    panel.title = "Create New Archive"
Sources/Librarian/Model/ArchiveRelinkFlow.swift:59:    panel.message = "Choose a folder for a new Librarian archive."
Sources/Librarian/Model/ArchiveRelinkFlow.swift:60:    panel.prompt = "Choose Folder"
Sources/Librarian/Model/ArchiveRelinkFlow.swift:78:        errorAlert.messageText = "Couldn’t Create Archive"
Sources/Librarian/Model/ArchiveRelinkFlow.swift:79:        errorAlert.informativeText = "Librarian was unable to save the new archive location."
Sources/Librarian/Shell/ArchiveRootPrompts.swift:8:        alert.messageText = "Switch to a Different Archive?"
Sources/Librarian/Shell/ArchiveRootPrompts.swift:9:        alert.informativeText =
Sources/Librarian/Shell/ArchiveRootPrompts.swift:26:        alert.messageText = "Create New Archive Here?"
Sources/Librarian/Shell/ArchiveRootPrompts.swift:27:        alert.informativeText =
Sources/Librarian/Shell/MainSplitViewController.swift:47:            self?.model.setSelectedSidebarItem(item)
Sources/Librarian/Shell/MainSplitViewController.swift:361:                    model.setStatusMessage("Removed failed items from Set Aside: \(removed).", autoClearAfterSuccess: true)
Sources/Librarian/Shell/MainSplitViewController.swift:366:                model.setStatusMessage("Couldn’t remove failed items from Set Aside. \(error.localizedDescription)")
Sources/Librarian/Shell/MainSplitViewController.swift:463:        panel.prompt = "Choose Folder"
Sources/Librarian/Shell/MainSplitViewController.swift:464:        panel.message = "Choose where Librarian should export archived photos."
Sources/Librarian/Shell/MainSplitViewController.swift:479:        alert.messageText = title
Sources/Librarian/Shell/MainSplitViewController.swift:480:        alert.informativeText = message
Sources/Librarian/Shell/ArchiveImportSheetView.swift:134:        panel.title = "Choose Source Folders"
Sources/Librarian/Shell/ArchiveImportSheetView.swift:135:        panel.message = "Choose one or more folders to import into the archive."
Sources/Librarian/Shell/ArchiveImportSheetView.swift:136:        panel.prompt = "Choose Folders"
Sources/Librarian/Shell/ArchiveImportSheetView.swift:166:            model.setStatusMessage(runError ?? "Archive import failed.")
Sources/Librarian/Shell/ArchiveImportSheetView.swift:171:            model.setStatusMessage(runError ?? "Archive import failed.")
Sources/Librarian/Shell/ArchiveImportSheetView.swift:189:                model.setStatusMessage("No files to import after duplicate checks.", autoClearAfterSuccess: true)
Sources/Librarian/Shell/ArchiveImportSheetView.swift:195:                model.setStatusMessage("Import completed with \(summary.failed.formatted()) failures.")
Sources/Librarian/Shell/ArchiveImportSheetView.swift:197:                model.setStatusMessage("Import complete: \(summary.imported.formatted()) files.", autoClearAfterSuccess: true)
Sources/Librarian/Shell/ArchiveImportSheetView.swift:201:            model.setStatusMessage("Import failed. \(error.localizedDescription)")
Sources/Librarian/Shell/ArchiveImportSheetView.swift:214:            model.setStatusMessage(runError ?? "Archive import failed.")
Sources/Librarian/Shell/ArchiveImportSheetView.swift:226:            model.setStatusMessage("Review failed. \(error.localizedDescription)")
Sources/Librarian/Shell/ArchiveImportSheetView.swift:239:            model.setStatusMessage("No unorganized files found.", autoClearAfterSuccess: true)
Sources/Librarian/Shell/ArchiveImportSheetView.swift:253:            model.setStatusMessage("Review failed. \(error.localizedDescription)")
Sources/Librarian/Shell/ArchiveImportSheetView.swift:258:            model.setStatusMessage("Review completed with \(execution.failed.formatted()) failures.")
Sources/Librarian/Shell/ArchiveImportSheetView.swift:260:            model.setStatusMessage(
Sources/Librarian/Shell/ArchiveImportSheetView.swift:435:                NSLocalizedDescriptionKey: "Could not compute relative path for \(childPath)"
Sources/Librarian/Shell/ArchiveImportSheetView.swift:473:        WorkflowSheetContainer(title: session.mode.title, infoText: session.mode.infoText) {
Sources/Librarian/Shell/ArchiveLibraryMismatchPrompt.swift:43:        alert.messageText = libraryName.map { "Switched to \($0)" } ?? "System Photo Library Changed"
Sources/Librarian/Shell/ArchiveLibraryMismatchPrompt.swift:44:        alert.informativeText = "Librarian found the archive linked to this library: \"\(archiveName)\".\n\nSwitch to it now?"
Sources/Librarian/Shell/ArchiveLibraryMismatchPrompt.swift:64:        alert.messageText = "No Archive Linked to This Library"
Sources/Librarian/Shell/ArchiveLibraryMismatchPrompt.swift:66:            alert.informativeText = "You switched to \"\(libraryName)\", but no linked archive was found.\n\nChoose how to continue."
Sources/Librarian/Shell/ArchiveLibraryMismatchPrompt.swift:68:            alert.informativeText = "No linked archive was found for the active system photo library.\n\nChoose how to continue."
Sources/Librarian/Shell/ArchiveLibraryMismatchPrompt.swift:119:            alert.messageText = "Archive Linked to Different Photo Library"
Sources/Librarian/Shell/ArchiveLibraryMismatchPrompt.swift:120:            alert.informativeText = mismatchInformativeText(
Sources/Librarian/Shell/ArchiveLibraryMismatchPrompt.swift:148:            alert.messageText = "Link Archive to This Photo Library"
Sources/Librarian/Shell/ArchiveLibraryMismatchPrompt.swift:150:                alert.informativeText = "\(archiveName) is not yet linked to a photo library.\n\nCurrent system photo library:\n\(currentName)"
Sources/Librarian/Shell/ArchiveLibraryMismatchPrompt.swift:152:                alert.informativeText = "\(archiveName) is not yet linked to a photo library.\n\nLibrarian can’t identify the current system photo library name."
Sources/Librarian/Shell/ArchiveLibraryMismatchPrompt.swift:175:            alert.messageText = "Couldn’t Verify Active Photo Library"
Sources/Librarian/Shell/ArchiveLibraryMismatchPrompt.swift:176:            alert.informativeText = "Librarian couldn’t verify the active system photo library. \(operation.displayName.capitalized) is paused until this is resolved."
Sources/Librarian/Shell/ArchiveLibraryMismatchPrompt.swift:191:        confirm.messageText = "Link Archive to Current Library?"
Sources/Librarian/Shell/ArchiveLibraryMismatchPrompt.swift:192:        confirm.informativeText = "Changing this link affects duplicate detection for future imports. Existing archived files will not be moved or deleted."
Sources/Librarian/Shell/ArchiveLibraryMismatchPrompt.swift:228:        panel.title = title
Sources/Librarian/Shell/ArchiveLibraryMismatchPrompt.swift:229:        panel.message = message
Sources/Librarian/Shell/ArchiveLibraryMismatchPrompt.swift:230:        panel.prompt = prompt
Sources/Librarian/Shell/ArchiveLibraryMismatchPrompt.swift:245:            alert.messageText = "Archive Not Recognized"
Sources/Librarian/Shell/ArchiveLibraryMismatchPrompt.swift:246:            alert.informativeText = "The selected folder does not contain a Librarian archive."
Sources/Librarian/Shell/ArchiveSettingsViewController.swift:116:        panel.prompt = "Choose"
Sources/Librarian/Shell/ArchiveSettingsViewController.swift:117:        panel.message = retrying
Sources/Librarian/Shell/ArchiveSettingsViewController.swift:165:        alert.messageText = "Existing Archive Detected"
Sources/Librarian/Shell/ArchiveSettingsViewController.swift:166:        alert.informativeText =
Sources/Librarian/Shell/ArchiveSettingsViewController.swift:187:        panel.title = "Choose Move Destination"
Sources/Librarian/Shell/ArchiveSettingsViewController.swift:188:        panel.message = "Choose where to move your archive. Librarian will move all archive files and switch to the new location."
Sources/Librarian/Shell/ArchiveSettingsViewController.swift:189:        panel.prompt = "Move Here"
Sources/Librarian/Shell/ArchiveSettingsViewController.swift:329:        alert.messageText = "Organize New Archive Location?"
Sources/Librarian/Shell/ArchiveSettingsViewController.swift:330:        alert.informativeText = "Librarian found \(count.formatted()) files outside the YYYY/MM/DD folder pattern. Organize them now?"
Sources/Librarian/Shell/ArchiveSettingsViewController.swift:480:        alert.messageText = "Move Existing Archive?"
Sources/Librarian/Shell/ArchiveSettingsViewController.swift:481:        alert.informativeText =
Sources/Librarian/Shell/ArchiveSettingsViewController.swift:497:        alert.messageText = "Move Existing Archive Failed"
Sources/Librarian/Shell/ArchiveSettingsViewController.swift:498:        alert.informativeText = message
Sources/Librarian/Shell/ArchiveSettingsViewController.swift:506:        alert.messageText = "Archive Move Complete"
Sources/Librarian/Shell/ArchiveSettingsViewController.swift:507:        alert.informativeText =
Sources/Librarian/Shell/ArchiveSettingsViewController.swift:523:                NSLocalizedDescriptionKey: """
Sources/Librarian/Shell/ArchiveSettingsViewController.swift:532:                NSLocalizedDescriptionKey: """
Sources/Librarian/Shell/ArchiveSettingsViewController.swift:543:                NSLocalizedDescriptionKey: "Current archive is not available: \(sourceAvailability.userVisibleDescription)"
Sources/Librarian/Shell/ArchiveSettingsViewController.swift:549:                NSLocalizedDescriptionKey: "Current archive is missing required Librarian metadata."
Sources/Librarian/Shell/ArchiveSettingsViewController.swift:559:                    NSLocalizedDescriptionKey: "Selected destination is not writable."
Sources/Librarian/Shell/ArchiveSettingsViewController.swift:566:                    NSLocalizedDescriptionKey: "Destination parent folder is not writable."
Sources/Librarian/Shell/ArchiveSettingsViewController.swift:573:                NSLocalizedDescriptionKey: "Selected destination already appears to be a Librarian archive."
Sources/Librarian/Shell/ArchiveSettingsViewController.swift:587:                    NSLocalizedDescriptionKey: """
Sources/Librarian/Shell/ArchiveSettingsViewController.swift:603:                NSLocalizedDescriptionKey: "Not enough free space at destination."
Sources/Librarian/Shell/ArchiveSettingsViewController.swift:632:                NSLocalizedDescriptionKey: """
Sources/Librarian/Shell/ArchiveSettingsViewController.swift:643:                NSLocalizedDescriptionKey: "Selected destination already contains an Archive folder."
Sources/Librarian/Shell/ArchiveSettingsViewController.swift:650:                NSLocalizedDescriptionKey: "Verification failed after move. Source archive folder still exists."
Sources/Librarian/Shell/ArchiveSettingsViewController.swift:657:                NSLocalizedDescriptionKey: "Verification failed after move (\(destinationStats.fileCount) of \(expectedFileCount) files visible at destination)."
Sources/Librarian/Model/ArchiveAddPhotosFlow.swift:15:        alert.messageText = "No Archive Configured"
Sources/Librarian/Model/ArchiveAddPhotosFlow.swift:16:        alert.informativeText = "Choose an archive location in Settings before adding photos."
Sources/Librarian/Model/ArchiveAddPhotosFlow.swift:24:    panel.title = "Choose Source Folders"
Sources/Librarian/Model/ArchiveAddPhotosFlow.swift:25:    panel.message = "Choose one or more folders whose photos will be copied into the archive. These folders will not be modified."
Sources/Librarian/Model/ArchiveAddPhotosFlow.swift:26:    panel.prompt = "Choose Folders"
Sources/Librarian/Model/ArchiveAddPhotosFlow.swift:50:        alert.messageText = "Scan Failed"
Sources/Librarian/Model/ArchiveAddPhotosFlow.swift:51:        alert.informativeText = error.localizedDescription
Sources/Librarian/Model/ArchiveAddPhotosFlow.swift:68:        alert.messageText = "Import Failed"
Sources/Librarian/Model/ArchiveAddPhotosFlow.swift:69:        alert.informativeText = error.localizedDescription
Sources/Librarian/Model/ArchiveAddPhotosFlow.swift:86:    alert.messageText = "Add Photos to Archive?"
Sources/Librarian/Model/ArchiveAddPhotosFlow.swift:99:    alert.informativeText = lines.joined(separator: "\n")
Sources/Librarian/Model/ArchiveAddPhotosFlow.swift:111:    alert.messageText = "Photos Added"
Sources/Librarian/Model/ArchiveAddPhotosFlow.swift:123:    alert.informativeText = lines.joined(separator: "\n")
Sources/Librarian/Model/AppModel.swift:731:    func setSelectedSidebarItem(_ item: SidebarItem) {
Sources/Librarian/Model/AppModel.swift:872:                NSLocalizedDescriptionKey: "An archive import is already in progress."
Sources/Librarian/Model/AppModel.swift:906:                    NSLocalizedDescriptionKey: "Import produced no result."
Sources/Librarian/Model/AppModel.swift:947:                NSLocalizedDescriptionKey: "Export failed for \(outcome.failedCount) items. Nothing was deleted."
Sources/Librarian/Model/AppModel.swift:952:                NSLocalizedDescriptionKey: "Exported \(outcome.exportedCount) items, but \(outcome.notDeletedCount) could not be removed from Photos. Those items were returned to Set Aside."
Sources/Librarian/Model/AppModel.swift:957:                NSLocalizedDescriptionKey: "Exported \(outcome.exportedCount) items. \(outcome.failedCount) failed and remain in Set Aside."
Sources/Librarian/Model/AppModel.swift:986:                NSLocalizedDescriptionKey: "Couldn’t prepare the archive at the selected location."
Sources/Librarian/Model/AppModel.swift:1499:    func setStatusMessage(_ message: String, autoClearAfterSuccess: Bool = false) {
Sources/Librarian/Model/AppModel.swift:1850:        NSLocalizedDescriptionKey: "Required export components are missing."
Sources/Librarian/Model/AppModel.swift:1871:        NSLocalizedDescriptionKey: "Bundled exiftool executable not found in app resources."
Sources/Librarian/Shell/ContentController.swift:823:        screenshotArchiveButton = NSButton(title: "Set Aside", target: self, action: #selector(markScreenshotsArchiveCandidate))
Sources/Librarian/Shell/ContentController.swift:829:        screenshotKeepButton = NSButton(title: "Keep", target: self, action: #selector(markScreenshotsKeep))
Sources/Librarian/Shell/ContentController.swift:870:        archivedNoticeActionButton = NSButton(title: "Review Import…", target: self, action: #selector(reviewArchivedImportNow))
Sources/Librarian/Shell/ContentController.swift:875:        archivedNoticeDismissButton = NSButton(title: "Not Now", target: self, action: #selector(dismissArchivedNoticeForLaunch))
Sources/Librarian/Shell/ContentController.swift:1138:        alert.messageText = "Quick Look Unavailable"
Sources/Librarian/Shell/ContentController.swift:1139:        alert.informativeText = "Selected items are not available locally. Download iCloud-only photos first."
Sources/Librarian/Shell/ContentController.swift:1179:            model.setStatusMessage("\(action): \(selectedAssets.count) screenshot(s).", autoClearAfterSuccess: true)
Sources/Librarian/Shell/ContentController.swift:1185:            model.setStatusMessage("Couldn’t update screenshot decisions. \(error.localizedDescription)")
Sources/Librarian/Shell/ContentController.swift:1208:            model.setStatusMessage("Set aside \(identifiers.count) photos.", autoClearAfterSuccess: true)
Sources/Librarian/Shell/ContentController.swift:1214:            model.setStatusMessage("Couldn’t set aside photos. \(error.localizedDescription)")
Sources/Librarian/Shell/ContentController.swift:1232:            model.setStatusMessage("Put back \(identifiers.count) items.", autoClearAfterSuccess: true)
Sources/Librarian/Shell/ContentController.swift:1235:            model.setStatusMessage("Couldn’t put back selected items. \(error.localizedDescription)")
Sources/Librarian/Shell/ContentController.swift:1348:            model.setStatusMessage("Set aside \(identifiers.count) photos.", autoClearAfterSuccess: true)
Sources/Librarian/Shell/ContentController.swift:1354:            model.setStatusMessage("Couldn’t set aside photos. \(error.localizedDescription)")
Sources/Librarian/Shell/ContentController.swift:1369:            model.setStatusMessage("Put back \(identifiers.count) items.", autoClearAfterSuccess: true)
Sources/Librarian/Shell/ContentController.swift:1372:            model.setStatusMessage("Couldn’t put back selected items. \(error.localizedDescription)")
