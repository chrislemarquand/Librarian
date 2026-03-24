# Changelog

All notable changes to Librarian are tracked here.

## 2026-03-24

### Changed
- Renamed the product spec document to `SPEC.MD` (repo root) and updated primary references.
- Converged planning docs to a single source: `ROADMAP.md` now replaces the separate shipping-plan document.
- Added `docs/CURRENT_STATE.md` as the implementation snapshot and `docs/README.md` as the canonical docs index.
- Aligned core docs (`CLAUDE.md`, `docs/ARCHITECTURE.md`, `docs/Engineering Baseline.md`) to current runtime/dependency behaviour.
- Tightened `SPEC.MD` + `CLAUDE.md` alignment so spec intent, execution priorities, and implementation snapshot references are explicit and consistent.

### Docs
- Archived superseded planning/handoff/investigation docs under `docs/_archive/2026-03-24-doc-convergence/`.
- Archived stale root-level handoff/planning docs under `docs/_archive/2026-03-24-root-docs-sweep/`.

## 2026-03-21

### Added
- Quick Look (`Space`) now works reliably in gallery and archive views, with behaviour identical to Ledger: single press opens, single press closes, no flash, no beep.

### Changed
- Spacebar → Quick Look keyboard handling extracted from Ledger into `SharedUI.ThreePaneSplitViewController` as `installContentKeyboardMonitor`. Root cause of Librarian's Quick Look bug (async dispatch creating a double-trigger race, and an overly broad focus guard) is eliminated by the shared implementation, which uses a synchronous call with a strict `contentView`-subtree focus check. Both apps now route through the same code path.
- `MainSplitViewController` keyboard handling reduced to a minimal `⌘⌃I` inspector-toggle monitor; all spacebar/Quick Look logic removed from app-specific code.

### Added
- Gallery context menus with view-aware actions:
  - PhotoKit-backed views: `Set Aside`, `Open in Photos`
  - Set Aside view: `Put Back`, `Open in Photos`, `Send Selected to Archive`
  - Archive view: `Reveal in Finder`
- Selection-scoped archive export path (`Send Selected to Archive`) using the same export sheet flow as bulk export.

### Changed
- Shared dependency synchronization advanced to SharedUI `v1.0.3` (local-path lockstep workflow).
- `Send to Archive` toolbar icon changed to `archivebox`.
- `Put Back` removed from toolbar; action remains available through contextual paths.
- Inspector item titles now display without file extensions for both PhotoKit and Archive selections.

### Fixed
- `Set Aside` toolbar enablement now stays disabled while browsing the `Set Aside` view.
- Shared-library badge placement adjusted to `6pt` top / `6pt` trailing inset for consistent thumbnail alignment.

## 2026-03-20

### Added
- App branding surface wiring and shared About panel integration via SharedUI menu/about helpers.
- Architecture guide documenting app shell and service boundaries (`docs/ARCHITECTURE.md`).

### Changed
- Bundle/project structure finalized for current app identifier and entitlements layout.
- Swift 6 baseline adopted in project/build settings; remaining strict-concurrency blockers cleaned up.
- Main window and shell wiring further aligned with SharedUI conventions (toolbar + key handling polish).
- Release tooling parity added (`archive`, `notarize`, `dmg`, release gates/check script updates).
- Replaced `ROADMAP.md` phase/backlog format with a versioned release roadmap (`v1.0` to `v2.0`).
- Updated roadmap scope to reflect implementation audit results (moved already-shipped capabilities to baseline status).
- Added explicit roadmap decision log entries for approved, delayed, and rejected items (including reject reasons).
- Added a dedicated `SharedUI Work` section in roadmap for cross-repo extraction items:
  - Quick Look coordinator
  - gallery context-menu selection infrastructure
  - three-pane keyboard focus utility
- Archive move preflight/error copy now includes explicit source/destination paths and clearer conflict context.
- Archive view subtitle/badge refresh is now synchronized with async archive content/index refresh completion.

### Fixed
- Restored app icon asset mapping after source/project structure moves.
- Restored gallery header fade styling regression.
- Prevented recursive `.../Librarian/Librarian/...` self-copy during archive move operations.

### Tests
- Added archive move regression tests for:
  - destination-inside-source rejection
  - parent destination acceptance
  - copy-phase recursive destination guard

## 2026-03-19

### Added
- Inspector rework with richer metadata sections.

### Changed
- Three-pane shell now inherits SharedUI `ThreePaneSplitViewController`.
- Sidebar migrated to SharedUI `AppKitSidebarController`.
- Placeholder, inspector/settings scaffolding, toolbar setup, window sizing, menu builders, key-code utilities, and alert helpers migrated to SharedUI infrastructure.

### Fixed
- Sidebar selection/inactive text color consistency.
- App menu/service wiring + toolbar identifier/restorable-state regressions during SharedUI migration.
- Initial inspector visibility corrected to start collapsed.

## 2026-03-17

### Added
- Native three-pane shell with AppKit split views (sidebar, gallery, inspector).
- Sidebar library filters: `All Photos`, `Recents` (last 30 days), `Favourites`, `Screenshots`.
- Archive workflow primitives:
  - Set Aside for Archive queue.
  - Put Back action for queued items.
  - Send to Archive action from toolbar/menu.
- Bundled `osxphotos` binary in app resources (`Librarian/Tools/osxphotos`).
- AppKit settings window with archive destination picker and manual rebuild control.
- SwiftUI read-only inspector embedded in AppKit wrapper, with preview + metadata sections.
- Gallery keyboard/pointer affordances:
  - Native multi-selection behavior.
  - Esc clears selection.
  - Zoom controls (+/-) and pinch-to-zoom wiring.

### Changed
- Gallery implementation moved to AppKit + PhotoKit-backed collection approach (instead of custom thumbnail pipeline).
- Gallery data loading now uses paged fetch + scroll-driven incremental loading, replacing the previous hard 3000-item grid cap.
- Sidebar implementation simplified toward native AppKit behavior and styling.
- Toolbar behavior improved:
  - Inspector toggle enabled and reliable.
  - Tracking separators aligned with split view dividers.
  - Spinner now indicates both indexing and archive export activity.
- Export destination layout changed from `Photos/Archive/...` to `Archive/...` under chosen root.
- Archive export pipeline refactored for robustness:
  - Single batch `osxphotos export` run per send operation (instead of per-item process launches).
  - Uses `--uuid-from-file`, `--report`, `--exportdb`, `--update`, `--update-errors`, and retry support.
  - Per-item success/failure reconciliation from osxphotos JSON report.
  - Only successfully exported items proceed to delete step in Photos.

### Fixed
- App launch/bootstrap issue where app opened without visible content window.
- Gallery white-gap rendering issue on initial load/scroll.
- Inspector toggle disabled state regression.
- Archive queue state regressions where mixed success/failure could leave incorrect queue status.
- False-negative export verification path that reported failure when export was valid.
- Random full re-index loops reduced via incremental PhotoKit change handling and reconciliation.

### Observability
- Log pane now includes much richer export diagnostics:
  - command/arguments,
  - exit codes,
  - process output,
  - saved report path,
  - report JSON content.
- Export reports are persisted under:
  - `~/Library/Application Support/com.librarian.app/export_reports/`
