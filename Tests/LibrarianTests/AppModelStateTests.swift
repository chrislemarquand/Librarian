import Testing
@testable import Librarian

@Test func windowSubtitlePriorityPrefersActiveOperationsBeforeStatus() {
    let subtitle = LibrarianWindowSubtitlePriority.compute(
        isSendingArchive: true,
        isImportingArchive: true,
        importStatusText: "Importing 2 / 10…",
        isIndexing: true,
        indexingStatusText: "Running (4 / 12)",
        isAnalysing: true,
        analysisStatusText: "Scanning…",
        pendingAnalysisCount: 5,
        archiveRootAvailability: .unavailable,
        statusMessage: "Set Aside: 3 photo(s)."
    )
    #expect(subtitle == "Importing 2 / 10…")
}

@Test func windowSubtitlePriorityFallsBackToArchiveAndStatusStates() {
    let archiveUnavailable = LibrarianWindowSubtitlePriority.compute(
        isSendingArchive: false,
        isImportingArchive: false,
        importStatusText: "",
        isIndexing: false,
        indexingStatusText: "Idle",
        isAnalysing: false,
        analysisStatusText: "",
        pendingAnalysisCount: 0,
        archiveRootAvailability: .unavailable,
        statusMessage: "Set Aside: 3 photo(s)."
    )
    #expect(archiveUnavailable == ArchiveSettings.ArchiveRootAvailability.unavailable.userVisibleDescription)

    let pendingAnalysis = LibrarianWindowSubtitlePriority.compute(
        isSendingArchive: false,
        isImportingArchive: false,
        importStatusText: "",
        isIndexing: false,
        indexingStatusText: "Idle",
        isAnalysing: false,
        analysisStatusText: "",
        pendingAnalysisCount: 7,
        archiveRootAvailability: .available,
        statusMessage: "Set Aside: 3 photo(s)."
    )
    #expect(pendingAnalysis == "7 photos to analyse")

    let statusMessage = LibrarianWindowSubtitlePriority.compute(
        isSendingArchive: false,
        isImportingArchive: false,
        importStatusText: "",
        isIndexing: false,
        indexingStatusText: "Idle",
        isAnalysing: false,
        analysisStatusText: "",
        pendingAnalysisCount: 0,
        archiveRootAvailability: .available,
        statusMessage: "Set Aside: 3 photo(s)."
    )
    #expect(statusMessage == "Set Aside: 3 photo(s).")
}
