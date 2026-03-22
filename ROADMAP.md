# Roadmap

Last updated: 2026-03-21

This file is the single source of truth for release planning.

## Product Direction

- Distribution target: notarized direct distribution (non-App Store).
- Security posture: credible/safe defaults without App Sandbox constraints.
- Reliability priority: archive trust boundary and import/export correctness before new feature breadth.

## Status Key

- `[Done]` shipped in current codebase
- `[In Progress]` partially shipped and actively being completed
- `[Planned]` approved but not started
- `[Parked]` intentionally deferred

## Current Baseline (Shipped)

- Queue set in product: `Screenshots`, `Duplicates`, `Low Quality`, `Documents`, `WhatsApp`, `Accidental`, `Set Aside`, `Archive`.
- Analysis pipeline: osxphotos query + Vision pass + score/label/fingerprint/file-size/person persistence.
- Archive creation + relink model with control folder (`.librarian`) and `archive.json` metadata.
- Archive move/relink guardrails, including recursive destination protections.
- Startup/offline/write-access handling for archive availability.
- Archive export progress workflow sheet with completion summary + log access.
- Archive import workflow sheet used by both:
  - Path A: user-triggered import from Librarian.
  - Path B: Finder-detected unorganized files routed through review/import flow.
- Import dedupe behavior:
  - Path A leaves duplicates in source location (no “Already in Photo Library” folder creation).
  - Path B keeps archive organization and relocates rejected duplicates into `Already in Photo Library` while preserving folder tree.
- Sidebar/archive count synchronization after export and archive index refresh.
- Multi-library safety gate baseline:
  - detect system photo library change,
  - pause archive import/export when binding mismatch risk exists,
  - prompt to rebind/select archive/create archive.
- Interaction baseline:
  - Quick Look (`Space`),
  - context menus with right-click target normalization,
  - sidebar badges,
  - keyboard parity (`Cmd+A`, put-back shortcut, Tab pane focus cycling).
- Runtime dependency hardening:
  - bundled ExifTool integrated,
  - osxphotos execution consolidated behind a single runner boundary shared by export + analysis.

## v1.0 — Trusted Core Release

Goal: stable daily-driver release with trustworthy archive behavior and distribution readiness.

### Must Ship

- Archive reliability + trust boundary:
  - [Done] stale `exporting` recovery at startup
  - [Done] mixed outcome handling and clearer per-item failure visibility
  - [Done] interrupted-run recovery baseline
  - [Done] archive move destination safety regressions covered
  - [Done] archive metadata/control writes use crash-safe atomic updates
- Import/export workflow convergence:
  - [Done] SharedUI-driven import sheet for both Path A and Path B entry points
  - [Done] Finder-detected import review path triggers the same sheet
  - [Done] dedupe placement rules differ correctly by Path A vs Path B
- Process/runtime hardening:
  - [Done] ExifTool bundled and runtime-resolved
  - [Done] osxphotos launch boundary consolidated for export + analysis
- Core UX and operability:
  - [Done] archive progress + completion messaging model
  - [Done] “Show in Finder” opens archive folder (not parent)
  - [Done] settings reflects active system library/archive linkage state

### Remaining To Close v1.0

- Indexing & analysis UX (see `docs/indexing-analysis-ux.md`):
  - [Planned] hide Low Quality queue until analysis has run at least once (spec-mandated correctness fix)
  - [Planned] post-index non-modal info bar prompting user to run analysis
- Boxes quality pass (single coordinated sweep across all boxes):
  - [In Progress] Duplicates tuning and regression checks
  - [In Progress] Documents OCR/vision false-positive tuning
  - [In Progress] Low Quality/Screenshots/Accidental consistency checks
  - [In Progress] WhatsApp quality + query/count/UI consistency
  - [Planned] complete shared quality-bar tests per box (classifier/query/count/UI wiring)
- Multi-library safety gate UX polish:
  - [In Progress] eliminate technical/fallback phrasing in mismatch prompts
  - [Planned] improve first-run/linking copy and naming clarity for library/archive references
- Test gate completion:
  - [In Progress] finalize/expand state-transition automated coverage for trust-boundary flows

### v1.0 Out of Scope

- Queue keep/reset empty-state redesign
- Restore feature UX
- Automation hooks and preset profiles
- Large taxonomy expansion beyond current boxes

## v1.1 — Stabilization + UX Hardening

Goal: remove rough edges from 1.0 usage and improve resilience/clarity without widening domain scope.

### Planned

- Queue keep/reset empty-state UX and cleanup of temporary Settings reset controls.
- Inspector readability pass for long fields (archive paths/errors/metadata).
- Archive robustness follow-through:
  - volume identity tracking (same path, different disk safeguards),
  - operation journal + reconciliation pass,
  - read-only/permission-drift handling polish,
  - slow-disk/network-volume responsiveness tuning.
- SharedUI extraction follow-through for interaction primitives introduced in 1.0.
- Optional background archive change monitoring (FSEvents) if passive refresh remains a UX pain point.

## v1.2+

- Analysis lifecycle improvements (last-analysed date in Settings, `.indexing` sidebar item removal) — see `docs/indexing-analysis-ux.md` for full plan.
- Smart/query view expansion and incremental indexing/reconciliation tooling.
- Workflow expansion and richer archive auditing/reporting.

## Parking Lot (Design Decisions Needed)

- Long-term data model for multiple Photos libraries:
  - separate DB per library vs single DB + stronger reconciliation/migration.
- Type-then-date archive export routing policy:
  - finalize content-type routing model before implementation.
- Archive pipeline extensions:
  - export presets/profiles,
  - richer post-export audit reports,
  - automation hooks.

## SharedUI Tracking

- [Done] Quick Look keyboard monitor extraction and shared wiring.
- [Done] Context-menu right-click selection normalization in SharedUI.
- [Done] Shared keyboard utility support used by Librarian parity behavior.
