# Changelog

All notable changes to Librarian are tracked here.

## 2026-04-23

### Fixed
- Export: bundled osxphotos binary is no longer re-signed during the release build. Re-signing changed the process Team ID without touching the PyInstaller-frozen dylibs (including libpython), so macOS refused to load them at runtime on other machines ("mapping process and mapped file have different Team IDs").

### Shipped
- v0.2.1

## 2026-04

### Added
- "Not in Album" queue (SFSymbol `rectangle.slash`) between Low Quality and Screenshots, showing photos that appear in no user album in Photos.
- Startup album membership sync: on launch with an existing catalogue, PhotoKit album membership is rescanned in the background so the Not in Album queue is always current without requiring a full re-index.
- Put Back button added to the default toolbar, grouped alongside Set Aside.
- "Open Archive Folder in Finder" added to the File menu below Set Archive Location.
- "Clear Set Aside…" added to the Photo menu.
- Open source credits with copyright notices added to the about box: osxphotos (Rhet Turnbull, MIT), ExifTool (Phil Harvey, Artistic/GPL), Sparkle (Andy Matuschak et al., MIT), WhatsNewKit (Sven Tiigi, MIT).

### Changed
- Inspector metadata fields now use `.monospacedDigit()` instead of `.monospaced()`, preserving proportional text with aligned numerals.

### Fixed
- CI release pipeline: version and build number are now derived from the git tag (`MAJOR×10000 + MINOR×100 + PATCH`), eliminating the shallow-clone `git rev-list` issue that caused Sparkle to report "up to date" after a real version bump.
- CI release pipeline: appcast enclosure URL now correctly targets GitHub release assets via `--download-url-prefix`, not GitHub Pages.

### Shipped
- v0.2: first release delivered via CI pipeline with working end-to-end Sparkle auto-update.

## 2026-03-24

### Added
- Archive exact deduplication across import, organise, export, and monitor flows (SHA-256 fingerprint matching with canonical path tracking and duplicate event audit trail).
- Archive dedupe observability in Settings and notice bar.
- Analysis-in-progress placeholder states in empty queue views with direct link to run analysis.
- Notice bar integration for archive organisation and analysis messaging.
- Trust-boundary smoke gate script (`./scripts/release/trust_boundary_smoke.sh`).
- Gallery zoom transition support via SharedUI.
- First-run welcome screen with post-index analysis chain.

### Changed
- Simplified photo library handling: removed multi-library binding/fingerprint system; Librarian always uses the System Photo Library. Runtime path change still triggers an informational alert.
- Rewrote user-facing copy to Catalogue/Archive terminology with UK English throughout.
- Corrected export defaults and removed alternate `kindThenDate` folder layout; canonical layout is `YYYY/MM/DD` only.
- Tightened near-duplicate matching thresholds for better precision on real libraries.
- Batched sidebar badge counts into a single database query for faster updates.
- Split large model and controller files into focused modules.
- Near-duplicate clustering now runs against the full dataset.
- Removed gallery bottom action bar UI.
- Removed unused Vision requests from analysis pipeline.
- Streamlined analysis status text to hide implementation detail.

### Fixed
- Window sizing regression: `NSHostingView` for the gallery placeholder propagated SwiftUI intrinsic size through Auto Layout, collapsing the window to toolbar height on first show. Replaced with `NSHostingController` using `sizingOptions = []`.
- Open in Photos now reliably reveals the selected item.
- Passed explicit `--library` path to bundled osxphotos so it targets the correct Photos library.
- Hardened bundled osxphotos diagnostics for better error reporting.
- Eliminated main-thread hangs during analysis.
- Inspector toggle state now updates correctly after analysis.
- Notification click now focuses the existing window instead of doing nothing.

### Tests
- Split test coverage by domain (archive boundary, config, import, osxphotos runner, app model).

### Docs
- Converged planning docs to a single source: `ROADMAP.md` replaces the separate shipping-plan document.
- Added `docs/CURRENT_STATE.md` as the implementation snapshot.
- Archived superseded docs under `docs/_archive/` (git-ignored).

## 2026-03-22 – 2026-03-23

### Added
- Vision analysis is now resumable after interruption; progress picks up where it left off.
- Sidebar queue reordering with persisted order via SharedUI callback.
- SF Symbols added to all menu bar and sidebar context menu items.
- First-run welcome screen with archive location picker and post-index analysis prompt.

### Changed
- Adopted SharedUI toolbar shell and window frame persistence.
- Toolbar appearance now updates correctly on light/dark mode switch.
- Toolbar items (`Set Aside`, `Put Back`, `Send to Archive`) use bordered style.
- Refined box classification heuristics and removed the "keep" concept.
- Analysis status copy unified under "Analysing" label.

### Fixed
- Welcome sheet now dismisses correctly on "Get Started".
- Spinner no longer persists after analysis completes.
- Selection restored after Set Aside action.
- Toolbar appearance adapter moved to correct lifecycle stage to avoid flicker.

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
