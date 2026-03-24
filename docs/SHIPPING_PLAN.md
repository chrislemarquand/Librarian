# Shipping Plan

_2026-03-23_

A focused, sequential plan to get Librarian to a shippable v1. Replaces the v1.0/v1.1 milestone structure. Work is organised into four blocks done in order — don't start block N+1 until block N is committed and tested.

---

## Current state

Blocks 1 and 2 are complete. Export defaults are correct, stale export recovery works, archive relink detection works, and the multi-library binding system has been replaced with a simple launch-time path check.

What remains before shipping:

1. ~~**Incorrect defaults**~~ ✅ Fixed in Block 1.
2. ~~**Safety gates**~~ ✅ Fixed in Block 2.
3. **Discovery/polish** — analysis is invisible, Low Quality shows empty instead of hiding, no notice bar for in-progress states.

---

## Block 1: Export correctness ✅

- [x] **1. Fix export option defaults** — defaults changed to `.on` for both originals and Live Photos.
- [x] **2. Reset stale export state on launch** — already implemented in `setup()` via `recoverStaleArchiveExports()`.
- [x] **3. Remove `kindThenDate` folder layout option** — `ArchiveFolderLayout` enum, radio buttons, and `importDestinationRoot` branching removed. Flat `YYYY/MM/DD` only.

---

## Block 2: Safety gates ✅

- [x] **4. Fix archive relink detection** — already implemented. `archiveRootAvailability` checks both `Archive/` and `Archive/.librarian/` subfolder existence (lines 471-480 of AppModel.swift).
- [x] **5. Simplify multi-library binding** — replaced ~830 lines of binding infrastructure (fingerprinting, evaluator, coupling registry, mismatch prompt, write gate) with a simple launch-time library path check (~40 lines). If the Photos library path has changed since last use, shows a one-button informational alert. Deleted: `ArchiveLibraryBindingEvaluator.swift`, `ArchiveLibraryCouplingRegistry.swift`, `ArchiveLibraryMismatchPrompt.swift`, `PhotoLibraryFingerprintService.swift`. Removed: `ArchiveWriteGateDecision`, `ArchiveWriteOperation`, 6-second polling evaluator, Combine binding observers in `MainSplitViewController`, write-gate checks from import/export/organize paths.

**Gate:** Exports are now correct (Block 1) and the app warns on library changes (Block 2).

---

## Block 3: Discovery and notice bars ✅

- [x] **6. Analysis-dependent queue empty states** — Instead of hiding Low Quality from the sidebar, empty analysis-dependent queues (Low Quality, Duplicates, Documents) now show a placeholder with "Run analysis to find items for this queue" + "Analyse Now" button (using `ContentUnavailableView`'s native actions slot). Added `actionTitle`/`action` parameters to `PlaceholderView` in SharedUI.
- [x] **7. Build NoticeBar in SharedUI** — SwiftUI-first: `NoticeBarState` (@Observable), `NoticeBarView` (SwiftUI, HStack with `.bar` background), `NoticeBar` (NSView wrapper with NSHostingView). Fixed 40pt height, visibility-driven constraint toggling.
- [x] **8. Wire NoticeBar into ContentController** — Replaced hand-rolled `archivedNoticeBar` (5 AppKit views, manual constraints). Single `updateNoticeBar()` method covers: archive view unorganised files + Review Import/Not Now; analysis-dependent queues + isAnalysing + has items → "Analysis in progress — more items may appear."
- [x] **9. Show last-analysed date in Settings** — `lastAnalysedDate()` query (MAX of analysedAt and visionAnalysedAt). Shown as relative date ("2 hours ago") in the analysis status label.

**Gate:** App is correct, safe, and discoverable.

---

## Block 4: Cleanup before ship

- [ ] **10. Move archive services out of ContentController**
  `ArchiveOrganizer`, `ArchiveIndexer`, `ArchivedThumbnailService` belong in Model layer. Pure reorganisation, no behaviour change.

- [ ] **11. Remove redundant Indexing sidebar item**
  Indexing state already shown in toolbar/subtitle. The sidebar item shows an empty placeholder.

- [ ] **12. Full flow test pass**
  Exercise: index → analyse → browse queues → set aside → export → verify archive → delete from Photos. Repeat on a secondary Photos library to verify the library-changed alert fires.

---

## Out of scope

Real things that don't block a usable v1:

- Restore workflow (reimport from archive to Photos)
- Photos album creation
- Story/meaningfulness engine
- OpenAI integration
- osxphotos XPC isolation (acceptable as direct `Process()` for direct distribution)
- `NSHostingController` → `NSHostingView` cleanup
- SharedUI audit consolidation items (zoom anchor, ClosureMenuItem, etc.)
- Swift 6 migration cleanup
