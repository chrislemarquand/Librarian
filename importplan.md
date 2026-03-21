# Archive Import Convergence Plan (Path A + Path B)

Date: 2026-03-21
Owner: Librarian
Status: Planning only (no implementation started)

## Non-negotiable constraints

1. **SharedUI workflow sheet must be used.**
   - Do not recreate the workflow sheet primitives in Librarian.
   - Use components from:
     - `/Users/chrislemarquand/Xcode Projects/SharedUI/Sources/SharedUI/Workflow/WorkflowSheetComponents.swift`
   - Librarian may provide app-specific session/view-model logic, but visual container/sections/banners/details popover should come from SharedUI components.

2. **Path A and Path B converge to one import workflow surface.**
   - Triggering differs; execution pipeline should be shared.

3. **Path A never creates `Already in Photo Library`.**
   - Path A skips exact duplicates quietly and leaves source files untouched.

4. **Path B uses `Already in Photo Library` for exact duplicates.**
   - Preserve relative subtree when moving rejected files.

---

## Goal

Unify archive ingestion into one robust import pipeline and one workflow sheet UX for:

- **Path A:** user-triggered import via menu command `Import Photos into Archive…`.
- **Path B:** external files detected in archive folder from Finder, surfaced via current archive notice/banner trigger.

Both paths should apply exact dedupe against PhotoKit library using a hybrid strategy:
- cheap prefilter first,
- SHA-256 exact check only when needed,
- lazy hash caching in DB.

---

## Current state summary (for restart context)

- Path A currently uses `runAddPhotosToArchiveFlow` + `ArchiveImportCoordinator` and alert-based UX.
- Path A dedupe against PhotoKit is currently EXIF timestamp heuristic (not exact).
- Path B currently relies on passive `ArchiveIndexer.refreshIndex()` (mostly on archive view load) and has no exact dedupe gate.
- Roadmap confirms no FSEvents watcher yet; passive detection is expected at present.

---

## Target behavior

### Path A (menu/sheet)

1. User opens **Import Photos into Archive…**
2. Unified import sheet appears (SharedUI workflow components).
3. User picks source folder(s) in-sheet.
4. Preflight runs:
   - discover supported media,
   - source duplicate collapse,
   - exact dedupe against PhotoKit (hybrid hash strategy).
5. Execution runs:
   - accepted files copied into archive according to current folder layout settings,
   - rejected exact duplicates skipped (remain in source).
6. Completion summary shown in-sheet.

### Path B (banner/sheet)

1. Banner indicates files detected that need organizing and/or dedupe.
2. Banner action opens same unified import sheet in Path B mode.
3. Preflight runs on detected incoming files.
4. Execution runs:
   - accepted files organized into canonical archive tree,
   - rejected exact duplicates moved to:
     - `Archive/Already in Photo Library/<relative subtree preserved>`
5. Completion summary shown in-sheet.

---

## Architecture decisions

### A. Shared sheet surface (do not duplicate SharedUI primitives)

- Create an app-specific sheet view in Librarian that composes SharedUI workflow components (same pattern as `ArchiveExportSheetView`).
- Avoid custom duplicated container/banner/details widgets in Librarian.

### B. One shared import engine

- One execution engine with mode-specific reject handling:
  - Mode A: skip duplicates
  - Mode B: move duplicates to quarantine folder

### C. Hybrid exact dedupe strategy

- Prefilter candidates via cheap keys (size, capture-date when available).
- Compute SHA-256 only for narrowed PhotoKit candidates and incoming files.
- Persist newly computed PhotoKit hash lazily for reuse.
- Exact match decision only on hash equality.

### D. Keep indexing/reindex lightweight

- Do not do full eager hash backfill in normal re-index path.
- Optional low-priority warm-up later; not required for initial rollout.

---

## Concrete implementation slices

## Slice 1: DB migration + repository APIs (hash cache)

### Deliverables
- Add nullable hash field to PhotoKit asset records (`contentHashSHA256`).
- Add index for fast lookup.
- Repository methods for:
  - reading/writing hash by localIdentifier,
  - fetching prefilter candidate assets by size/date.

### Files
- `/Users/chrislemarquand/Xcode Projects/Librarian/Sources/Librarian/Database/Migrations.swift`
- `/Users/chrislemarquand/Xcode Projects/Librarian/Sources/Librarian/Database/AssetRepository.swift`

### Notes
- Prefer compact binary storage if existing patterns allow; otherwise normalized hex text.
- Keep migration backward-safe and additive.

## Slice 2: Shared exact dedupe service (hybrid)

### Deliverables
- New service to evaluate exact duplicate status for incoming files.
- Uses prefilter -> hash -> exact decision.
- Lazily persists PhotoKit hashes.

### Proposed new file
- `/Users/chrislemarquand/Xcode Projects/Librarian/Sources/Librarian/Model/ArchiveExactDedupeService.swift`

### Integration points
- Called from unified import engine for both modes.

## Slice 3: Unified import sheet scaffolding (SharedUI-based)

### Deliverables
- New import session model (`ObservableObject`) and sheet view.
- Uses SharedUI workflow components:
  - `WorkflowSheetContainer`
  - `WorkflowOptionGroup` (if needed)
  - `WorkflowInlineMessageBanner`
  - `WorkflowDetailsPopover`
- Supports states: idle/preflight/running/completed/failed.

### Proposed new files
- `/Users/chrislemarquand/Xcode Projects/Librarian/Sources/Librarian/Shell/ArchiveImportSheetView.swift`
- `/Users/chrislemarquand/Xcode Projects/Librarian/Sources/Librarian/Shell/ArchiveImportSheetPresenter.swift`

### Important
- Do not recreate the UI primitives from SharedUI in Librarian.

## Slice 4: Path A wiring to unified sheet

### Deliverables
- Replace current Add Photos flow entry with unified sheet presenter.
- Menu label becomes: `Import Photos into Archive…`.
- Enforce Path A invariant: no `Already in Photo Library` output.

### Files
- `/Users/chrislemarquand/Xcode Projects/Librarian/Sources/Librarian/AppDelegate.swift`
- `/Users/chrislemarquand/Xcode Projects/Librarian/Sources/Librarian/Shell/MainSplitViewController.swift`
- `/Users/chrislemarquand/Xcode Projects/Librarian/Sources/Librarian/Shell/ArchiveSettingsViewController.swift`
- `/Users/chrislemarquand/Xcode Projects/Librarian/Sources/Librarian/Model/ArchiveAddPhotosFlow.swift` (retire or redirect)

## Slice 5: Path B wiring to unified sheet

### Deliverables
- Replace current archive banner action with unified sheet launch in Path B mode.
- Pass detected external file candidates into session.

### Files
- `/Users/chrislemarquand/Xcode Projects/Librarian/Sources/Librarian/Shell/ContentController.swift`
- Optional helper file for detection/planning if needed.

## Slice 6: Unified execution core + mode-specific reject handling

### Deliverables
- Shared import execution path:
  - discovery
  - preflight classification
  - execution
  - summary
- Mode-specific reject handling:
  - Path A: skip exact duplicates.
  - Path B: move exact duplicates to `Already in Photo Library` preserving subtree.

### Files
- `/Users/chrislemarquand/Xcode Projects/Librarian/Sources/Librarian/Model/ArchiveImportCoordinator.swift`
- Optional shared types file if clarity needed.

## Slice 7: Persistence + reporting

### Deliverables
- Extend import run persistence to include source mode (A/B) and exact rejection counts.
- Feed details popover content from run summary.

### Files
- `/Users/chrislemarquand/Xcode Projects/Librarian/Sources/Librarian/Database/AssetRepository.swift`
- Migration for any additional run columns.

## Slice 8: Tests and acceptance hardening

### Deliverables
- Unit/integration tests for A/B behavior split:
  - A exact duplicate skipped, source untouched, no quarantine folder writes.
  - B exact duplicate moved to quarantine with subtree intact.
  - same date different bytes not rejected.
  - different date same bytes rejected.
- Verify no regressions to archive view indexing/placeholder behavior.

### Files
- `/Users/chrislemarquand/Xcode Projects/Librarian/Tests/LibrarianTests/LibrarianTests.swift`

---

## Data/logic details for resume

### Exact dedupe decision function

Given incoming file `F`:
1. Extract cheap keys from `F`:
   - byte size
   - capture date (EXIF if available) or nullable
2. Query candidate PhotoKit assets with matching cheap keys.
3. If no candidates -> not duplicate.
4. Compute SHA-256 for `F`.
5. For each candidate asset:
   - if cached hash exists, compare;
   - else fetch PhotoKit original bytes, hash, persist hash, compare.
6. Any equal hash -> exact duplicate.

### Path B subtree preservation rule

When moving rejected duplicate `R` detected under incoming scope root `S`:
- relative path = `R.path` relative to `S`
- destination = `Archive/Already in Photo Library/<relative path>`
- ensure parents created; collision-safe naming if destination exists.

### Organizer responsibility

After execution in both modes, run organizer pass so accepted files match current folder layout settings.

---

## Risks and mitigations

1. **PhotoKit original fetch latency (iCloud):**
   - Mitigate with prefilter narrowing and progress feedback in sheet.
2. **Large imports:**
   - Stream progress; avoid loading full byte arrays when hashing.
3. **Path B ambiguity of “incoming scope root”:**
   - Define deterministic scope root in detection phase and carry into run context.
4. **UI regressions from replacing alert flow:**
   - Mirror `ArchiveExportSheetView` interaction patterns.

---

## Definition of done

- Path A and Path B both launch one unified SharedUI-based import sheet.
- Exact dedupe uses hash-based final decision.
- Path A never writes duplicates into archive or quarantine.
- Path B moves exact duplicates into `Already in Photo Library` with tree preserved.
- Accepted files end in canonical archive structure per settings.
- Tests cover A/B divergence and exact-match correctness.
