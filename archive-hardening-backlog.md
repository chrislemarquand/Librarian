# Archive Hardening Backlog

Date: 2026-03-21
Scope: Archive view/function/folder implementation review follow-ups

## Must-Fix

1. Multi-library safety gate
- Detect active Photos library mismatch and block archive import/export/dedupe until user re-indexes or confirms switch.
- Why: prevents wrong-library dedupe/index decisions.
- Source anchor: `ROADMAP.md:194`

2. Path B dedupe scope must include organized-path files
- Don’t limit Path B review to unorganized files only; add a scope that can dedupe external additions even if already in canonical folders.
- Why: current behavior misses duplicates placed directly into canonical folders.
- Source anchor: `Sources/Librarian/Shell/ArchiveImportSheetView.swift:362`

3. Explicit policy for indeterminate exact checks
- Add policy/UX for files that cannot be verified exactly (e.g. PhotoKit original unavailable locally):
  - Conservative default: do not auto-import; surface in review.
  - Permissive mode only when user explicitly allows.
- Why: current default can import true duplicates.
- Source anchor: `Sources/Librarian/Model/ArchiveImportCoordinator.swift:95`

## Should-Fix

4. Banner dismissal timing
- Only dismiss Path B banner after successful sheet completion, not on click.
- Why: avoids prompt disappearing on cancel.
- Source anchor: `Sources/Librarian/Shell/ContentController.swift:904`

5. Path B summary semantics
- Report separate counters:
  - accepted
  - organizedMoved
  - quarantinedAsDuplicate
  - failed
- Why: current “imported” count can be misleading when files were already organized.
- Source anchor: `Sources/Librarian/Shell/ArchiveImportSheetView.swift:325`

6. Candidate cap escape hatch
- If prefilter candidate count hits cap (500), surface warning and support deeper scan (paged or user-confirmed).
- Why: hard cap can hide true duplicates.
- Source anchor: `Sources/Librarian/Database/AssetRepository.swift:928`

7. Move Path B execution out of sheet session
- Refactor filesystem execution into a model/service (`ArchiveImportEngine`); keep sheet UI as orchestration only.
- Why: lower UI coupling, better testability.
- Source anchor: `Sources/Librarian/Shell/ArchiveImportSheetView.swift:279`

## Nice-to-Have

8. Archive watcher (FSEvents)
- Add FSEvents watcher + debounced re-index for live updates after Finder edits.
- Why: reduces stale archive counts/view states.
- Source anchor: `ROADMAP.md:196`

## Suggested Order

1. Must-Fix 1-3
2. Should-Fix 4-6
3. Should-Fix 7
4. Nice-to-Have 8
