# Roadmap

## Immediate — Phase 4 Hardening

These are correctness issues identified during a codebase review on 2026-03-17. They should be
resolved before building further UX on top of the archive pipeline.

### 1) Fix Export Flags vs Spec

`AppModel.runOsxPhotosExportBatch` currently passes `--skip-original-if-edited` and `--skip-live`.
Both contradict spec decisions already locked in CLAUDE.md:

- `--skip-original-if-edited` → spec says export **both** original and edited versions.
- `--skip-live` → spec says Live Photos are supported in v1 (all five media types).

Either remove both flags (to honour the spec) or document a deliberate divergence in CLAUDE.md
before proceeding.

### 2) Reset Stale `exporting` Rows at Startup

If the app crashes or is force-quit during an archive send, rows remain in `exporting` state
permanently. They won't appear in the retry path and won't drain from the Set Aside queue.

Fix: in `AppModel.setup()`, after the database opens, reset any `archive_candidate` rows still
in `exporting` status to `failed` with an explanatory error string
(e.g. "Export interrupted — app was quit or crashed").

### 3) Export Progress Sheet (Ledger-style)

Currently the user sees only a toolbar spinner during an archive send, then an alert on
completion. For large batches this blocks UI silently for minutes.

Add a sheet on the main window visually aligned with Ledger's import sheet:
- Header + live status line (e.g. "Exporting 47 items…").
- Indeterminate progress indicator (osxphotos doesn't emit incremental progress).
- On completion: final counts (exported / failed / deleted).
- Actions: `Done`, `View Log`; optional `Cancel` only if cancellation can be safely wired.
- Keep SwiftUI content fully wrapped in AppKit sheet presentation (matching inspector pattern).

Backed by the existing job record in the database.

---

## Near Term

### 4) Queue Keep Decisions — Reset UX

Queue keep decisions (items dismissed from a queue via Keep) are currently reset per-queue via
buttons in the Settings window. The intended final UX is:

- When a queue is **empty** (all items either kept or set aside), show a contextual message in
  the empty state: "All items reviewed. Reset keep decisions to review again." with a direct
  action button.
- Remove the per-queue reset buttons from Settings once the empty-state UX is in place.

The Settings buttons remain as the mechanism while queues are actively being developed and
debugged.

### 5) Archive UX Hardening

- Improve per-item failure visibility in the Set Aside view — show an inline error badge or
  message for `failed` status items, not just in the log.
- Add explicit retry action for failed archive items (reset `failed → pending`, then re-run).
- Show clearer end-state summaries for partial success (exported vs failed vs deleted counts).

### 6) Inspector Enhancements

- Continue visual alignment with Ledger where appropriate.
- Ensure archive metadata/error fields remain clear and non-editable.
- Add compact formatting for long identifiers/paths while preserving full-value access.

### 7) Settings Expansion

- Add user-configurable export template settings (future-safe for folder/file naming rules).
- Persist and expose export-related toggles that currently live in code defaults.

---

## Medium Term

### 8) Library Analysis Pass

A user-initiated action (not a background process) that runs osxphotos in query mode, imports
enriched metadata into GRDB, and unlocks score-dependent queues and inspector fields.

**What it imports** (specific columns on `asset` table, no full JSON blob):
- Quality scores: overall aesthetic + component scores (noise, exposure, sharpness, etc.)
- `fileSizeBytes` — not available cheaply from PhotoKit; immediately useful for size-sorted curation
- `hasNamedPerson` bool + `namedPersonCount` int — photos with recognised people are higher value
- `labels` JSON string — Apple ML scene/object labels (e.g. "receipt", "document", "sunset")
- `perceptualFingerprint` — for exact duplicate detection

**UUID join:** osxphotos returns bare UUIDs; strip the `/L0/001` suffix from `localIdentifier`
before joining. Same logic already exists in the export batch path.

**UX:**
- Offered via a non-modal prompt after initial index completes ("Librarian can analyse your
  library for quality signals. This takes a few minutes and runs once.") with `Analyse` and
  `Not Now` options. Never a blocking setup step.
- Progress sheet (same pattern as export) — indeterminate indicator, status line, `Done` /
  `View Log` on completion.
- "Last analysed: [date]" shown in Settings. Refresh offered if asset count has grown
  significantly but not pushed aggressively.
- The Low Quality queue (and any other score-dependent views) are hidden until at least one
  analysis pass has completed. If the user somehow navigates to where they will appear, show
  a one-line explanation with a direct link to run analysis.

### 9) XPC Service for osxphotos

The spec (CLAUDE.md) requires the osxphotos helper to run in an XPC service, not as a direct
`Process()` subprocess. The current approach works in development but will hit sandboxing
entitlement checks at distribution. Covers both the export and analysis pass invocations.

The isolation boundary is already architecturally correct (osxphotos is user-initiated only,
never a passive reader). The work is formalising the process boundary into an XPC service and
updating entitlements.

### 10) Smart Views + Archive-Oriented Views

- Expand smart/sidebar views using query model rather than one-off hardcoded filters.
- Ensure queued-for-archive visibility rules remain central and reusable across future views.

### 11) Incremental Indexing and Data Integrity

- Continue reducing full rebuild scenarios.
- Add explicit integrity/reconciliation tools and diagnostics for edge cases (recovered photos,
  missing assets, external changes).

### 12) Test Coverage

Priority targets for the archive pipeline (the trust boundary):
- Archive state machine transitions (`pending → exporting → exported → deleted`, all failure paths).
- Mixed export outcomes (partial success batch).
- Deletion reconciliation (exported but not deleted case).
- Photo library change deltas and delta accumulation.

### 13) Ledger UI Parity — Keyboard & Selection

Patterns present in Ledger that would make the apps feel consistent:

- **Cmd+A** — select all currently visible assets in the gallery.
- **Cmd+D** — deselect all (or map to Escape, which already clears selection).
- **Keyboard shortcut for Put Back** — the Set Aside view has no keyboard shortcut to
  put back selected items; batch review currently requires mouse.
- **Tab key cycling** — Tab to move focus between sidebar → gallery → inspector, matching
  Ledger's pane-cycling behaviour.
- **Multi-selection feedback in inspector** — when 2+ photos are selected, inspector should
  show "X photos selected" rather than the empty "No Selection" state.

### 14) Ledger UI Parity — Quick Look

Space bar should open Quick Look (`QLPreviewPanel`) for the currently selected photo(s).
Standard macOS behaviour for any image-browsing app; essential for evaluating whether a
photo is worth keeping before deciding to archive it. One of the highest-value missing
interactions relative to the workflow.

### 15) Ledger UI Parity — Gallery Context Menus

Right-click on a gallery item should show a context menu. Minimum useful set:
- **Set Aside** (primary action, all library/queue views)
- **Keep** (queue views only — dismisses from that queue)
- **Put Back** (Set Aside view only)
- Separator
- **Open in Photos**

Right-clicking an unselected item should auto-select it first (Ledger pattern).
Disabled items for inapplicable actions should be shown but inactive, not hidden.

### 16) Ledger UI Parity — Sidebar Badges

Show item counts as badges next to each sidebar item, giving at-a-glance visibility
across all views simultaneously. Particularly useful for queue views (how many screenshots,
duplicates, low-quality items remain). Uses `countForSidebarKind()` already in
`AssetRepository`. SwiftUI `.badge()` modifier in the sidebar cell view.

### 17) Ledger UI Parity — Subtitle Feedback for Archive Results

Ledger uses the window subtitle for non-critical operation feedback rather than modal
alerts. A clean full-success archive send currently shows an NSAlert; the subtitle pattern
is less disruptive. NSAlert remains appropriate for partial failures (items that couldn't
be exported or deleted), but clean success should use subtitle feedback:
e.g. "Archived 47 photos."

---

## Later

### 18) Archive Pipeline Extensions

- Optional export profiles/presets.
- Better post-export auditing and reporting UI.
- Optional automation hooks for downstream archive workflows.
