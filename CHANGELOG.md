# Changelog

All notable changes to Librarian are tracked here.

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
