# Roadmap

Last updated: 2026-03-21

## Planning Principles

- Version scope is capability-based, not date-based.
- v1.0 is distribution-ready (not dev-only).
- The archive pipeline is the trust boundary; reliability items there take priority over new UX.
- Do not plan already-shipped features as new work.

## Implemented Baseline (Do Not Re-Plan)

These are already present in code and should be treated as shipped baseline:

- Core queue set currently implemented: `Screenshots`, `Duplicates`, `Low Quality`, `Documents`, plus archive `Set Aside`.
- Library analysis pipeline (osxphotos query + Vision pass + import of scores/labels/fingerprints/file size/person counts).
- Create New Archive flow with preflight scan, dedupe, import summary, and archive-root switch.
- Multi-selection inspector placeholder (`X Photos Selected`).

## Decision Log (Approved / Rejected / Delayed)

### Approved

- Reset stale `exporting` archive rows at startup to recover from interrupted runs.
- Add an export progress sheet with clear completion counts and log access.
- Keep direct notarized distribution as the release target (not App Store / sandbox track for v1.0).
- Keep osxphotos process-boundary hardening (XPC or equivalent) as reliability architecture work, not a distribution gate.
- Add Quick Look (`Space`) for selected items.
- Add gallery context menus with auto-select-on-right-click behavior.
- Add sidebar badges for at-a-glance counts.
- Add keyboard parity bundle:
  - `Cmd+A` select visible
  - put-back shortcut
  - Tab pane cycling
- Add archive trust-boundary automated test baseline.

### Approved with Custom Direction

- Export flags behavior (`--skip-original-if-edited`, `--skip-live`):
  - keep behavior behind explicit user-approved export toggles in Settings.
  - default behavior and copy must be explicit and reversible.

### Delayed

- Queue keep-reset empty-state UX (replace Settings-only reset controls).

### Rejected

- `Review Later` queue.
  - Reason: overlaps existing queues.
- Subtitle-only success feedback for archive completion.
  - Reason: explicit modal success confirmation is preferred.

## Release Plan

## v1.0 — Trusted Core + Distribution Readiness

Goal: stable daily-driver release with safe archive trust boundary and release-safe process model.

Status key: `[Done]`, `[Partial]`, `[Planned]`

### In

- Archive pipeline hardening:
  - [Done] startup reset of stale `exporting` rows
  - [Done] retry-safe failure handling and clearer per-item failure visibility
  - [Done] improved partial-success summaries
  - [Done] archive move guardrails to prevent recursive self-copy when destination resolves inside current archive
- Export UX:
  - [Done] progress sheet (indeterminate + status line + completion summary + log access)
- osxphotos boundary:
  - [Planned] consolidate export and analysis subprocess launching behind a single internal runner boundary (XPC optional)
- Export behavior controls:
  - [Done] add user-visible toggles for edited/live export handling (the approved flags decision)
- Runtime dependency hardening:
  - [Done] bundle and validate ExifTool at app runtime so export behavior is not dependent on user machine installs
- Interaction baseline:
  - [Done] Quick Look (`Space`)
  - [Done] gallery context menus with view-aware actions and right-click target normalization
  - [Partial] keyboard parity (`Cmd+A`, put-back shortcut, Tab focus cycling)
- Vision tuning:
  - [Planned] Duplicates box: tune Vision-based perceptual similarity thresholds and signals to improve precision/recall
  - [Planned] Documents box: tune Vision/OCR-based document classifier to reduce false positives and improve coverage
- Box expansion:
  - [Planned] WhatsApp Box (smart view) with confidence-based classification:
    - album signal (`WhatsApp` album membership)
    - filename-pattern signal (WhatsApp export naming conventions)
    - optional public metadata signal where available
  - [Planned] persist `isWhatsApp` classification at index time with tests for classifier + sidebar counts + box fetch path
- Inspector completeness:
  - [Done] finalise Inspector fields, including Archive-view-specific metadata coverage
- Sidebar visibility:
  - [Done] item badges wired through `badgeText` + repository counts
- Trust-boundary test gate:
  - [Partial] state transitions
  - [Done] mixed export outcomes
  - [Done] deletion reconciliation
  - [Done] interrupted-run recovery
  - [Done] archive move destination safety regression coverage (inside-source blocked, parent-destination allowed, recursive-copy guard)
- External archive robustness baseline:
  - [Done] archive control folder (`.librarian`) with schema/version metadata and stable archive ID
  - [Done] archive relink flow for moved archives (internal ↔ external), with archive ID validation
  - [Done] startup/offline handling when archive volume is unavailable
  - [Done] write-access and free-space preflight before archive export/import
  - [Done] crash/disconnect-safe control-file writes (atomic writes for archive metadata and run artifacts)
  - [Done] async archive-view/badge/subtitle synchronization after archive index refresh

### Remaining Priority To Reach v1.0

- Finish keyboard parity (`Cmd+A`, explicit put-back shortcut, Tab pane focus cycle).
- Implement WhatsApp Box classification + indexing + view wiring.
- Tune Vision classifiers for Duplicates and Documents boxes (precision/recall and false-positive reduction).

### Out

- Queue keep-reset empty-state UX
- broader smart-view expansion and integrity tooling
- restore UI
- workflow automation hooks

## v1.1 — Stabilization + UX Hardening

Goal: remove rough edges from 1.0 and improve review speed without widening domain scope.

### In

- Queue keep-reset empty-state UX and cleanup of temporary Settings reset surface.
- Inspector polish and readability improvements for long archive/error fields.
- Additional archive UX hardening discovered during 1.0 use (non-breaking).
- SharedUI extraction follow-through for interaction primitives introduced in 1.0.
- External archive robustness follow-through:
  - volume identity tracking (same path, different disk safeguards)
  - operation journal + reconciliation pass for interrupted archive runs
  - read-only mount and permission-drift handling polish
  - slow-disk/network-volume behavior tuning (batching, responsiveness)

## v1.2 — Analysis and View Model Expansion

Goal: strengthen analysis lifecycle and scale query-driven views.

### In

- Analysis lifecycle improvements:
  - rerun policy
  - "last analysed" state visibility
  - refresh recommendations when library growth warrants it
- Smart/query view expansion beyond current queue set.
- Incremental indexing and integrity/reconciliation tooling.

## v1.3 — Workflow Expansion

Goal: deepen curation workflows built on stable 1.0–1.2 foundations.

### In

- Context-review style curation flows (day/event/trip-oriented review).
- Archive pipeline extension work directly supporting richer review workflows.

## v2.0 — Intelligence + Workflow Platform

Goal: first materially new generation beyond incremental queue and UX work.

### In

- Mature explainability/meaningfulness stack.
- Stronger context-aware recommendation workflows.
- Durable job orchestration and audit/replay/recovery improvements.
- Extensibility hooks for downstream archive workflows.
- Restore capability promoted toward user-facing product surface (if quality bar is met).

## SharedUI Work

These are cross-repo items discovered from Ledger/SharedUI audit and should be tracked as SharedUI-scoped work even when driven by Librarian needs.

- **[SharedUI] Quick Look Coordinator** — [Done]
  - Spacebar → Quick Look keyboard monitor extracted from Ledger into `ThreePaneSplitViewController.installContentKeyboardMonitor`. Both apps now use the shared implementation; `QuickLookPanelCoordinator` was already in SharedUI.

- **[SharedUI] Gallery Context-Menu Selection Infrastructure**
  - [Done] Extracted reusable right-click target normalization and shared menu-item helpers into SharedUI (`ContextMenuSupport`), then consumed from Ledger and Librarian.
  - Keep app-specific menu item actions local to each app (implemented).
  - Source reference: `Ledger/Sources/Ledger/BrowserGalleryView.swift`.

- **[SharedUI] Three-Pane Keyboard Focus Utility**
  - [Done] Spacebar → Quick Look routing extracted as `installContentKeyboardMonitor` in `ThreePaneSplitViewController`.
  - [Planned] Tab pane focus-cycling (sidebar ↔ content) — still app-specific in Ledger, not yet implemented in Librarian.
  - Source reference: `Ledger/Sources/Ledger/MainContentView.swift`.

## Open Items / Parking Lot

- **Multiple library handling follow-through** — Librarian now detects system library changes, updates UI state, and gates archive writes with archive-library binding prompts. Remaining design work is around long-term data model strategy: whether to maintain separate GRDB databases per Photos library or keep a single database with stronger reconciliation/migration rules when the active library changes.

- **FSEvents archive folder watching** — Currently the ArchiveIndexer only runs when the Archive view is opened (passive detection). If the user places files in the archive folder via Finder, they won't appear until the view is next opened and there's no badge update. A full solution requires: installing an FSEvents watcher on the archive root folder, triggering a re-index when changes are detected, updating the sidebar badge, and optionally auto-triggering the organize pass if unorganized files are detected. Parked in favour of passive detection for now.

- **Archive export routing (Type then Date layout)** — When the "Type then date" folder layout is selected, the export pipeline (Set Aside → osxphotos export) should route files into the correct top-level subfolder based on content type rather than dumping everything into a flat date structure. The routing logic needs to be defined — the original spec used a queue-based rule (Duplicates → `Photos/`, Screenshots/junk → `Other/`) but this no longer reflects the intended model. The correct routing rules should be agreed before implementation. This is blocked on export-pipeline routing design, not on App Store sandboxing. In the meantime the organizer (`ArchiveOrganizer`) falls back to routing everything to `Photos/` with a comment.

- Archive pipeline extensions:
  - export profiles/presets
  - richer post-export auditing/reporting
  - optional automation hooks
- Any future queue taxonomy changes should be additive and justified by measurable workflow gain.
