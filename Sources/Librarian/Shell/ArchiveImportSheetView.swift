import SwiftUI
import AppKit
import SharedUI

enum ArchiveImportSheetMode {
    case pathAUserPick
    case pathBDetected(candidates: [URL])

    var title: String { "Import Photos into Archive" }

    var infoText: String {
        switch self {
        case .pathAUserPick:
            return "Choose source folders to copy into your archive. Exact duplicates already in your Photo Library will be skipped."
        case .pathBDetected:
            return "Review detected files from your archive folder before Librarian organizes them."
        }
    }

    var initialSources: [URL] {
        switch self {
        case .pathAUserPick:
            return []
        case .pathBDetected(let candidates):
            var roots: Set<URL> = []
            for candidate in candidates {
                var isDir = ObjCBool(false)
                if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                    roots.insert(candidate.standardizedFileURL)
                } else {
                    roots.insert(candidate.deletingLastPathComponent().standardizedFileURL)
                }
            }
            return Array(roots).sorted { $0.path < $1.path }
        }
    }
}

#if DEBUG
extension ArchiveImportSession {
    nonisolated static func test_executePathBPlan(
        archiveTreeRoot: URL,
        exactDuplicates: [URL],
        accepted: [URL]
    ) throws -> ArchiveImportRunSummary {
        try executePathBPlan(
            archiveTreeRoot: archiveTreeRoot,
            plan: PathBPlan(
                allCandidates: exactDuplicates + accepted,
                exactDuplicates: exactDuplicates,
                accepted: accepted
            )
        )
    }
}
#endif

@MainActor
final class ArchiveImportSession: ObservableObject {
    @Published var sourceFolders: [URL]
    @Published var isBusy = false
    @Published var runError: String?
    @Published var preflight: ArchiveImportPreflightResult?
    @Published var summary: ArchiveImportRunSummary?

    let mode: ArchiveImportSheetMode

    init(mode: ArchiveImportSheetMode) {
        self.mode = mode
        self.sourceFolders = mode.initialSources
    }

    var canChooseSources: Bool {
        if case .pathAUserPick = mode { return true }
        return false
    }

    var sourceSummaryText: String {
        guard !sourceFolders.isEmpty else { return "No source folders selected." }
        if sourceFolders.count == 1 {
            return sourceFolders[0].path
        }
        return "\(sourceFolders.count) folders selected"
    }

    var detailsText: String {
        var lines: [String] = []
        lines.append("Archive Import")
        lines.append("Mode: \(modeLabel)")
        if !sourceFolders.isEmpty {
            lines.append("Source folders:")
            lines.append(contentsOf: sourceFolders.map { "- \($0.path)" })
        }
        if let preflight {
            lines.append("")
            lines.append("Preflight")
            lines.append("- Discovered: \(preflight.totalDiscovered)")
            lines.append("- Duplicate in source: \(preflight.duplicatesInSource)")
            lines.append("- Already in Photo Library: \(preflight.existsInPhotoKit)")
            lines.append("- To import: \(preflight.toImport)")
        }
        if let summary {
            lines.append("")
            lines.append("Run Summary")
            lines.append("- Imported: \(summary.imported)")
            lines.append("- Duplicate in source: \(summary.skippedDuplicateInSource)")
            lines.append("- Already in Photo Library: \(summary.skippedExistsInPhotoKit)")
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
        return lines.joined(separator: "\n")
    }

    private var modeLabel: String {
        switch mode {
        case .pathAUserPick: return "Path A (User Pick)"
        case .pathBDetected: return "Path B (Detected in Archive)"
        }
    }

    func chooseSourceFolders() {
        guard canChooseSources else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Source Folders"
        panel.message = "Choose one or more folders to import into the archive."
        panel.prompt = "Choose Sources"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        sourceFolders = panel.urls
    }

    func run(model: AppModel) async {
        guard !isBusy else { return }

        isBusy = true
        runError = nil
        preflight = nil
        summary = nil
        defer { isBusy = false }

        switch mode {
        case .pathAUserPick:
            await runPathA(model: model)
        case .pathBDetected:
            await runPathB(model: model)
        }
    }

    private func runPathA(model: AppModel) async {
        guard !sourceFolders.isEmpty else {
            runError = "Choose at least one source folder."
            return
        }
        guard let archiveRoot = ArchiveSettings.restoreArchiveRootURL() else {
            runError = "No archive root is configured."
            return
        }

        let coordinator = ArchiveImportCoordinator(
            archiveRoot: archiveRoot,
            sourceFolders: sourceFolders,
            database: model.database,
            photosService: model.photosService
        )

        do {
            let preflight = try await Task.detached(priority: .utility) {
                try await coordinator.runPreflight()
            }.value
            self.preflight = preflight

            guard preflight.toImport > 0 else { return }
            let summary = try await model.runArchiveImport(sourceFolders: sourceFolders, preflight: preflight)
            self.summary = summary
        } catch {
            runError = error.localizedDescription
        }
    }

    private struct PathBPlan {
        let allCandidates: [URL]
        let exactDuplicates: [URL]
        let accepted: [URL]
    }

    private func runPathB(model: AppModel) async {
        guard let archiveTreeRoot = ArchiveSettings.currentArchiveTreeRootURL() else {
            runError = "Archive folder is unavailable."
            return
        }

        let dedupeService = ArchiveExactDedupeService(database: model.database, photosService: model.photosService)
        let plan: PathBPlan
        do {
            plan = try await Task.detached(priority: .utility) {
                try await Self.makePathBPlan(archiveTreeRoot: archiveTreeRoot, dedupeService: dedupeService)
            }.value
        } catch {
            runError = error.localizedDescription
            return
        }

        preflight = ArchiveImportPreflightResult(
            totalDiscovered: plan.allCandidates.count,
            duplicatesInSource: 0,
            existsInPhotoKit: plan.exactDuplicates.count,
            toImport: plan.accepted.count,
            candidateURLs: plan.accepted
        )

        guard !plan.allCandidates.isEmpty else {
            return
        }

        let execution: ArchiveImportRunSummary
        do {
            execution = try await Task.detached(priority: .utility) {
                try Self.executePathBPlan(
                    archiveTreeRoot: archiveTreeRoot,
                    plan: plan
                )
            }.value
        } catch {
            runError = error.localizedDescription
            return
        }
        summary = execution

        // Re-index archive after in-place dedupe/organize so archive view and badges update.
        let db = model.database
        Task.detached(priority: .utility) {
            let indexer = ArchiveIndexer(database: db)
            _ = try? indexer.refreshIndex()
            await MainActor.run {
                NotificationCenter.default.post(name: .librarianArchiveQueueChanged, object: nil)
                NotificationCenter.default.post(name: .librarianContentDataChanged, object: nil)
            }
        }
    }

    nonisolated private static func makePathBPlan(
        archiveTreeRoot: URL,
        dedupeService: ArchiveExactDedupeService
    ) async throws -> PathBPlan {
        let candidates = try collectPathBCandidates(in: archiveTreeRoot)
        guard !candidates.isEmpty else {
            return PathBPlan(allCandidates: [], exactDuplicates: [], accepted: [])
        }

        let classifications = await dedupeService.classifyFiles(candidates, allowNetworkAccess: false)
        var duplicates: [URL] = []
        var accepted: [URL] = []
        for classification in classifications {
            switch classification.outcome {
            case .exactMatch:
                duplicates.append(classification.fileURL)
            case .noMatch, .indeterminate:
                accepted.append(classification.fileURL)
            }
        }

        return PathBPlan(allCandidates: candidates, exactDuplicates: duplicates, accepted: accepted)
    }

    nonisolated private static func executePathBPlan(
        archiveTreeRoot: URL,
        plan: PathBPlan
    ) throws -> ArchiveImportRunSummary {
        let fileManager = FileManager.default
        let didAccess = archiveTreeRoot.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                archiveTreeRoot.stopAccessingSecurityScopedResource()
            }
        }

        var failures: [(path: String, reason: String)] = []
        let quarantineRoot = archiveTreeRoot
            .appendingPathComponent("Already in Photo Library", isDirectory: true)
        if !plan.exactDuplicates.isEmpty {
            try fileManager.createDirectory(at: quarantineRoot, withIntermediateDirectories: true)
        }

        for duplicateURL in plan.exactDuplicates {
            do {
                let relativePath = try relativePath(from: archiveTreeRoot, to: duplicateURL)
                let destinationURL = quarantineRoot.appendingPathComponent(relativePath, isDirectory: false)
                let parent = destinationURL.deletingLastPathComponent()
                try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
                let finalDestination = uniqueDestinationURL(
                    in: parent,
                    preferredName: destinationURL.lastPathComponent,
                    fileManager: fileManager
                )
                try fileManager.moveItem(at: duplicateURL, to: finalDestination)
            } catch {
                failures.append((duplicateURL.path, error.localizedDescription))
            }
        }

        var organizedCount = 0
        do {
            let organizer = ArchiveOrganizer()
            let organization = try organizer.organizeArchiveTree(in: archiveTreeRoot)
            organizedCount = organization.movedCount
        } catch {
            failures.append((archiveTreeRoot.path, "Organize failed: \(error.localizedDescription)"))
        }

        return ArchiveImportRunSummary(
            imported: organizedCount,
            skippedDuplicateInSource: 0,
            skippedExistsInPhotoKit: plan.exactDuplicates.count,
            failed: failures.count,
            failures: failures,
            completedAt: Date()
        )
    }

    nonisolated private static func collectPathBCandidates(in archiveTreeRoot: URL) throws -> [URL] {
        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey]
        guard let enumerator = fileManager.enumerator(
            at: archiveTreeRoot,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants, .skipsHiddenFiles]
        ) else {
            return []
        }

        let rootComponents = archiveTreeRoot.standardizedFileURL.pathComponents
        var files: [URL] = []
        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent.hasPrefix(".") { continue }
            let standardized = fileURL.standardizedFileURL
            let fileComponents = standardized.pathComponents
            guard fileComponents.count > rootComponents.count else { continue }
            guard Array(fileComponents.prefix(rootComponents.count)) == rootComponents else { continue }

            let relativeComponents = Array(fileComponents.dropFirst(rootComponents.count))
            guard !relativeComponents.isEmpty else { continue }
            if relativeComponents.first == ".librarian-thumbnails" { continue }
            if relativeComponents.first == "Already in Photo Library" { continue }

            let values = try fileURL.resourceValues(forKeys: keys)
            guard values.isRegularFile == true else { continue }

            let parentComponents = Array(relativeComponents.dropLast())
            guard !isOrganizedPath(parentComponents, layout: ArchiveSettings.folderLayout) else { continue }
            files.append(standardized)
        }
        return files
    }

    nonisolated private static func isOrganizedPath(_ components: [String], layout: ArchiveSettings.ArchiveFolderLayout) -> Bool {
        switch layout {
        case .dateOnly:
            return components.count == 3 && isOrganizedDatePath(components)
        case .kindThenDate:
            if components.count == 4 && components[0] == "Photos" {
                return isOrganizedDatePath(Array(components.suffix(3)))
            }
            if components.count == 5 && components[0] == "Other" {
                return isOrganizedDatePath(Array(components.suffix(3)))
            }
            return false
        }
    }

    nonisolated private static func isOrganizedDatePath(_ components: [String]) -> Bool {
        guard components.count >= 3 else { return false }
        let year = components[components.count - 3]
        let month = components[components.count - 2]
        let day = components[components.count - 1]
        return isYear(year) && isMonth(month) && isDay(day)
    }

    nonisolated private static func isYear(_ value: String) -> Bool {
        guard value.count == 4, let year = Int(value) else { return false }
        return year >= 1900 && year <= 3000
    }

    nonisolated private static func isMonth(_ value: String) -> Bool {
        guard value.count == 2, let month = Int(value) else { return false }
        return month >= 1 && month <= 12
    }

    nonisolated private static func isDay(_ value: String) -> Bool {
        guard value.count == 2, let day = Int(value) else { return false }
        return day >= 1 && day <= 31
    }

    nonisolated private static func relativePath(from root: URL, to child: URL) throws -> String {
        let rootPath = root.standardizedFileURL.path
        let childPath = child.standardizedFileURL.path
        guard childPath.hasPrefix(rootPath + "/") else {
            throw NSError(domain: "\(AppBrand.identifierPrefix).archiveImport", code: 201, userInfo: [
                NSLocalizedDescriptionKey: "Could not compute relative path for \(childPath)"
            ])
        }
        return String(childPath.dropFirst(rootPath.count + 1))
    }

    nonisolated private static func uniqueDestinationURL(in directory: URL, preferredName: String, fileManager: FileManager) -> URL {
        var candidate = directory.appendingPathComponent(preferredName, isDirectory: false)
        guard fileManager.fileExists(atPath: candidate.path) else { return candidate }
        let ext = (preferredName as NSString).pathExtension
        let baseName = (preferredName as NSString).deletingPathExtension
        var counter = 2
        while true {
            let suffix = "-\(counter)"
            let nextName = ext.isEmpty ? "\(baseName)\(suffix)" : "\(baseName)\(suffix).\(ext)"
            candidate = directory.appendingPathComponent(nextName, isDirectory: false)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            counter += 1
        }
    }
}

struct ArchiveImportSheetView: View {
    @ObservedObject var model: AppModel
    let onClose: () -> Void

    @StateObject private var session: ArchiveImportSession
    @State private var showDetails = false

    init(model: AppModel, mode: ArchiveImportSheetMode, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
        _session = StateObject(wrappedValue: ArchiveImportSession(mode: mode))
    }

    var body: some View {
        WorkflowSheetContainer(title: session.mode.title, infoText: session.mode.infoText) {
            HStack {
                TextField("", text: Binding(
                    get: { session.sourceSummaryText },
                    set: { _ in }
                ))
                .textFieldStyle(.roundedBorder)
                .disabled(true)

                if session.canChooseSources {
                    Button("Choose…") {
                        session.chooseSourceFolders()
                    }
                    .disabled(session.isBusy)
                }
            }

            if let banner = activeBanner {
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
                    WorkflowDetailsPopover(text: session.detailsText)
                }

                Spacer()

                if !isComplete {
                    Button("Cancel") {
                        onClose()
                    }
                    .keyboardShortcut(.cancelAction)
                }

                Button(isComplete ? "Close" : "Import") {
                    if isComplete {
                        onClose()
                    } else {
                        Task { await session.run(model: model) }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(session.isBusy)
            }
        }
    }

    private var isComplete: Bool {
        session.summary != nil || session.runError != nil || (session.preflight?.toImport == 0 && session.preflight != nil)
    }

    private var activeBanner: [String]? {
        if let runError = session.runError {
            return [runError]
        }
        if let preflight = session.preflight, preflight.toImport == 0 {
            return ["Nothing to import after duplicate checks."]
        }
        if let summary = session.summary {
            if summary.failed > 0 {
                return ["Imported \(summary.imported). Failed \(summary.failed). Review Details…"]
            }
            return ["Imported \(summary.imported) file(s)."]
        }
        return nil
    }
}
