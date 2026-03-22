# Toolbar Appearance Investigation — Restart Handoff (2026-03-22)

## Scope
This handoff covers the cross-app toolbar dark/light transition bug work across:
- `SharedUI`
- `Ledger`
- (Librarian intentionally deferred until `SharedUI` + `Ledger` architecture is stable)

Primary requirement from user:
- Keep native Liquid Glass behavior (`toolbarStyle = .automatic`) and full-height sidebar/titlebar presentation.
- Keep native positioning behavior where folder/sidebar controls align with the sidebar divider when open, then regroup when sidebar is collapsed.
- Remove brittle workaround architecture; prefer clean, simple, native AppKit.

## High-confidence findings (validated)

1. **Toolbar rebuild pipeline is not the blocker**
   Earlier instrumentation confirmed in Librarian that all of these occurred on appearance toggle:
   - appearance observer fires
   - rebuild function runs
   - toolbar is replaced
   - delegate item creation runs
   Yet custom items still did not visually update.

2. **This is not an "edge vs center" placement issue**
   In Ledger, two identical probe items placed at different toolbar positions both failed to transition when the bug was present.

3. **The decisive trigger is window styling path, specifically `fullSizeContentView`**
   In Ledger:
   - When `configureWindowForToolbar(window)` was disabled, all toolbar buttons transitioned correctly on dark/light.
   - Re-enabling `fullSizeContentView` (with `.automatic`) restored desired visuals but reintroduced transition failures.

4. **Workaround attempts that did not fix root issue**
   - Toolbar rebuild on appearance changes
   - Identifier versioning / cache-busting style attempts
   - Converting selected items to bordered/view-backed controls in isolation
   - Forcing image refresh callbacks after appearance change

## Architectural conclusion
The long-lived workaround architecture (appearance KVO + toolbar rebuild) is the wrong layer.

The real fault line is the interaction between:
- custom toolbar item rendering paths
- and the full-size-content/titlebar compositing path required for Liquid Glass visuals.

We need a native AppKit-first toolbar architecture with minimal SharedUI chrome policy and no rebuild-on-appearance logic.

---

## Current repo state (IMPORTANT)

### `SharedUI`
Modified file:
- `Sources/SharedUI/Toolbar/WindowToolbarSetup.swift`

Current behavior in this file:
- keeps `window.styleMask.insert(.fullSizeContentView)`
- keeps `window.toolbarStyle = .automatic`
- removed forced titlebar separator/visibility/transparency overrides
- function annotated `@MainActor`

### `Ledger`
Modified file:
- `Sources/Ledger/MainContentView.swift`

Current behavior in this file:
- `ToolbarAppearanceAdapter` usage removed
- `viewDidAppear` appearance-adapter setup removed
- rebuild function removed (`rebuildToolbarForCurrentAppearance`)
- toolbar is installed once in `configureWindowIfNeeded()`
- toolbar item ordering and tracking-separator logic preserved

### `Librarian`
No intentional source changes for toolbar work in this session.
Current local status showed one unrelated user-data file modified:
- `Librarian.xcodeproj/xcuserdata/chrislemarquand.xcuserdatad/xcschemes/xcschememanagement.plist`

### Untracked/generated files observed
In `Ledger`:
- `Ledger.xcodeproj/project.xcworkspace/`
- `Package.resolved`

These were generated during package resolution/build work.

---

## What is working right now
With current edits:
- Visual layout presentation is back to looking correct (per user feedback) once `fullSizeContentView` is enabled.
- But dark/light transition bug is still present for custom toolbar buttons.

So current state = **correct look, incorrect appearance transitions**.

---

## Resume plan (next actions)

### Phase 1: Stabilize minimal native baseline in Ledger
1. Keep current single-install toolbar architecture (no appearance rebuild, no adapter).
2. Keep item order and tracking separators exactly as-is.
3. Preserve `fullSizeContentView + .automatic` while investigating item rendering path with least custom code.

### Phase 2: Native item API migration test (Ledger only)
Goal: use the most native toolbar item classes for failing controls without adding observer hacks.

Candidate approach:
- Migrate failing center controls to native toolbar item classes (`NSButtonToolbarItem` / `NSToolbarItemGroup` where appropriate) in one coherent slice, not one-off patches.
- Keep actions/labels/order identical.
- Rely on native AppKit validation and rendering.

Do **not** reintroduce:
- appearance KVO toolbar rebuild
- toolbar replacement on toggle
- image reset observers

### Phase 3: Validate invariants after migration
Must pass all:
1. Liquid Glass visual presentation unchanged.
2. Sidebar open: folder/sidebar controls align to divider (tracking separator behavior intact).
3. Sidebar collapsed: controls regroup naturally in toolbar.
4. All custom toolbar buttons transition correctly across dark/light toggles.

### Phase 4: Apply to Librarian
Once Ledger solution is clean and verified:
- port same architecture to Librarian
- remove parallel workaround paths
- keep SharedUI as primitive provider, not chrome enforcer

---

## Guardrails (from user direction)
- Prefer ripping out wrong-turn architecture over adding more custom code.
- Clean, simple, native AppKit solutions only.
- SharedUI should not impose custom window chrome beyond minimal native toolbar style setup.

---

## Useful commands to resume quickly

From `Ledger`:
```bash
swift build
xcodebuild -project Ledger.xcodeproj -scheme Ledger -configuration Debug -destination 'platform=macOS' build
```

From `SharedUI`:
```bash
swift build
```

Status checks:
```bash
git -C '/Users/chrislemarquand/Xcode Projects/SharedUI' status --short
git -C '/Users/chrislemarquand/Xcode Projects/Ledger' status --short
git -C '/Users/chrislemarquand/Xcode Projects/Librarian' status --short
```

---

## Exact files to inspect first on resume
- `/Users/chrislemarquand/Xcode Projects/SharedUI/Sources/SharedUI/Toolbar/WindowToolbarSetup.swift`
- `/Users/chrislemarquand/Xcode Projects/Ledger/Sources/Ledger/MainContentView.swift`
- `/Users/chrislemarquand/Xcode Projects/Librarian/docs/toolbar-appearance-bug.md`
- `/Users/chrislemarquand/Xcode Projects/Librarian/docs/toolbar-appearance-restart-handoff-2026-03-22.md` (this file)

---

## Continuation Update (2026-03-22, later pass)

### What was changed in this pass

`Ledger` only:
- File: `Sources/Ledger/MainContentView.swift`
- Replaced the toolbar `View` mode control from a custom `NSSegmentedControl`-backed `NSToolbarItem` (`item.view = control`) to native `NSToolbarItemGroup` image-based API with `.selectOne`.
- Replaced selector wiring:
  - old: `viewModeChanged(_ sender: NSSegmentedControl)`
  - new: `viewModeGroupChanged(_ sender: NSToolbarItemGroup)`
- Updated delegate cache/update wiring:
  - old cached ref: `viewModeControl: NSSegmentedControl?`
  - new cached ref: `viewModeGroupItem: NSToolbarItemGroup?`
  - old refresh: `selectedSegment = ...`
  - new refresh: `selectedIndex = ...`

### Why this slice
- This is the least-invasive native-API migration away from custom toolbar view-backed controls while preserving toolbar order and split tracking separator behavior.
- `NSButtonToolbarItem` is not available in this AppKit SDK, so migration targeted available native classes (`NSToolbarItemGroup`, `NSMenuToolbarItem`, `NSToolbarItem`).

### Build/verification status
- `SharedUI`: `swift build` ✅
- `Ledger`: `swift build` ✅
- `Ledger`: `xcodebuild -project Ledger.xcodeproj -scheme Ledger -configuration Debug -destination 'platform=macOS' build` ✅

### Still required (runtime/manual)
- Verify dark/light transition behavior on macOS 26 with `fullSizeContentView + toolbarStyle = .automatic` after this `NSToolbarItemGroup` migration.
- Confirm all invariants remain true:
  1. Liquid Glass/full-height look unchanged.
  2. Sidebar controls still align/regroup correctly with tracking separators.
  3. Toolbar controls update correctly across post-launch appearance toggles.

---

## Continuation Update (2026-03-22, latest)

### Current baseline status (after reverting latest failed fix)
- `Ledger` toolbar architecture has been fully rewritten to a native, simplified baseline.
- Appearance-transition issue remains for a subset of custom toolbar buttons.
- Verified working on toggle:
  - native sidebar toggle
  - open-folder button
  - inspector toggle button
- Still failing on toggle:
  - zoom out/in
  - sort/import/export/presets menu toolbar items
  - apply changes

### Current toolbar architecture in `Ledger` (baseline to keep)

Primary file:
- `/Users/chrislemarquand/Xcode Projects/Ledger/Sources/Ledger/MainContentView.swift`

Architecture:
1. One-time window config in `configureWindowIfNeeded()`:
   - `configureWindowForToolbar(window)` (SharedUI minimal primitive)
   - install toolbar once, no rebuild-on-appearance.
2. Toolbar ownership:
   - `mainToolbarController: MainToolbarController`
   - `NSToolbar.delegate = mainToolbarController`
3. Native AppKit item types:
   - `.toggleSidebar` system item
   - `NSTrackingSeparatorToolbarItem` for sidebar + inspector dividers
   - `NSToolbarItemGroup` for view mode (gallery/list)
   - `NSToolbarItem` for zoom/open/apply/inspector
   - `NSMenuToolbarItem` for sort/import/export/presets
4. State updates:
   - `refreshToolbarState()` calls `mainToolbarController.syncFromModel()` + `validateVisibleItems()`.
5. Validation:
   - `MainToolbarController` implements `NSToolbarItemValidation`.
   - enable/disable and dynamic labels/styles are driven via `validateToolbarItem(_:)`.
6. Explicitly removed from baseline:
   - appearance-driven toolbar rebuilds
   - toolbar replacement on light/dark toggle
   - debugging probes and scoped image-refresh workaround from latest failed attempt
   - spinner/loading toolbar item in center section (removed in rewrite)

### Attempt log and outcomes (latest full sequence)

1. **Native control migration (`NSToolbarItemGroup`) for view mode**
   - Goal: remove custom `item.view` segmented control.
   - Result: regression (appearance behavior worsened), reverted.

2. **Full Ledger toolbar rewrite (current baseline)**
   - Replaced legacy delegate flow with dedicated `MainToolbarController`.
   - Moved to validation-driven updates.
   - Removed appearance rebuild machinery.
   - Result: architecture substantially cleaner; some items now behave correctly; core failing subset unchanged.

3. **Control-backed presentation attempt (`isBordered = true` on failing items)**
   - Applied to zoom/sort/import/export/presets/apply.
   - Result: no fix for failing subset.

4. **Scoped appearance observer + explicit image reassignment (Option 1)**
   - Added `ToolbarAppearanceAdapter` in Ledger only.
   - On appearance change: reassign SF Symbol images for known failing items, then `validateVisibleItems()`.
   - Result: still failed; reverted completely.

### High-confidence conclusion
- The remaining issue is likely in macOS 26/AppKit titlebar compositing invalidation for specific custom toolbar item rendering paths under:
  - `fullSizeContentView`
  - `toolbarStyle = .automatic`
- This no longer looks like architectural complexity in Ledger; the pipeline has been stripped and simplified.

### What to try next (not yet implemented)
1. Replace failing `NSMenuToolbarItem` paths with alternate native interaction models (plain button + popup on action), one item at a time to isolate class-specific breakage.
2. Introduce version-gated workaround (macOS 26 only) via low-frequency forced revalidation/reimage hook tied to app activation/appearance change notifications at app level (still no toolbar rebuild).
3. As last resort, compromise on titlebar path (disable full-size-content) if visual parity is less important than perfect transitions.

### Verification notes from this pass
- `swift build` in `Ledger` repeatedly passed after each major change/revert.
- Latest state in repo after reverting failed Option 1 is compile-clean and is the intended baseline for next resume.
