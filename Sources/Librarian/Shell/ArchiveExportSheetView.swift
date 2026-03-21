import SwiftUI
import AppKit
import Combine
import SharedUI

@MainActor
final class ArchiveExportSession: ObservableObject {
    enum ToggleChoice: String, CaseIterable, Identifiable {
        case on
        case off

        var id: String { rawValue }
        var title: String {
            switch self {
            case .on: return "On"
            case .off: return "Off"
            }
        }
    }

    @Published var destinationURL: URL
    @Published var keepOriginalsChoice: ToggleChoice
    @Published var keepLivePhotosChoice: ToggleChoice
    @Published var isBusy = false
    @Published var outcome: ArchiveSendOutcome?
    @Published var runError: String?
    let scopedLocalIdentifiers: [String]?

    init(destinationURL: URL, scopedLocalIdentifiers: [String]?) {
        self.destinationURL = destinationURL
        self.scopedLocalIdentifiers = scopedLocalIdentifiers
        self.keepOriginalsChoice = .off
        self.keepLivePhotosChoice = .off
    }

    var exportOptions: ArchiveExportOptions {
        ArchiveExportOptions(
            keepOriginalsAlongsideEdits: keepOriginalsChoice == .on,
            keepLivePhotos: keepLivePhotosChoice == .on
        )
    }

    var detailsText: String {
        guard let outcome else { return "" }
        var lines: [String] = []
        lines.append("Archive Export Summary")
        lines.append("Destination: \(destinationURL.path)")
        lines.append("Exported: \(outcome.exportedCount)")
        lines.append("Deleted from Photos: \(outcome.deletedCount)")
        lines.append("Failed: \(outcome.failedCount)")
        lines.append("Not deleted from Photos: \(outcome.notDeletedCount)")

        if !outcome.failures.isEmpty {
            lines.append("")
            lines.append("Failures")
            for failure in outcome.failures.sorted(by: { $0.identifier < $1.identifier }) {
                lines.append("- \(failure.identifier): \(failure.message)")
            }
        }

        return lines.joined(separator: "\n")
    }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.prompt = "Set Archive Folder"
        panel.message = "Choose where Librarian should export archived photos."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = destinationURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        destinationURL = url
    }

    func performExport(model: AppModel) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }
        runError = nil
        outcome = nil

        do {
            let result = try await model.sendArchiveCandidatesWithOutcome(
                to: destinationURL,
                options: exportOptions,
                localIdentifiers: scopedLocalIdentifiers
            )
            outcome = result
            return true
        } catch {
            runError = error.localizedDescription
            return false
        }
    }
}

struct ArchiveExportSheetView: View {
    @ObservedObject var model: AppModel
    let onClose: () -> Void

    @StateObject private var session: ArchiveExportSession
    @State private var showDetails = false

    init(model: AppModel, initialDestinationURL: URL, scopedLocalIdentifiers: [String]? = nil, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
        _session = StateObject(wrappedValue: ArchiveExportSession(destinationURL: initialDestinationURL, scopedLocalIdentifiers: scopedLocalIdentifiers))
    }

    var body: some View {
        WorkflowSheetContainer(
            title: "Send to Archive",
            infoText: session.scopedLocalIdentifiers == nil
                ? "Exports all photos currently in Set Aside. Failed items remain in Set Aside for follow-up."
                : "Exports selected photos currently in Set Aside. Failed items remain in Set Aside for follow-up."
        ) {
            HStack {
                TextField("", text: Binding(
                    get: { session.destinationURL.path },
                    set: { _ in }
                ))
                .textFieldStyle(.roundedBorder)
                .disabled(true)

                Button("Choose…") {
                    session.chooseDestination()
                }
                .disabled(session.isBusy)
            }

            HStack(alignment: .top, spacing: 28) {
                WorkflowOptionGroup("Keep originals alongside edits:") {
                    Picker("", selection: $session.keepOriginalsChoice) {
                        Text("On").tag(ArchiveExportSession.ToggleChoice.on)
                        Text("Off").tag(ArchiveExportSession.ToggleChoice.off)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    .disabled(session.isBusy)
                }

                WorkflowOptionGroup("Keep Live Photos:") {
                    Picker("", selection: $session.keepLivePhotosChoice) {
                        Text("On").tag(ArchiveExportSession.ToggleChoice.on)
                        Text("Off").tag(ArchiveExportSession.ToggleChoice.off)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    .disabled(session.isBusy)
                }
            }

            if session.isBusy {
                WorkflowInlineMessageBanner(messages: [sheetProgressText])
            } else if let banner = activeBanner {
                WorkflowInlineMessageBanner(messages: banner)
            }

            ProgressView()
                .progressViewStyle(.linear)
                .opacity(session.isBusy ? 1 : 0)

            HStack {
                Button("Details…") {
                    showDetails = true
                }
                .disabled(session.detailsText.isEmpty)
                .popover(isPresented: $showDetails) {
                    WorkflowDetailsPopover(
                        text: session.detailsText.isEmpty ? "No details available." : session.detailsText
                    )
                }

                Spacer()

                if !isComplete {
                    Button("Cancel") {
                        onClose()
                    }
                    .keyboardShortcut(.cancelAction)
                }

                Button(isComplete ? "Close" : "Export") {
                    if isComplete {
                        onClose()
                    } else {
                        performExport()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(session.isBusy)
            }
        }
    }

    private var isComplete: Bool {
        session.outcome != nil || session.runError != nil
    }

    private var activeBanner: [String]? {
        if let runError = session.runError {
            return [runError]
        }
        guard let outcome = session.outcome else { return nil }
        if outcome.failedCount > 0 || outcome.notDeletedCount > 0 {
            return [
                "\(outcome.exportedCount) exported, \(outcome.failedCount) failed.",
                "Failed items remain in Set Aside. Review Details…"
            ]
        }
        return [
            "\(outcome.exportedCount) exported and \(outcome.deletedCount) removed from Photos."
        ]
    }

    private var sheetProgressText: String {
        let text = model.archiveSendStatusText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "Sending to Archive…" : text
    }

    private func performExport() {
        Task {
            _ = await session.performExport(model: model)
        }
    }
}
