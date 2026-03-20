# Roadmap

Last updated: 2026-03-20

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
- Move osxphotos process boundary to XPC for distribution readiness.
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

### In

- Archive pipeline hardening:
  - startup reset of stale `exporting` rows
  - retry-safe failure handling and clearer per-item failure visibility
  - improved partial-success summaries
- Export UX:
  - progress sheet (indeterminate + status line + completion summary + log access)
- osxphotos boundary:
  - replace direct subprocess usage with XPC service path for export and analysis invocations
- Export behavior controls:
  - add user-visible toggles for edited/live export handling (the approved flags decision)
- Runtime dependency hardening:
  - bundle and validate ExifTool at app runtime so export behavior is not dependent on user machine installs
- Interaction baseline:
  - Quick Look (`Space`)
  - gallery context menus
  - keyboard parity (`Cmd+A`, put-back shortcut, Tab focus cycling)
- Sidebar visibility:
  - item badges wired through `badgeText` + repository counts
- Trust-boundary test gate:
  - state transitions
  - mixed export outcomes
  - deletion reconciliation
  - interrupted-run recovery
- External archive robustness baseline:
  - archive control folder (`.librarian`) with schema/version metadata and stable archive ID
  - archive relink flow for moved archives (internal ↔ external), with archive ID validation
  - startup/offline handling when archive volume is unavailable
  - write-access and free-space preflight before archive export/import
  - crash/disconnect-safe control-file writes (atomic writes for archive metadata and run artifacts)

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

- **[SharedUI] Quick Look Coordinator**
  - Extract Ledger Quick Look controller patterns into SharedUI so Librarian consumes a shared coordinator.
  - Source reference: `Ledger/Sources/Ledger/AppModel+Preview.swift`.

- **[SharedUI] Gallery Context-Menu Selection Infrastructure**
  - Extend `SharedGalleryCollectionView` with reusable right-click target normalization (auto-select clicked item before menu generation).
  - Keep app-specific menu item actions local to each app.
  - Source reference: `Ledger/Sources/Ledger/BrowserGalleryView.swift`.

- **[SharedUI] Three-Pane Keyboard Focus Utility**
  - Add reusable pane focus-cycling utilities for sidebar/content/inspector.
  - Source reference: `Ledger/Sources/Ledger/MainContentView.swift`.

## Open Items / Parking Lot

- Archive pipeline extensions:
  - export profiles/presets
  - richer post-export auditing/reporting
  - optional automation hooks
- Any future queue taxonomy changes should be additive and justified by measurable workflow gain.
