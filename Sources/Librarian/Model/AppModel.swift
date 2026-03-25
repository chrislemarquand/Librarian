import Cocoa
import Photos
import Combine
import SwiftUI
import CryptoKit
import SharedUI

@MainActor
final class AppModel: ObservableObject {
    private static let staleArchiveExportMessage =
        "Previous archive export was interrupted. Item returned to Set Aside."

    // MARK: - Services (owned here, accessed by coordinators)

    let photosService: PhotosLibraryService
    let database: DatabaseManager
    let systemNotifications: SystemNotificationService

    // MARK: - First-run analysis scheduling

    /// Set by the welcome screen coordinator before `setup()` is called.
    /// When true, `startIndexing` will automatically trigger `runLibraryAnalysis`
    /// once the initial index pass completes.
    private var shouldAutoAnalyseAfterIndex = false

    // MARK: - Published state

    @Published var photosAuthState: PHAuthorizationStatus = .notDetermined
    @Published var selectedSidebarItem: SidebarItem? = SidebarItem.allItems.first
    @Published var isInspectorCollapsed = false
    @Published var isIndexing = false
    @Published var isSendingArchive = false
    @Published var archiveSendStatusText: String = ""
    @Published var isAnalysing = false
    @Published private(set) var isAnalysisInNonResumableStage = false
    @Published var analysisStatusText: String = ""
    private var lastAnalysisProgressNotificationDate: Date = .distantPast
    @Published private(set) var pendingAnalysisCount: Int = 0
    @Published private(set) var analysisHasRunBefore: Bool = false
    @Published var isImportingArchive = false
    @Published var importStatusText: String = ""
    @Published var statusMessage: String = "Ready"
    @Published var indexedAssetCount = 0
    @Published var pendingArchiveCandidateCount = 0
    @Published var failedArchiveCandidateCount = 0
    @Published var assetDataVersion: Int = 0
    @Published var selectedAsset: IndexedAsset?
    @Published var selectedArchivedItem: ArchivedItem?
    @Published var selectedAssetCount: Int = 0
    @Published var activeInspectorFieldCatalog: [InspectorFieldCatalogEntry] = AppModel.defaultInspectorFieldCatalog()
    @Published var indexingProgress: IndexingProgress = .idle
    @Published var archiveRootAvailability: ArchiveSettings.ArchiveRootAvailability = .notConfigured
    @Published var archiveRootURL: URL? = ArchiveSettings.currentArchiveRootResolution().rootURL
    @Published var currentSystemPhotoLibraryPath: String?
    @Published var galleryGridLevel: Int = 4 {
        didSet {
            let clamped = min(max(galleryGridLevel, Self.galleryColumnRange.lowerBound), Self.galleryColumnRange.upperBound)
            if galleryGridLevel != clamped {
                galleryGridLevel = clamped
                return
            }
            UserDefaults.standard.set(galleryGridLevel, forKey: Self.galleryGridLevelKey)
            NotificationCenter.default.post(name: .librarianGalleryZoomChanged, object: nil)
        }
    }

    private var changeTracker: PhotosChangeTracker?
    private var pendingDeltaApplyTask: Task<Void, Never>?
    private var pendingUnknownReconcileTask: Task<Void, Never>?
    private var pendingLibraryIdentityCheckTask: Task<Void, Never>?
    private var pendingArchiveMonitorTask: Task<Void, Never>?
    private var pendingAnalysisAutoResumeTask: Task<Void, Never>?
    private var libraryMonitorTimer: Timer?
    private var libraryMonitorInterval: TimeInterval = 60
    private static let libraryMonitorBaseInterval: TimeInterval = 60
    private static let libraryMonitorMaxInterval: TimeInterval = 300
    private var archiveMonitorTimer: Timer?
    private var archiveMonitorInterval: TimeInterval = 120
    private static let archiveMonitorBaseInterval: TimeInterval = 120
    private static let archiveMonitorMaxInterval: TimeInterval = 600
    private var archiveFSEventSource: DispatchSourceFileSystemObject?
    private var isArchiveBackgroundReconcileRunning = false
    private var hasAutoResumedAnalysisThisLaunch = false
    private var lastObservedArchiveRelativePaths: Set<String> = []
    private var didNotifyArchiveNeedsRelinkForCurrentOutage = false
    private var didNotifyArchiveUnavailableSystemNotificationForCurrentOutage = false
    private var statusResetTask: Task<Void, Never>?
    private var suppressChangeSyncUntil: Date = .distantPast
    private var suppressChangeSyncReason: String?
    private var pendingUpsertsByIdentifier: [String: IndexedAsset] = [:]
    private var pendingDeletedIdentifiers: Set<String> = []

    static let galleryColumnRange = 2 ... 9
    private static let galleryGridLevelKey = "ui.gallery.grid.level"
    private static let analysisAutoResumeLaunchDelayMilliseconds: UInt64 = 15_000
    private static let analysisAutoResumeRetryDelayMilliseconds: UInt64 = 45_000
    static let inspectorFieldVisibilityKey = "ui.inspector.field.visibility"

    // MARK: - Init

    init() {
        self.photosService = PhotosLibraryService()
        self.database = DatabaseManager()
        self.systemNotifications = .shared
        let defaults = UserDefaults.standard
        let storedLevel = defaults.integer(forKey: Self.galleryGridLevelKey)
        if storedLevel == 0 {
            galleryGridLevel = 4
        } else {
            galleryGridLevel = min(max(storedLevel, Self.galleryColumnRange.lowerBound), Self.galleryColumnRange.upperBound)
        }
        activeInspectorFieldCatalog = Self.applyingInspectorVisibilityPreferences(to: Self.defaultInspectorFieldCatalog())
    }

    // MARK: - Setup

    func setup() async {
        systemNotifications.prepare()
        do {
            try database.open()
        } catch {
            // Database open failure is unrecoverable — surface via overlay
            indexingProgress = .failed(error.localizedDescription)
            AppLog.shared.error("Database open failed: \(error.localizedDescription)")
            return
        }
        AppLog.shared.info("Database opened")

        do {
            let recovered = try database.assetRepository.recoverStaleArchiveExports(
                errorMessage: Self.staleArchiveExportMessage
            )
            if recovered > 0 {
                AppLog.shared.info("Recovered \(recovered) stale archive export items at launch")
            }
        } catch {
            AppLog.shared.error("Failed to recover stale archive exports: \(error.localizedDescription)")
        }

        // Load persisted count before requesting Photos access so UI isn't blank
        indexedAssetCount = (try? database.assetRepository.count()) ?? 0
        pendingArchiveCandidateCount = (try? database.assetRepository.countArchiveCandidates(statuses: [.pending, .exporting, .failed])) ?? 0
        failedArchiveCandidateCount = (try? database.assetRepository.countArchiveCandidates(statuses: [.failed])) ?? 0
        pendingAnalysisCount = (try? database.assetRepository.countVisionAnalysisCandidates(includePreviouslyAnalysed: false)) ?? 0
        analysisHasRunBefore = (try? database.assetRepository.analysisHasRunBefore()) ?? false
        AppLog.shared.info("Loaded persisted index count: \(indexedAssetCount)")
        let availability = refreshArchiveRootAvailability()
        if availability == .unavailable {
            didNotifyArchiveNeedsRelinkForCurrentOutage = true
        }
        startSystemPhotoLibraryMonitoring()
        startArchiveMonitoring()
        scheduleSystemPhotoLibraryRefresh(reason: "startup", debounceMilliseconds: 0)
        scheduleArchiveMonitorTick(reason: "startup", debounceMilliseconds: 0)

        await requestPhotosAccess()
        scheduleAnalysisAutoResume(
            reason: "setupComplete",
            initialDelayMilliseconds: Self.analysisAutoResumeLaunchDelayMilliseconds
        )
    }

    // MARK: - Photos access

    private func requestPhotosAccess() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        photosAuthState = status
        AppLog.shared.info("Photos authorization status: \(String(describing: status.rawValue))")
        notifyIndexingStateChanged()

        switch status {
        case .authorized:
            registerChangeTracking()
            suppressChangeSync(for: 8, reason: "initialAuthorization")
            if indexedAssetCount == 0 {
                await startInitialIndex()
            } else {
                AppLog.shared.info("Skipping full launch re-index; existing index count is \(indexedAssetCount)")
                scheduleAnalysisAutoResume(
                    reason: "authorizedWithExistingCatalogue",
                    initialDelayMilliseconds: Self.analysisAutoResumeLaunchDelayMilliseconds
                )
            }
        case .limited:
            // Limited access: show locked state — full access required
            unregisterChangeTracking()
            break
        default:
            unregisterChangeTracking()
            break
        }
    }

    func retryPhotosAccess() async {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        photosAuthState = status
        notifyIndexingStateChanged()
        if status == .authorized {
            registerChangeTracking()
            if indexedAssetCount == 0 {
                await startInitialIndex()
            } else {
                scheduleAnalysisAutoResume(
                    reason: "retryAuthorizedWithExistingCatalogue",
                    initialDelayMilliseconds: Self.analysisAutoResumeLaunchDelayMilliseconds
                )
            }
        } else {
            unregisterChangeTracking()
        }
    }

    // MARK: - Indexing

    private func startInitialIndex() async {
        await startIndexing(reason: "initial", userVisibleProgress: true)
    }

    func rebuildIndexManually() async {
        await startIndexing(reason: "manualRebuild", userVisibleProgress: true)
    }

    private func startBackgroundSync(reason: String) async {
        await startIndexing(reason: reason, userVisibleProgress: false)
    }

    private func startIndexing(reason: String, userVisibleProgress: Bool) async {
        guard !isIndexing else { return }
        isIndexing = true
        if userVisibleProgress {
            indexingProgress = .running(completed: 0, total: 0)
        }
        AppLog.shared.info("Indexing started (\(reason))")
        notifyIndexingStateChanged()

        let indexer = AssetIndexer(database: database)
        do {
            for try await progress in indexer.run() {
                if userVisibleProgress {
                    indexingProgress = .running(completed: progress.completed, total: progress.total)
                }
                indexedAssetCount = progress.completed
                if userVisibleProgress {
                    notifyIndexingStateChanged()
                }
            }
            if userVisibleProgress {
                indexingProgress = .idle
            }
            AppLog.shared.info("Indexing completed (\(reason))")
            if reason == "manualRebuild" {
                systemNotifications.postIfBackground(
                    title: "Catalogue Updated",
                    body: "Librarian finished updating your Catalogue.",
                    identifier: "rebuild-index-complete"
                )
            }
        } catch {
            indexingProgress = .failed(error.localizedDescription)
            AppLog.shared.error("Indexing failed (\(reason)): \(error.localizedDescription)")
            if reason == "manualRebuild" {
                systemNotifications.postIfBackground(
                    title: "Couldn’t Update Catalogue",
                    body: error.localizedDescription,
                    identifier: "rebuild-index-failed"
                )
            }
        }

        isIndexing = false
        indexedAssetCount = (try? database.assetRepository.count()) ?? indexedAssetCount
        assetDataVersion &+= 1
        notifyIndexingStateChanged()
        refreshAnalysisStatus()

        if reason == "initial" && shouldAutoAnalyseAfterIndex {
            shouldAutoAnalyseAfterIndex = false
            Task { await runLibraryAnalysis() }
        } else if reason == "initial" && !isAnalysing && analysisHasRunBefore && pendingAnalysisCount > 0 {
            Task { await runLibraryAnalysis() }
        }
        scheduleAnalysisAutoResume(reason: "indexingCompleted:\(reason)")
    }

    private func notifyIndexingStateChanged() {
        NotificationCenter.default.post(name: .librarianIndexingStateChanged, object: nil)
    }

    func setSelectedSidebarItem(_ item: SidebarItem) {
        if selectedSidebarItem?.kind == item.kind {
            return
        }
        selectedSidebarItem = item
        NotificationCenter.default.post(name: .librarianSidebarSelectionChanged, object: nil)
    }

    func setSelectedAsset(_ asset: IndexedAsset?, count: Int = 1) {
        let newCount = asset == nil ? 0 : count
        if selectedAsset?.localIdentifier == asset?.localIdentifier,
           selectedArchivedItem == nil,
           selectedAssetCount == newCount {
            return
        }
        selectedAsset = asset
        selectedArchivedItem = nil
        selectedAssetCount = newCount
        NotificationCenter.default.post(name: .librarianSelectionChanged, object: nil)
    }

    func setSelectedArchivedItem(_ item: ArchivedItem?, count: Int = 1) {
        let newCount = item == nil ? 0 : count
        if selectedArchivedItem?.relativePath == item?.relativePath,
           selectedAsset == nil,
           selectedAssetCount == newCount {
            return
        }
        selectedArchivedItem = item
        selectedAsset = nil
        selectedAssetCount = newCount
        NotificationCenter.default.post(name: .librarianSelectionChanged, object: nil)
    }

    func queueAssetsForArchive(localIdentifiers: [String]) throws {
        let identifiers = Array(Set(localIdentifiers))
        guard !identifiers.isEmpty else { return }
        try database.assetRepository.queueForArchive(identifiers: identifiers)
        AppLog.shared.info("Queued \(identifiers.count) items for archive")
        refreshArchiveCandidateCount()
    }

    func unqueueAssetsForArchive(localIdentifiers: [String]) throws {
        let identifiers = Array(Set(localIdentifiers))
        guard !identifiers.isEmpty else { return }
        try database.assetRepository.removeFromArchiveQueue(identifiers: identifiers)
        AppLog.shared.info("Removed \(identifiers.count) items from archive set-aside queue")
        refreshArchiveCandidateCount()
    }

    func unqueueFailedArchiveAssets() throws -> Int {
        let failed = try database.assetRepository.fetchArchiveCandidateIdentifiers(statuses: [.failed])
        guard !failed.isEmpty else { return 0 }
        try database.assetRepository.removeFromArchiveQueue(identifiers: failed)
        AppLog.shared.info("Removed \(failed.count) failed items from archive set-aside queue")
        refreshArchiveCandidateCount()
        assetDataVersion &+= 1
        return failed.count
    }

    @discardableResult
    func updateArchiveRoot(_ url: URL) -> Bool {
        // Remove the custom icon from the current Archive/ subfolder before switching.
        if let oldRoot = ArchiveSettings.restoreArchiveRootURL(),
           oldRoot.standardizedFileURL != url.standardizedFileURL {
            ArchiveFolderIcon.remove(from: ArchiveSettings.archiveTreeRootURL(from: oldRoot), accessedVia: oldRoot)
        }
        guard ArchiveSettings.persistArchiveRootURL(url) else { return false }
        ArchiveFolderIcon.apply(to: ArchiveSettings.archiveTreeRootURL(from: url), accessedVia: url)
        refreshArchiveRootAvailability()
        scheduleSystemPhotoLibraryRefresh(reason: "archiveRootUpdated", debounceMilliseconds: 0)
        scheduleArchiveMonitorTick(reason: "archiveRootUpdated", debounceMilliseconds: 0)
        return true
    }

    @discardableResult
    func refreshArchiveRootAvailability() -> ArchiveSettings.ArchiveRootAvailability {
        let previous = archiveRootAvailability
        let previousURL = archiveRootURL?.standardizedFileURL
        let resolution = ArchiveSettings.currentArchiveRootResolution()
        let current = resolution.availability
        archiveRootAvailability = current
        archiveRootURL = resolution.rootURL
        let currentURL = archiveRootURL?.standardizedFileURL
        if previous != current {
            AppLog.shared.info("Archive root availability changed: \(String(describing: previous)) -> \(String(describing: current))")
        }
        let didChange = previous != current || previousURL != currentURL
        if didChange {
            lastObservedArchiveRelativePaths.removeAll()
            startArchiveFSEventMonitoring()
            NotificationCenter.default.post(name: .librarianArchiveRootChanged, object: nil)
            NotificationCenter.default.post(name: .librarianArchiveQueueChanged, object: nil)
            scheduleArchiveMonitorTick(reason: "archiveRootChanged", debounceMilliseconds: 0)
        }
        if current == .unavailable {
            if !didNotifyArchiveNeedsRelinkForCurrentOutage {
                didNotifyArchiveNeedsRelinkForCurrentOutage = true
                NotificationCenter.default.post(name: .librarianArchiveNeedsRelink, object: nil)
            }
            if !didNotifyArchiveUnavailableSystemNotificationForCurrentOutage {
                didNotifyArchiveUnavailableSystemNotificationForCurrentOutage = true
                systemNotifications.postIfBackground(
                    title: "Archive Not Available",
                    body: "Librarian can’t find your Archive. Open the app to relink it or create a new Archive.",
                    identifier: "archive-unavailable"
                )
            }
        } else {
            didNotifyArchiveNeedsRelinkForCurrentOutage = false
            didNotifyArchiveUnavailableSystemNotificationForCurrentOutage = false
        }
        return current
    }

    func runLibraryAnalysis() async {
        guard !isAnalysing else { return }
        pendingAnalysisAutoResumeTask?.cancel()
        isAnalysing = true
        isAnalysisInNonResumableStage = true
        analysisStatusText = "Analysing…"
        notifyAnalysisStateChanged()

        let analyser = LibraryAnalyser(database: database)
        do {
            for try await progress in analyser.run() {
                switch progress.phase {
                case .querying, .importing:
                    isAnalysisInNonResumableStage = true
                case .visionAnalysing:
                    isAnalysisInNonResumableStage = false
                }
                analysisStatusText = progress.statusText
                let now = Date()
                if now.timeIntervalSince(lastAnalysisProgressNotificationDate) >= 0.25 {
                    lastAnalysisProgressNotificationDate = now
                    notifyAnalysisStateChanged()
                }
            }
            analysisStatusText = ""
            assetDataVersion &+= 1
            systemNotifications.postIfBackground(
                title: "Library Analysis Complete",
                body: "Librarian finished analysing your Photos Library.",
                identifier: "analysis-complete"
            )
        } catch {
            analysisStatusText = "Failed: \(error.localizedDescription)"
            AppLog.shared.error("Library analysis failed: \(error.localizedDescription)")
            systemNotifications.postIfBackground(
                title: "Library Analysis Failed",
                body: error.localizedDescription,
                identifier: "analysis-failed"
            )
        }

        isAnalysisInNonResumableStage = false
        isAnalysing = false
        refreshAnalysisStatus()
    }

    private var hasPendingResumableAnalysisWork: Bool {
        analysisHasRunBefore && pendingAnalysisCount > 0
    }

    private var canRunAnalysisNow: Bool {
        !isIndexing && !isImportingArchive && !isSendingArchive && !isAnalysing
    }

    private var isAutoResumeEnvironmentSuitable: Bool {
        let processInfo = ProcessInfo.processInfo
        guard !processInfo.isLowPowerModeEnabled else { return false }
        switch processInfo.thermalState {
        case .serious, .critical:
            return false
        default:
            return true
        }
    }

    private func scheduleAnalysisAutoResume(
        reason: String,
        initialDelayMilliseconds: UInt64 = 0
    ) {
        guard photosAuthState == .authorized else { return }
        guard hasPendingResumableAnalysisWork else { return }
        guard !hasAutoResumedAnalysisThisLaunch else { return }

        pendingAnalysisAutoResumeTask?.cancel()
        pendingAnalysisAutoResumeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if initialDelayMilliseconds > 0 {
                try? await Task.sleep(nanoseconds: initialDelayMilliseconds * 1_000_000)
            }

            while !Task.isCancelled {
                guard self.photosAuthState == .authorized else { return }
                guard self.hasPendingResumableAnalysisWork else { return }
                guard !self.hasAutoResumedAnalysisThisLaunch else { return }

                if self.canRunAnalysisNow && self.isAutoResumeEnvironmentSuitable {
                    self.hasAutoResumedAnalysisThisLaunch = true
                    AppLog.shared.info("Auto-resuming library analysis (\(reason))")
                    await self.runLibraryAnalysis()
                    return
                }

                try? await Task.sleep(
                    nanoseconds: Self.analysisAutoResumeRetryDelayMilliseconds * 1_000_000
                )
            }
        }
    }

    private func notifyAnalysisStateChanged() {
        NotificationCenter.default.post(name: .librarianAnalysisStateChanged, object: nil)
    }

    private func refreshAnalysisStatus() {
        guard let repo = database.assetRepository else { return }
        pendingAnalysisCount = (try? repo.countVisionAnalysisCandidates(includePreviouslyAnalysed: false)) ?? pendingAnalysisCount
        analysisHasRunBefore = (try? repo.analysisHasRunBefore()) ?? analysisHasRunBefore
        notifyAnalysisStateChanged()
    }

    /// Called by the welcome screen on first run. Schedules an analysis pass to
    /// run automatically once the initial index completes (or immediately if the
    /// index already exists).
    func scheduleAnalysisAfterInitialIndex() {
        if indexedAssetCount > 0 && !isIndexing {
            Task { await runLibraryAnalysis() }
        } else {
            shouldAutoAnalyseAfterIndex = true
        }
    }

    func runArchiveImport(
        sourceFolders: [URL],
        preflight: ArchiveImportPreflightResult
    ) async throws -> ArchiveImportRunSummary {
        let resolution = ArchiveSettings.currentArchiveRootResolution()
        guard let archiveRoot = resolution.rootURL, resolution.isAvailable else {
            throw NSError(domain: "\(AppBrand.identifierPrefix).archiveImport", code: 6, userInfo: [
                NSLocalizedDescriptionKey: resolution.availability.userVisibleDescription
            ])
        }
        guard !isImportingArchive else {
            throw NSError(domain: "\(AppBrand.identifierPrefix).archiveImport", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "An archive import is already in progress."
            ])
        }

        _ = try ArchiveOperationPreflightService.checkWritableAndFreeSpace(
            at: archiveRoot,
            estimatedWriteBytes: ArchiveOperationPreflightService.estimateImportWriteBytes(candidateURLs: preflight.candidateURLs)
        )

        isImportingArchive = true
        importStatusText = "Starting import…"
        defer {
            isImportingArchive = false
            scheduleAnalysisAutoResume(reason: "archiveImportFinished")
        }

        let jobStartedAt = Date()
        let jobID = UUID().uuidString
        let job = try await database.jobRepository.create(type: .archiveImport)
        try await database.jobRepository.markRunning(job)

        let coordinator = ArchiveImportCoordinator(
            archiveRoot: archiveRoot,
            sourceFolders: sourceFolders,
            database: database
        )

        var finalSummary: ArchiveImportRunSummary?
        do {
            for try await event in coordinator.runImport(preflight: preflight) {
                switch event {
                case .progress(let completed, let total):
                    importStatusText = "Importing \(completed.formatted()) / \(total.formatted())…"
                case .done(let summary):
                    finalSummary = summary
                    importStatusText = ""
                }
            }

            guard let summary = finalSummary else {
                throw NSError(domain: "\(AppBrand.identifierPrefix).archiveImport", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Import produced no result."
                ])
            }

            try database.assetRepository.saveArchiveImportRun(
                id: jobID,
                startedAt: jobStartedAt,
                summary: summary,
                archiveRootPath: archiveRoot.path,
                sourcePaths: sourceFolders.map(\.path)
            )

            if summary.imported > 0 {
                refreshArchivedIndexAsync()
            }

            try await database.jobRepository.markCompleted(job)
            AppLog.shared.info(
                "Archive import completed. imported=\(summary.imported), " +
                "skippedDuplicateInSource=\(summary.skippedDuplicateInSource), " +
                "skippedExistsInPhotoKit=\(summary.skippedExistsInPhotoKit), " +
                "skippedExistsInArchive=\(summary.skippedExistsInArchive), " +
                "failed=\(summary.failed)"
            )
            let body: String
            if summary.failed > 0 {
                body = "Imported \(summary.imported) photos. \(summary.failed) failed."
            } else {
                body = "Imported \(summary.imported) photos."
            }
            systemNotifications.postIfBackground(
                title: "Archive Import Complete",
                body: body,
                identifier: "archive-import-complete"
            )
            return summary

        } catch {
            try? await database.jobRepository.markFailed(job, error: error.localizedDescription)
            importStatusText = "Import failed: \(error.localizedDescription)"
            AppLog.shared.error("Archive import failed: \(error.localizedDescription)")
            systemNotifications.postIfBackground(
                title: "Archive Import Failed",
                body: error.localizedDescription,
                identifier: "archive-import-failed"
            )
            throw error
        }
    }

    func archiveCandidateInfo(for localIdentifier: String) -> ArchiveCandidateInfo? {
        try? database.assetRepository.fetchArchiveCandidateInfo(localIdentifier: localIdentifier)
    }

    func sendPendingArchive(to archiveRootURL: URL) async throws {
        let outcome = try await sendPendingArchiveWithOutcome(to: archiveRootURL, options: .default)
        if outcome.exportedCount == 0 {
            throw NSError(domain: "\(AppBrand.identifierPrefix).archive", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Export failed for \(outcome.failedCount) photos. Nothing was deleted."
            ])
        }
        if outcome.notDeletedCount > 0 {
            throw NSError(domain: "\(AppBrand.identifierPrefix).archive", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "Exported \(outcome.exportedCount) photos, but \(outcome.notDeletedCount) could not be removed from Photos. Those photos were returned to Set Aside."
            ])
        }
        if outcome.failedCount > 0 {
            throw NSError(domain: "\(AppBrand.identifierPrefix).archive", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "Exported \(outcome.exportedCount) photos. \(outcome.failedCount) failed and remain in Set Aside."
            ])
        }
    }

    func sendPendingArchiveWithOutcome(
        to archiveRootURL: URL,
        options: ArchiveExportOptions
    ) async throws -> ArchiveSendOutcome {
        try await sendArchiveCandidatesWithOutcome(
            to: archiveRootURL,
            options: options,
            localIdentifiers: nil
        )
    }

    func sendArchiveCandidatesWithOutcome(
        to archiveRootURL: URL,
        options: ArchiveExportOptions,
        localIdentifiers: [String]? = nil
    ) async throws -> ArchiveSendOutcome {
        let availability = ArchiveSettings.archiveRootAvailability(for: archiveRootURL)
        guard availability == .available else {
            throw NSError(domain: "\(AppBrand.identifierPrefix).archive", code: 9, userInfo: [
                NSLocalizedDescriptionKey: availability.userVisibleDescription
            ])
        }
        guard ArchiveSettings.ensureControlFolder(at: archiveRootURL) else {
            throw NSError(domain: "\(AppBrand.identifierPrefix).archive", code: 8, userInfo: [
                NSLocalizedDescriptionKey: "Couldn’t prepare the Archive at the selected location."
            ])
        }
        guard !isSendingArchive else {
            return ArchiveSendOutcome(exportedCount: 0, deletedCount: 0, failedCount: 0, notDeletedCount: 0, failures: [])
        }
        let pendingOrFailedIdentifiers = try database.assetRepository.fetchArchiveCandidateIdentifiers(statuses: [.pending, .failed])
        let identifiers: [String]
        if let localIdentifiers {
            let scopedSet = Set(localIdentifiers)
            identifiers = pendingOrFailedIdentifiers.filter { scopedSet.contains($0) }
        } else {
            identifiers = pendingOrFailedIdentifiers
        }
        guard !identifiers.isEmpty else {
            return ArchiveSendOutcome(exportedCount: 0, deletedCount: 0, failedCount: 0, notDeletedCount: 0, failures: [])
        }

        let fileSizeStats = try database.assetRepository.fetchFileSizeStats(localIdentifiers: identifiers)
        let estimatedExportBytes = ArchiveOperationPreflightService.estimateExportWriteBytes(fileSizeStats: fileSizeStats)
        _ = try ArchiveOperationPreflightService.checkWritableAndFreeSpace(
            at: archiveRootURL,
            estimatedWriteBytes: estimatedExportBytes
        )

        isSendingArchive = true
        archiveSendStatusText = "Preparing archive export…"
        defer {
            isSendingArchive = false
            archiveSendStatusText = ""
            scheduleAnalysisAutoResume(reason: "archiveSendFinished")
        }

        let job = try await database.jobRepository.create(type: .archiveExport)
        try await database.jobRepository.markRunning(job)

        do {
            try database.assetRepository.markArchiveCandidatesExporting(identifiers: identifiers)
            archiveSendStatusText = "Exporting \(identifiers.count.formatted()) photos…"
            refreshArchiveCandidateCount()
            let exportTargets = [
                ArchiveExportTarget(
                    destination: archiveRootForExport(archiveRootURL),
                    localIdentifiers: identifiers
                )
            ]
            let exportRoot = archiveRootURL
            let preExportRelativePaths = try await Task.detached(priority: .utility) {
                try withArchiveRootAccess(root: exportRoot) {
                    try archiveImageRelativePaths(under: archiveRootForExport(exportRoot))
                }
            }.value
            let exportResult = try await Task.detached(priority: .utility) {
                try withArchiveRootAccess(root: exportRoot) {
                    try runOsxPhotosExportBatch(targets: exportTargets, options: options)
                }
            }.value
            let exportedIdentifiers = Array(Set(exportResult.exportedGroups.flatMap(\.localIdentifiers)))
            var failures = exportResult.failures
            let failedIdentifiers = Array(Set(failures.map(\.identifier)))

            if !failedIdentifiers.isEmpty {
                let failedByIdentifier = Dictionary(grouping: failures, by: \.identifier)
                let summary = failedIdentifiers.compactMap { identifier -> String? in
                    guard let groupedFailures = failedByIdentifier[identifier], let message = groupedFailures.first?.message else { return nil }
                    return "\(identifier): \(message)"
                }.joined(separator: " | ")
                try database.assetRepository.markArchiveCandidatesFailed(identifiers: failedIdentifiers, error: summary)
                AppLog.shared.error("Archive export failed for \(failedIdentifiers.count) items: \(summary)")
            }

            guard !exportedIdentifiers.isEmpty else {
                try await database.jobRepository.markFailed(job, error: "No items were exported.")
                refreshArchiveCandidateCount()
                systemNotifications.postIfBackground(
                    title: "Archive Export Failed",
                    body: "No photos were exported.",
                    identifier: "archive-export-failed"
                )
                return ArchiveSendOutcome(
                    exportedCount: 0,
                    deletedCount: 0,
                    failedCount: failedIdentifiers.count,
                    notDeletedCount: 0,
                    failures: failures
                )
            }

            archiveSendStatusText = "Checking for duplicates…"
            let exportDedupeSummary = try await Task.detached(priority: .utility) {
                try withArchiveRootAccess(root: exportRoot) {
                    try reconcileNewlyExportedArchiveDuplicates(
                        archiveTreeRoot: archiveRootForExport(exportRoot),
                        preExportRelativePaths: preExportRelativePaths,
                        database: self.database
                    )
                }
            }.value

            for group in exportResult.exportedGroups where !group.localIdentifiers.isEmpty {
                try database.assetRepository.markArchiveCandidatesExported(identifiers: group.localIdentifiers, archivePath: group.destinationPath)
            }
            // Re-index as soon as export writes complete so Archive sidebar count updates immediately.
            archiveSendStatusText = "Refreshing archive index…"
            refreshArchivedIndexAsync()
            archiveSendStatusText = "Deleting exported photos from Photos…"
            suppressChangeSync(for: 20, reason: "archiveDelete")
            let deletedIdentifiers = try await photosService.deleteAssets(localIdentifiers: exportedIdentifiers)
            let notDeleted = Self.notDeletedIdentifiers(
                exportedIdentifiers: exportedIdentifiers,
                deletedIdentifiers: deletedIdentifiers
            )

            if !deletedIdentifiers.isEmpty {
                try database.assetRepository.markDeleted(identifiers: deletedIdentifiers, at: Date())
                try database.assetRepository.markArchiveCandidatesDeleted(identifiers: deletedIdentifiers)
            }

            if !notDeleted.isEmpty {
                let errorText = "Delete step did not remove \(notDeleted.count) photos from Photos. Returned to Set Aside."
                try database.assetRepository.markArchiveCandidatesFailed(identifiers: notDeleted, error: errorText)
                failures.append(contentsOf: notDeleted.map { ArchiveExportFailure(identifier: $0, message: errorText) })
                try await database.jobRepository.markFailed(job, error: errorText)
                AppLog.shared.error("Archive send partially failed. Exported \(exportedIdentifiers.count), deleted \(deletedIdentifiers.count), not deleted \(notDeleted.count).")
                indexedAssetCount = (try? database.assetRepository.count()) ?? indexedAssetCount
                assetDataVersion &+= 1
                refreshArchiveCandidateCount()
                notifyIndexingStateChanged()
                systemNotifications.postIfBackground(
                    title: "Archive Export Needs Attention",
                    body: "Exported \(exportedIdentifiers.count) photos, but \(notDeleted.count) couldn’t be removed from Photos.",
                    identifier: "archive-export-not-deleted"
                )
                return ArchiveSendOutcome(
                    exportedCount: exportedIdentifiers.count,
                    deletedCount: deletedIdentifiers.count,
                    failedCount: Array(Set(failures.map(\.identifier))).count,
                    notDeletedCount: notDeleted.count,
                    failures: failures
                )
            }

            if !failedIdentifiers.isEmpty {
                let message = "Exported \(exportedIdentifiers.count) photos. \(failedIdentifiers.count) failed and remain in Set Aside."
                try await database.jobRepository.markFailed(job, error: message)
                indexedAssetCount = (try? database.assetRepository.count()) ?? indexedAssetCount
                assetDataVersion &+= 1
                refreshArchiveCandidateCount()
                notifyIndexingStateChanged()
                systemNotifications.postIfBackground(
                    title: "Archive Export Partly Failed",
                    body: "Exported \(exportedIdentifiers.count) photos. \(failedIdentifiers.count) failed and remain in Set Aside.",
                    identifier: "archive-export-partial-failure"
                )
                return ArchiveSendOutcome(
                    exportedCount: exportedIdentifiers.count,
                    deletedCount: deletedIdentifiers.count,
                    failedCount: failedIdentifiers.count,
                    notDeletedCount: 0,
                    failures: failures
                )
            }

            try await database.jobRepository.markCompleted(job)
            archiveSendStatusText = "Archive send complete."
            AppLog.shared.info(
                "Archive send completed. Exported \(exportedIdentifiers.count) and deleted \(deletedIdentifiers.count) from Photos. " +
                "suppressedDuplicates=\(exportDedupeSummary.suppressedCount), movedToNeedsReview=\(exportDedupeSummary.movedToNeedsReviewCount), " +
                "dedupeFailures=\(exportDedupeSummary.failureCount)"
            )
            indexedAssetCount = (try? database.assetRepository.count()) ?? indexedAssetCount
            assetDataVersion &+= 1
            refreshArchiveCandidateCount()
            notifyIndexingStateChanged()
            let dedupeSummarySuffix: String
            if exportDedupeSummary.suppressedCount > 0 || exportDedupeSummary.movedToNeedsReviewCount > 0 {
                dedupeSummarySuffix = " Duplicates suppressed: \(exportDedupeSummary.suppressedCount). Needs Review: \(exportDedupeSummary.movedToNeedsReviewCount)."
            } else {
                dedupeSummarySuffix = ""
            }
            systemNotifications.postIfBackground(
                title: "Archive Export Complete",
                body: "Exported \(exportedIdentifiers.count) photos and removed them from Photos.\(dedupeSummarySuffix)",
                identifier: "archive-export-complete"
            )
            return ArchiveSendOutcome(
                exportedCount: exportedIdentifiers.count,
                deletedCount: deletedIdentifiers.count,
                failedCount: 0,
                notDeletedCount: 0,
                failures: []
            )
        } catch {
            let exportingIdentifiers = (try? database.assetRepository.fetchArchiveCandidateIdentifiers(statuses: [.exporting])) ?? []
            let stillExporting = Array(Set(exportingIdentifiers).intersection(Set(identifiers)))
            if !stillExporting.isEmpty {
                try? database.assetRepository.markArchiveCandidatesFailed(identifiers: stillExporting, error: error.localizedDescription)
            }
            try? await database.jobRepository.markFailed(job, error: error.localizedDescription)
            refreshArchiveCandidateCount()
            AppLog.shared.error("Archive send failed: \(error.localizedDescription)")
            systemNotifications.postIfBackground(
                title: "Archive Export Failed",
                body: error.localizedDescription,
                identifier: "archive-export-failed-error"
            )
            throw error
        }
    }

    var galleryColumnCount: Int {
        galleryGridLevel
    }

    var canIncreaseGalleryZoom: Bool {
        galleryGridLevel > Self.galleryColumnRange.lowerBound
    }

    var canDecreaseGalleryZoom: Bool {
        galleryGridLevel < Self.galleryColumnRange.upperBound
    }

    func increaseGalleryZoom() {
        galleryGridLevel = max(galleryGridLevel - 1, Self.galleryColumnRange.lowerBound)
    }

    func decreaseGalleryZoom() {
        galleryGridLevel = min(galleryGridLevel + 1, Self.galleryColumnRange.upperBound)
    }

    func adjustGalleryGridLevel(by delta: Int) {
        guard delta != 0 else { return }
        galleryGridLevel = min(
            max(galleryGridLevel + delta, Self.galleryColumnRange.lowerBound),
            Self.galleryColumnRange.upperBound
        )
    }

    deinit {
        pendingDeltaApplyTask?.cancel()
        pendingUnknownReconcileTask?.cancel()
        pendingLibraryIdentityCheckTask?.cancel()
        pendingArchiveMonitorTask?.cancel()
        pendingAnalysisAutoResumeTask?.cancel()
    }

    var currentSystemPhotoLibraryURL: URL? {
        guard let path = currentSystemPhotoLibraryPath, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    func scheduleSystemPhotoLibraryRefresh(reason: String, debounceMilliseconds: UInt64 = 450) {
        pendingLibraryIdentityCheckTask?.cancel()
        pendingLibraryIdentityCheckTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if debounceMilliseconds > 0 {
                try? await Task.sleep(nanoseconds: debounceMilliseconds * 1_000_000)
            }
            guard !Task.isCancelled else { return }
            self.refreshSystemPhotoLibraryState(reason: reason)
        }
    }

    private func startSystemPhotoLibraryMonitoring() {
        guard libraryMonitorTimer == nil else { return }
        scheduleLibraryMonitorTimer()
    }

    private func scheduleLibraryMonitorTimer() {
        libraryMonitorTimer?.invalidate()
        let interval = libraryMonitorInterval
        libraryMonitorTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let previousPath = self.currentSystemPhotoLibraryPath
                self.scheduleSystemPhotoLibraryRefresh(reason: "periodicPoll")
                // Adaptive backoff: if nothing changed, double the interval
                if self.currentSystemPhotoLibraryPath == previousPath {
                    self.libraryMonitorInterval = min(
                        self.libraryMonitorInterval * 2,
                        Self.libraryMonitorMaxInterval
                    )
                } else {
                    self.libraryMonitorInterval = Self.libraryMonitorBaseInterval
                }
                self.scheduleLibraryMonitorTimer()
            }
        }
    }

    private func startArchiveMonitoring() {
        guard archiveMonitorTimer == nil else { return }
        startArchiveFSEventMonitoring()
        scheduleArchiveMonitorTimer()
    }

    private func scheduleArchiveMonitorTimer() {
        archiveMonitorTimer?.invalidate()
        let interval = archiveMonitorInterval
        archiveMonitorTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let previousPaths = self.lastObservedArchiveRelativePaths
                self.scheduleArchiveMonitorTick(reason: "fallbackPoll")
                // Adaptive backoff: if nothing changed, double the interval
                if self.lastObservedArchiveRelativePaths == previousPaths {
                    self.archiveMonitorInterval = min(
                        self.archiveMonitorInterval * 2,
                        Self.archiveMonitorMaxInterval
                    )
                } else {
                    self.archiveMonitorInterval = Self.archiveMonitorBaseInterval
                }
                self.scheduleArchiveMonitorTimer()
            }
        }
    }

    private func startArchiveFSEventMonitoring() {
        stopArchiveFSEventMonitoring()
        guard let archiveRoot = ArchiveSettings.restoreArchiveRootURL() else { return }
        let exportRoot = archiveRootForExport(archiveRoot)
        let fd = open(exportRoot.path, O_EVTONLY)
        guard fd >= 0 else {
            AppLog.shared.error("Cannot open archive root for FSEvents monitoring: \(exportRoot.path)")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.archiveMonitorInterval = Self.archiveMonitorBaseInterval
                self.scheduleArchiveMonitorTick(reason: "fsEvent")
                self.scheduleArchiveMonitorTimer()
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        archiveFSEventSource = source
        AppLog.shared.info("Started FSEvents monitoring on archive root: \(exportRoot.path)")
    }

    private func stopArchiveFSEventMonitoring() {
        archiveFSEventSource?.cancel()
        archiveFSEventSource = nil
    }

    private func scheduleArchiveMonitorTick(reason: String, debounceMilliseconds: UInt64 = 650) {
        pendingArchiveMonitorTask?.cancel()
        pendingArchiveMonitorTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if debounceMilliseconds > 0 {
                try? await Task.sleep(nanoseconds: debounceMilliseconds * 1_000_000)
            }
            guard !Task.isCancelled else { return }
            await self.runArchiveBackgroundMonitor(reason: reason)
        }
    }

    private func runArchiveBackgroundMonitor(reason: String) async {
        guard archiveRootAvailability == .available,
              let archiveRoot = ArchiveSettings.restoreArchiveRootURL()
        else {
            lastObservedArchiveRelativePaths.removeAll()
            return
        }
        guard !isSendingArchive, !isImportingArchive else { return }
        guard !isArchiveBackgroundReconcileRunning else { return }

        isArchiveBackgroundReconcileRunning = true
        defer { isArchiveBackgroundReconcileRunning = false }

        let exportRoot = archiveRoot
        let currentRelativePaths: Set<String>
        do {
            currentRelativePaths = try await Task.detached(priority: .utility) {
                try withArchiveRootAccess(root: exportRoot) {
                    try archiveImageRelativePaths(under: archiveRootForExport(exportRoot))
                }
            }.value
        } catch {
            AppLog.shared.error("Archive monitor snapshot failed (\(reason)): \(error.localizedDescription)")
            return
        }

        if lastObservedArchiveRelativePaths.isEmpty {
            lastObservedArchiveRelativePaths = currentRelativePaths
            return
        }

        let newlyObserved = currentRelativePaths.subtracting(lastObservedArchiveRelativePaths)
        lastObservedArchiveRelativePaths = currentRelativePaths
        guard !newlyObserved.isEmpty else { return }

        let summary: ArchiveExportDedupeSummary
        do {
            summary = try await Task.detached(priority: .utility) {
                try withArchiveRootAccess(root: exportRoot) {
                    try reconcileArchiveDuplicates(
                        archiveTreeRoot: archiveRootForExport(exportRoot),
                        newRelativePaths: newlyObserved,
                        database: self.database,
                        flow: "finder_watch"
                    )
                }
            }.value
        } catch {
            AppLog.shared.error("Archive monitor reconcile failed (\(reason)): \(error.localizedDescription)")
            return
        }

        if summary.suppressedCount > 0 || summary.movedToNeedsReviewCount > 0 || summary.failureCount > 0 {
            AppLog.shared.info(
                "Archive monitor reconciled \(newlyObserved.count) additions. " +
                "suppressedDuplicates=\(summary.suppressedCount), movedToNeedsReview=\(summary.movedToNeedsReviewCount), failures=\(summary.failureCount)"
            )
            refreshArchivedIndexAsync()
            if summary.movedToNeedsReviewCount > 0 {
                setStatusMessage(
                    "\(summary.movedToNeedsReviewCount.formatted()) files moved to Needs Review during Archive monitoring.",
                    autoClearAfterSuccess: true
                )
            }
            // Refresh snapshot after reconcile may have removed or moved files.
            if let refreshed = try? withArchiveRootAccess(root: exportRoot, operation: {
                try archiveImageRelativePaths(under: archiveRootForExport(exportRoot))
            }) {
                lastObservedArchiveRelativePaths = refreshed
            }
        }
    }

    private func refreshSystemPhotoLibraryState(reason: String) {
        // Keep archive path/availability synchronized during runtime so
        // settings and archive UI react when the archive is moved/deleted.
        refreshArchiveRootAvailability()

        let previousPath = currentSystemPhotoLibraryPath
        let nextPath = ArchiveSettings.currentPhotoLibraryPath()
        currentSystemPhotoLibraryPath = nextPath

        // Stamp the config with the current library path if not yet recorded,
        // so future changes can be detected.
        if let nextPath,
           let archiveRoot = ArchiveSettings.restoreArchiveRootURL(),
           let config = ArchiveSettings.controlConfig(for: archiveRoot),
           config.lastKnownPhotoLibraryPath == nil {
            ArchiveSettings.updateControlConfig(at: archiveRoot) { config in
                config.lastKnownPhotoLibraryPath = nextPath
            }
        }

        if previousPath != nextPath {
            NotificationCenter.default.post(name: .librarianSystemPhotoLibraryChanged, object: nil)
        }
    }

    private func registerChangeTracking() {
        guard changeTracker == nil else { return }
        let tracker = PhotosChangeTracker { [weak self] changeEvent in
            Task { @MainActor in
                self?.handlePhotoLibraryChangeEvent(changeEvent)
            }
        }
        tracker.register()
        changeTracker = tracker
        AppLog.shared.info("Registered Photos change tracker")
    }

    private func unregisterChangeTracking() {
        pendingDeltaApplyTask?.cancel()
        pendingDeltaApplyTask = nil
        pendingUnknownReconcileTask?.cancel()
        pendingUnknownReconcileTask = nil
        pendingUpsertsByIdentifier.removeAll()
        pendingDeletedIdentifiers.removeAll()
        changeTracker?.unregister()
        changeTracker = nil
    }

    private func handlePhotoLibraryChangeEvent(_ event: PhotosLibraryChangeEvent) {
        if Date() < suppressChangeSyncUntil {
            let reason = suppressChangeSyncReason ?? "unspecified"
            AppLog.shared.info("Ignoring photoLibraryDidChange (suppressed: \(reason))")
            return
        }

        switch event {
        case .unknown:
            AppLog.shared.info("Photo library changed (unknown delta); scheduling deleted-asset reconcile")
            scheduleUnknownReconcile()
        case .delta(let delta):
            accumulate(delta: delta)
            scheduleDeltaApply()
        }
    }

    private func accumulate(delta: PhotosLibraryDelta) {
        for identifier in delta.deletedLocalIdentifiers {
            pendingDeletedIdentifiers.insert(identifier)
            pendingUpsertsByIdentifier.removeValue(forKey: identifier)
        }
        for asset in delta.upsertedAssets {
            guard !pendingDeletedIdentifiers.contains(asset.localIdentifier) else { continue }
            pendingUpsertsByIdentifier[asset.localIdentifier] = asset
        }
    }

    private func scheduleDeltaApply() {
        pendingDeltaApplyTask?.cancel()
        pendingDeltaApplyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            await self?.applyPendingPhotoLibraryDelta()
        }
    }

    private func scheduleUnknownReconcile() {
        pendingUnknownReconcileTask?.cancel()
        pendingUnknownReconcileTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            await self?.reconcileRestoredDeletedAssets()
        }
    }

    private func suppressChangeSync(for seconds: TimeInterval, reason: String) {
        let until = Date().addingTimeInterval(seconds)
        if until > suppressChangeSyncUntil {
            suppressChangeSyncUntil = until
            suppressChangeSyncReason = reason
        }
    }

    private func applyPendingPhotoLibraryDelta() async {
        let upserts = Array(pendingUpsertsByIdentifier.values)
        let deleted = Array(pendingDeletedIdentifiers)
        pendingUpsertsByIdentifier.removeAll()
        pendingDeletedIdentifiers.removeAll()

        guard !upserts.isEmpty || !deleted.isEmpty else { return }

        do {
            if !upserts.isEmpty {
                try await database.assetRepository.upsert(upserts)
            }
            if !deleted.isEmpty {
                try database.assetRepository.markDeleted(identifiers: deleted, at: Date())
            }
            indexedAssetCount = (try? database.assetRepository.count()) ?? indexedAssetCount
            assetDataVersion &+= 1
            AppLog.shared.info("Applied photo delta: upserts=\(upserts.count), deleted=\(deleted.count)")
            notifyIndexingStateChanged()
        } catch {
            AppLog.shared.error("Failed applying photo delta: \(error.localizedDescription)")
        }
    }

    private func reconcileRestoredDeletedAssets() async {
        do {
            let deletedIdentifiers = try database.assetRepository.fetchDeletedAssetIdentifiers()
            guard !deletedIdentifiers.isEmpty else { return }

            let restoredAssets = photosService.fetchAssets(localIdentifiers: deletedIdentifiers)
            guard !restoredAssets.isEmpty else { return }

            let now = Date()
            let upserts = restoredAssets.map { IndexedAsset(from: $0, lastSeenAt: now) }
            try await database.assetRepository.upsert(upserts)
            indexedAssetCount = (try? database.assetRepository.count()) ?? indexedAssetCount
            assetDataVersion &+= 1
            AppLog.shared.info("Reconciled restored assets from Photos: \(upserts.count)")
            notifyIndexingStateChanged()
        } catch {
            AppLog.shared.error("Failed to reconcile restored deleted assets: \(error.localizedDescription)")
        }
    }

    private func refreshArchiveCandidateCount() {
        pendingArchiveCandidateCount = (try? database.assetRepository.countArchiveCandidates(statuses: [.pending, .exporting, .failed])) ?? 0
        failedArchiveCandidateCount = (try? database.assetRepository.countArchiveCandidates(statuses: [.failed])) ?? 0
        NotificationCenter.default.post(name: .librarianArchiveQueueChanged, object: nil)
    }

    func setStatusMessage(_ message: String, autoClearAfterSuccess: Bool = false) {
        statusResetTask?.cancel()
        statusResetTask = nil
        statusMessage = message

        guard autoClearAfterSuccess else { return }
        statusResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, self.statusMessage == message else { return }
            self.statusMessage = "Ready"
            self.statusResetTask = nil
        }
    }

    private func refreshArchivedIndexAsync() {
        let db = self.database
        Task.detached(priority: .utility) {
            let indexer = ArchiveIndexer(database: db)
            _ = try? indexer.refreshIndex()
            await MainActor.run {
                NotificationCenter.default.post(name: .librarianArchiveQueueChanged, object: nil)
                NotificationCenter.default.post(name: .librarianContentDataChanged, object: nil)
            }
        }
    }

    nonisolated static func notDeletedIdentifiers(
        exportedIdentifiers: [String],
        deletedIdentifiers: [String]
    ) -> [String] {
        let deletedSet = Set(deletedIdentifiers)
        let expectedSet = Set(exportedIdentifiers)
        return Array(expectedSet.subtracting(deletedSet))
    }

    enum ArchiveSendClassification {
        case noExports
        case deleteMismatch
        case partialFailures
        case success
    }

    nonisolated static func classifyArchiveSendOutcome(
        exportedCount: Int,
        failedCount: Int,
        notDeletedCount: Int
    ) -> ArchiveSendClassification {
        if exportedCount == 0 { return .noExports }
        if notDeletedCount > 0 { return .deleteMismatch }
        if failedCount > 0 { return .partialFailures }
        return .success
    }
}

struct ArchiveExportOptions: Sendable {
    var keepOriginalsAlongsideEdits: Bool
    var keepLivePhotos: Bool

    static let `default` = ArchiveExportOptions(
        keepOriginalsAlongsideEdits: true,
        keepLivePhotos: true
    )
}

struct ArchiveExportFailure: Sendable {
    let identifier: String
    let message: String
}

struct ArchiveSendOutcome: Sendable {
    let exportedCount: Int
    let deletedCount: Int
    let failedCount: Int
    let notDeletedCount: Int
    let failures: [ArchiveExportFailure]
}

private struct OsxPhotosReportRow: Decodable {
    let uuid: String
    let exported: Bool?
    let new: Bool?
    let updated: Bool?
    let skipped: Bool?
    let missing: Bool?
    let error: String?
    let userError: String?
    let exiftoolError: String?
    let sidecarUserError: String?

    enum CodingKeys: String, CodingKey {
        case uuid
        case exported
        case new
        case updated
        case skipped
        case missing
        case error
        case userError = "user_error"
        case exiftoolError = "exiftool_error"
        case sidecarUserError = "sidecar_user_error"
    }
}

private struct ArchiveExportTarget {
    let destination: URL
    let localIdentifiers: [String]
}

private struct ArchiveExportGroupResult {
    let destinationPath: String
    let localIdentifiers: [String]
}

private struct ArchiveExportBatchResult {
    let exportedGroups: [ArchiveExportGroupResult]
    let failures: [ArchiveExportFailure]
}

private struct ArchiveExportDedupeSummary {
    let suppressedCount: Int
    let movedToNeedsReviewCount: Int
    let failureCount: Int
}

nonisolated private func runOsxPhotosExportBatch(
    targets: [ArchiveExportTarget],
    options: ArchiveExportOptions
) throws -> ArchiveExportBatchResult {
    let osxPhotosRunner = OsxPhotosRunner()
    var exportedGroups: [ArchiveExportGroupResult] = []
    var failures: [ArchiveExportFailure] = []

    for target in targets {
        let destination = target.destination
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let identifierByUUID = Dictionary(grouping: target.localIdentifiers, by: { identifier in
            identifier.split(separator: "/").first.map(String.init) ?? identifier
        })
        let uuidList = Array(identifierByUUID.keys).sorted()
        guard !uuidList.isEmpty else { continue }

        let runToken = UUID().uuidString
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent("librarian-export-\(runToken)", isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let uuidFileURL = tempDir.appendingPathComponent("uuids.txt", isDirectory: false)
        let reportURL = tempDir.appendingPathComponent("report.json", isDirectory: false)
        let exportDBURL = destination.appendingPathComponent(".librarian_osxphotos_export.db", isDirectory: false)
        let uuidFileContents = uuidList.joined(separator: "\n")
        try uuidFileContents.write(to: uuidFileURL, atomically: true, encoding: .utf8)

        var args: [String] = [
            "export",
            destination.path,
            "--uuid-from-file", uuidFileURL.path,
            "--report", reportURL.path,
            "--exportdb", exportDBURL.path,
            "--export-by-date",
            "--jpeg-ext", "jpg",
            "--no-progress",
            "--update-errors",
            "--retry", "2",
            "--exiftool",
            "--update"
        ]
        if let libraryPath = OsxPhotosLibraryResolver.preferredLibraryPath() {
            args.append(contentsOf: ["--library", libraryPath])
        }
        if !options.keepOriginalsAlongsideEdits {
            args.append("--skip-original-if-edited")
        }
        if !options.keepLivePhotos {
            args.append("--skip-live")
        }
        logInfoAsync("osxphotos command: \(renderShellCommand(arguments: args))")

        var result = osxPhotosRunner.run(arguments: args, includeExifToolEnvironment: true)
        logInfoAsync("osxphotos executable: \(result.executableURL.path)")
        logInfoAsync("osxphotos used external fallback: \(result.usedExternalFallback)")
        logInfoAsync("osxphotos exit code: \(result.exitCode)")
        if !result.outputText.isEmpty {
            logInfoMultilineAsync(prefix: "osxphotos output", text: result.outputText)
        }
        if result.exitCode != 0, shouldRetryWithoutExifTool(outputText: result.outputText) {
            args = args.filter { $0 != "--exiftool" }
            logInfoAsync("Retrying osxphotos export without --exiftool")
            result = osxPhotosRunner.run(arguments: args, includeExifToolEnvironment: false)
            logInfoAsync("osxphotos retry executable: \(result.executableURL.path)")
            logInfoAsync("osxphotos retry used external fallback: \(result.usedExternalFallback)")
            logInfoAsync("osxphotos retry exit code: \(result.exitCode)")
            if !result.outputText.isEmpty {
                logInfoMultilineAsync(prefix: "osxphotos retry output", text: result.outputText)
            }
        }
        if result.exitCode != 0 {
            let message = result.outputText.isEmpty ? "Export failed (code \(result.exitCode))." : result.outputText
            failures.append(contentsOf: target.localIdentifiers.map { ArchiveExportFailure(identifier: $0, message: message) })
            try? fileManager.removeItem(at: tempDir)
            continue
        }

        let reportRows: [OsxPhotosReportRow]
        let reportData: Data
        do {
            reportData = try Data(contentsOf: reportURL)
            reportRows = try JSONDecoder().decode([OsxPhotosReportRow].self, from: reportData)
        } catch {
            let message = "Export report parsing failed: \(error.localizedDescription)"
            failures.append(contentsOf: target.localIdentifiers.map { ArchiveExportFailure(identifier: $0, message: message) })
            try? fileManager.removeItem(at: tempDir)
            continue
        }
        if let persistedReportURL = persistExportReportJSON(reportData: reportData, runToken: runToken) {
            logInfoAsync("osxphotos report saved: \(persistedReportURL.path)")
        }
        if let reportJSONString = String(data: reportData, encoding: .utf8), !reportJSONString.isEmpty {
            logInfoMultilineAsync(prefix: "osxphotos report json", text: reportJSONString)
        }

        let rowsByUUID = Dictionary(grouping: reportRows, by: \.uuid)
        var succeededIdentifiers: [String] = []

        for uuid in uuidList {
            let localIdentifiers = identifierByUUID[uuid] ?? []
            guard !localIdentifiers.isEmpty else { continue }
            guard let uuidRows = rowsByUUID[uuid], !uuidRows.isEmpty else {
                failures.append(contentsOf: localIdentifiers.map {
                    ArchiveExportFailure(identifier: $0, message: "Export report did not include this item")
                })
                continue
            }

            let errorMessages = uuidRows.compactMap { row -> String? in
                let candidates = [row.error, row.userError, row.exiftoolError, row.sidecarUserError]
                return candidates.first { value in
                    if let value { return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    return false
                } ?? nil
            }

            if !errorMessages.isEmpty {
                let summary = Array(Set(errorMessages)).joined(separator: " | ")
                failures.append(contentsOf: localIdentifiers.map { ArchiveExportFailure(identifier: $0, message: summary) })
                continue
            }

            let missingOnly = uuidRows.allSatisfy { $0.missing == true }
            if missingOnly {
                failures.append(contentsOf: localIdentifiers.map {
                    ArchiveExportFailure(identifier: $0, message: "Export reported this item as missing")
                })
                continue
            }

            let hasOutcome = uuidRows.contains { row in
                row.exported == true || row.new == true || row.updated == true || row.skipped == true
            }
            if !hasOutcome {
                failures.append(contentsOf: localIdentifiers.map {
                    ArchiveExportFailure(identifier: $0, message: "Export finished, but no result was reported for this item")
                })
                continue
            }

            succeededIdentifiers.append(contentsOf: localIdentifiers)
        }

        try? fileManager.removeItem(at: tempDir)

        if succeededIdentifiers.isEmpty {
            continue
        }

        exportedGroups.append(
            ArchiveExportGroupResult(destinationPath: destination.path, localIdentifiers: Array(Set(succeededIdentifiers)))
        )
    }

    return ArchiveExportBatchResult(exportedGroups: exportedGroups, failures: failures)
}

nonisolated private func archiveImageRelativePaths(under archiveTreeRoot: URL) throws -> Set<String> {
    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: archiveTreeRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        return []
    }
    let supportedExtensions: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "tif", "tiff"]
    let keys: Set<URLResourceKey> = [.isRegularFileKey]
    guard let enumerator = fileManager.enumerator(
        at: archiveTreeRoot,
        includingPropertiesForKeys: Array(keys),
        options: [.skipsPackageDescendants, .skipsHiddenFiles]
    ) else { return [] }

    let rootComponents = archiveTreeRoot.standardizedFileURL.pathComponents
    var results = Set<String>()
    for case let fileURL as URL in enumerator {
        if fileURL.lastPathComponent.hasPrefix(".") { continue }
        let ext = fileURL.pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else { continue }
        let standardized = fileURL.standardizedFileURL
        let values = try? standardized.resourceValues(forKeys: keys)
        guard values?.isRegularFile == true else { continue }

        let fileComponents = standardized.pathComponents
        guard fileComponents.count > rootComponents.count else { continue }
        guard Array(fileComponents.prefix(rootComponents.count)) == rootComponents else { continue }
        let relativeComponents = Array(fileComponents.dropFirst(rootComponents.count))
        guard !relativeComponents.isEmpty else { continue }
        if relativeComponents.first == ".librarian-thumbnails" { continue }
        let relativePath = relativeComponents.joined(separator: "/")
        results.insert(relativePath)
    }
    return results
}

nonisolated private func reconcileNewlyExportedArchiveDuplicates(
    archiveTreeRoot: URL,
    preExportRelativePaths: Set<String>,
    database: DatabaseManager
) throws -> ArchiveExportDedupeSummary {
    let postExportRelativePaths = try archiveImageRelativePaths(under: archiveTreeRoot)
    let newRelativePaths = postExportRelativePaths.subtracting(preExportRelativePaths)
    return try reconcileArchiveDuplicates(
        archiveTreeRoot: archiveTreeRoot,
        newRelativePaths: newRelativePaths,
        database: database,
        flow: "set_aside_export"
    )
}

nonisolated private func reconcileArchiveDuplicates(
    archiveTreeRoot: URL,
    newRelativePaths: Set<String>,
    database: DatabaseManager,
    flow: String
) throws -> ArchiveExportDedupeSummary {
    let fileManager = FileManager.default
    guard !newRelativePaths.isEmpty else {
        return ArchiveExportDedupeSummary(suppressedCount: 0, movedToNeedsReviewCount: 0, failureCount: 0)
    }

    let keys: Set<URLResourceKey> = [.isRegularFileKey]
    let rootComponents = archiveTreeRoot.standardizedFileURL.pathComponents
    let newURLSet = Set(newRelativePaths.map {
        archiveTreeRoot.appendingPathComponent($0, isDirectory: false).standardizedFileURL
    })

    var seenHashes = Set<String>()
    var canonicalPathByHash: [String: String] = [:]
    if let enumerator = fileManager.enumerator(
        at: archiveTreeRoot,
        includingPropertiesForKeys: Array(keys),
        options: [.skipsPackageDescendants, .skipsHiddenFiles]
    ) {
        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent.hasPrefix(".") { continue }
            let standardized = fileURL.standardizedFileURL
            if newURLSet.contains(standardized) { continue }
            let values = try? standardized.resourceValues(forKeys: keys)
            guard values?.isRegularFile == true else { continue }

            let fileComponents = standardized.pathComponents
            guard fileComponents.count > rootComponents.count else { continue }
            guard Array(fileComponents.prefix(rootComponents.count)) == rootComponents else { continue }
            let relativeComponents = Array(fileComponents.dropFirst(rootComponents.count))
            guard !relativeComponents.isEmpty else { continue }
            if relativeComponents.first == ".librarian-thumbnails" { continue }
            if relativeComponents.first == "Already in Photo Library" { continue }
            if relativeComponents.first == "Needs Review" { continue }

            if let hash = try? sha256Hex(ofFileAt: standardized) {
                seenHashes.insert(hash)
                if canonicalPathByHash[hash] == nil {
                    canonicalPathByHash[hash] = relativeComponents.joined(separator: "/")
                }
            }
        }
    }

    var suppressedCount = 0
    var movedToNeedsReviewCount = 0
    var failureCount = 0
    var events: [ArchiveDuplicateEvent] = []
    events.reserveCapacity(newRelativePaths.count)
    let needsReviewRoot = archiveTreeRoot.appendingPathComponent("Needs Review", isDirectory: true)

    for relativePath in newRelativePaths.sorted() {
        let sourceURL = archiveTreeRoot.appendingPathComponent(relativePath, isDirectory: false).standardizedFileURL
        guard fileManager.fileExists(atPath: sourceURL.path) else { continue }
        do {
            let hash = try sha256Hex(ofFileAt: sourceURL)
            if seenHashes.contains(hash) {
                try fileManager.removeItem(at: sourceURL)
                suppressedCount += 1
                events.append(
                    ArchiveDuplicateEvent(
                        id: UUID().uuidString,
                        incomingRelativePath: relativePath,
                        canonicalRelativePath: canonicalPathByHash[hash],
                        incomingSHA256: hash,
                        reason: "exact_match",
                        flow: flow,
                        createdAt: Date()
                    )
                )
            } else {
                seenHashes.insert(hash)
                canonicalPathByHash[hash] = relativePath
            }
        } catch {
            do {
                try fileManager.createDirectory(at: needsReviewRoot, withIntermediateDirectories: true)
                let destinationURL = needsReviewRoot.appendingPathComponent(relativePath, isDirectory: false)
                let parent = destinationURL.deletingLastPathComponent()
                try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
                let finalDestination = uniqueDestinationURL(
                    in: parent,
                    preferredName: destinationURL.lastPathComponent,
                    fileManager: fileManager
                )
                try fileManager.moveItem(at: sourceURL, to: finalDestination)
                movedToNeedsReviewCount += 1
                events.append(
                    ArchiveDuplicateEvent(
                        id: UUID().uuidString,
                        incomingRelativePath: relativePath,
                        canonicalRelativePath: nil,
                        incomingSHA256: nil,
                        reason: "indeterminate_kept",
                        flow: flow,
                        createdAt: Date()
                    )
                )
            } catch {
                failureCount += 1
            }
        }
    }

    if !events.isEmpty {
        try? database.assetRepository.saveArchiveDuplicateEvents(events)
    }
    return ArchiveExportDedupeSummary(
        suppressedCount: suppressedCount,
        movedToNeedsReviewCount: movedToNeedsReviewCount,
        failureCount: failureCount
    )
}

nonisolated private func uniqueDestinationURL(
    in directory: URL,
    preferredName: String,
    fileManager: FileManager
) -> URL {
    var candidate = directory.appendingPathComponent(preferredName, isDirectory: false)
    guard fileManager.fileExists(atPath: candidate.path) == true else { return candidate }
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

nonisolated private func sha256Hex(ofFileAt url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
        let chunk = handle.readData(ofLength: 65_536)
        if chunk.isEmpty { break }
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02hhx", $0) }.joined()
}

nonisolated private func shouldRetryWithoutExifTool(outputText: String) -> Bool {
    let lower = outputText.lowercased()
    guard lower.contains("exiftool") else { return false }
    return lower.contains("not found")
        || lower.contains("no such file")
        || lower.contains("could not find")
}

nonisolated private func archiveRootForExport(_ rootURL: URL) -> URL {
    rootURL.appendingPathComponent("Archive", isDirectory: true)
}

nonisolated private func withArchiveRootAccess<T>(root: URL, operation: () throws -> T) throws -> T {
    let didAccess = root.startAccessingSecurityScopedResource()
    defer {
        if didAccess {
            root.stopAccessingSecurityScopedResource()
        }
    }
    return try operation()
}

nonisolated private func persistExportReportJSON(reportData: Data, runToken: String) -> URL? {
    let fileManager = FileManager.default
    let dir = appSupportDirectory().appendingPathComponent("export_reports", isDirectory: true)
    do {
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let timestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent("osxphotos-report-\(timestamp)-\(runToken).json", isDirectory: false)
        try reportData.write(to: url, options: .atomic)
        return url
    } catch {
        logErrorAsync("Failed to persist osxphotos report: \(error.localizedDescription)")
        return nil
    }
}

nonisolated private func appSupportDirectory() -> URL {
    let appSupport = try? FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
    )
    return (appSupport ?? URL(fileURLWithPath: NSTemporaryDirectory()))
        .appendingPathComponent("com.chrislemarquand.Librarian", isDirectory: true)
}

nonisolated private func renderShellCommand(arguments: [String]) -> String {
    let escaped = arguments.map { arg -> String in
        if arg.contains(where: { $0 == " " || $0 == "\"" || $0 == "'" }) {
            return "\"\(arg.replacingOccurrences(of: "\"", with: "\\\""))\""
        }
        return arg
    }
    return "osxphotos \(escaped.joined(separator: " "))"
}

nonisolated private func logInfoAsync(_ message: String) {
    Task { @MainActor in
        AppLog.shared.info(message)
    }
}

nonisolated private func logErrorAsync(_ message: String) {
    Task { @MainActor in
        AppLog.shared.error(message)
    }
}

nonisolated private func logInfoMultilineAsync(prefix: String, text: String) {
    Task { @MainActor in
        AppLog.shared.infoMultiline(prefix: prefix, text: text)
    }
}

// MARK: - Supporting types

struct IndexingProgress: Equatable {
    enum State: Equatable {
        case idle
        case running(completed: Int, total: Int)
        case failed(String)
    }

    private let state: State

    static let idle = IndexingProgress(state: .idle)
    static func running(completed: Int, total: Int) -> IndexingProgress {
        IndexingProgress(state: .running(completed: completed, total: total))
    }
    static func failed(_ message: String) -> IndexingProgress {
        IndexingProgress(state: .failed(message))
    }

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    var statusText: String {
        switch state {
        case .idle:
            return "Idle"
        case .running(let completed, let total):
            if total > 0 {
                return "Updating Catalogue (\(completed.formatted()) / \(total.formatted()))"
            }
            return "Updating Catalogue"
        case .failed(let message):
            return "Failed: \(message)"
        }
    }

    var fractionComplete: Double? {
        guard case .running(let completed, let total) = state, total > 0 else { return nil }
        return min(max(Double(completed) / Double(total), 0), 1)
    }
}

final class AppLog: @unchecked Sendable {
    static let shared = AppLog()

    private let queue = DispatchQueue(label: "\(AppBrand.identifierPrefix).log")
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private init() {}

    func info(_ message: String) {
        append(level: "INFO", message: message)
    }

    func error(_ message: String) {
        append(level: "ERROR", message: message)
    }

    func infoMultiline(prefix: String, text: String) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.isEmpty {
            info("\(prefix):")
            return
        }
        for line in lines {
            info("\(prefix): \(line)")
        }
    }

    func readRecentLines(maxLines: Int) -> String {
        queue.sync {
            guard let data = try? Data(contentsOf: logURL()),
                  let text = String(data: data, encoding: .utf8) else {
                return ""
            }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.count <= maxLines {
                return text
            }
            return lines.suffix(maxLines).joined(separator: "\n")
        }
    }

    private func append(level: String, message: String) {
        queue.async {
            let line = "[\(self.formatter.string(from: Date()))] [\(level)] \(message)\n"
            let url = self.logURL()
            do {
                let handle: FileHandle
                if FileManager.default.fileExists(atPath: url.path) {
                    handle = try FileHandle(forWritingTo: url)
                    try handle.seekToEnd()
                } else {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                    handle = try FileHandle(forWritingTo: url)
                }
                if let data = line.data(using: .utf8) {
                    try handle.write(contentsOf: data)
                }
                try handle.close()
            } catch {
                // Best-effort logging; ignore write failures.
            }

            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .librarianLogUpdated, object: nil)
            }
        }
    }

    private func logURL() -> URL {
        let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = (appSupport ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("com.chrislemarquand.Librarian", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("librarian.log")
    }
}
