# Librarian Window Sizing Regression Handoff

## Context
This document hands off the unresolved main-window sizing regression in Librarian. The issue appeared after recent refactor/testing work and is currently blocking normal use.

Date of handoff: 2026-03-24
Repos involved:
- `/Users/chrislemarquand/Xcode Projects/Librarian`
- `/Users/chrislemarquand/Xcode Projects/SharedUI`

## User-reported symptoms
- Main window opens at an abnormally short height.
- Sidebar appears visually oversized relative to content.
- Window cannot be resized back to a normal working size reliably.
- Behavior regresses again even after state reset attempts.

User screenshots show window frame collapsing to a very shallow layout (title/toolbar + minimal content height).

## Known bad persisted geometry
The following persisted frame value is repeatedly observed:

`defaults read com.chrislemarquand.Librarian 'NSWindow Frame Librarian.MainWindow'`

Output seen:
`85 734 1300 178 0 0 1470 923`

The key point is persisted height `178`, which is far below intended app min/default sizing.

## Why this is hard / why attempted fixes have not held
1. Sanitization/reset logic does run in some sessions, but the window still shrinks during show-time.
2. Evidence indicates the shrink can happen *after* initial frame restoration/default application.
3. That means corruption is likely reintroduced during/after `super.showWindow(...)` by another restoration/layout path.
4. Reset scripts can remove stored keys, but a bad frame is later persisted again, so resets are not a stable fix.
5. Disabling app state restoration in `AppDelegate` and `window.isRestorable = false` has not yet conclusively eliminated the regression in user runs.

## Instrumentation and logs
### Debug log location
Window diagnostics were instrumented to write to:

`/tmp/librarian-window-debug.log`

### Why this log may be missing
- `/tmp` logs are ephemeral and may be deleted by restart/reset tooling.
- If the launched app binary does not include current instrumentation (old build), no file is produced.
- If the app never reaches instrumented paths in a run (e.g. crash/early termination), file may not exist.

### Most important captured evidence (from earlier run)
Captured sequence (paraphrased from previous diagnostic run):
- `WindowFramePersistence` sanitizes bad stored frame and applies a good default (1300x800).
- `MainWindowController showWindow before`: frame is good.
- `MainWindowController showWindow after`: frame is immediately `1300x178`.

Interpretation: shrink occurs during/after `super.showWindow`, not during initial defaults read/sanitize.

## Files currently modified for this investigation
These are uncommitted local changes at handoff time.

### Librarian
- `/Users/chrislemarquand/Xcode Projects/Librarian/Sources/Librarian/AppDelegate.swift`
- `/Users/chrislemarquand/Xcode Projects/Librarian/Sources/Librarian/Shell/MainWindowController.swift`
- `/Users/chrislemarquand/Xcode Projects/Librarian/reset_librarian_state.sh`

### SharedUI
- `/Users/chrislemarquand/Xcode Projects/SharedUI/Sources/SharedUI/Window/WindowFramePersistenceController.swift`
- `/Users/chrislemarquand/Xcode Projects/SharedUI/Sources/SharedUI/SplitView/ThreePaneSplitViewController.swift`

## What has been changed (investigation patches)

### 1) App state restoration disabled (Librarian)
`AppDelegate.swift`:
- `applicationSupportsSecureRestorableState` -> `false`
- `applicationShouldSaveApplicationState` -> `false`
- `applicationShouldRestoreApplicationState` -> `false`

`MainWindowController.swift`:
- `window.isRestorable = false`

Rationale: eliminate NSApplication/NSWindow restoration as a source of bad post-launch geometry.

### 2) Window frame persistence sanitization + logging (SharedUI)
`WindowFramePersistenceController.swift`:
- Sanitizes/removes invalid saved frame values before restore.
- Applies default/min size when restore is invalid.
- Logs init/restore/post-init/persist frame snapshots.
- Appends diagnostics to `/tmp/librarian-window-debug.log`.

### 3) Split autosave sanitization + logging (SharedUI)
`ThreePaneSplitViewController.swift`:
- Sanitizes invalid split autosave entries (`NSSplitView Subview Frames ...`, divider positions).
- Logs stored split frames and split bounds.
- Appends diagnostics to `/tmp/librarian-window-debug.log`.

### 4) Show-window boundary logging (Librarian)
`MainWindowController.swift`:
- Logs frame/content rect before and after `super.showWindow`.

### 5) Expanded local reset script
`reset_librarian_state.sh` now also clears:
- additional container prefs/state paths for both bundle IDs:
  - `com.chrislemarquand.Librarian`
  - `com.librarian.app`
- explicit keys:
  - `NSWindow Frame Librarian.MainWindow`
  - split autosave keys

## Commits relevant to regression window
Recent timeline in Librarian:
- `e5dcc67` refactor: split large model/controller files
- `4b22232` test: split coverage by domain and add trust-boundary smoke gate

Window-persistence/toolbar adoption earlier:
- `4ea99e3` refactor: adopt SharedUI toolbar shell and window persistence

SharedUI introduction of frame persistence:
- `bf6f7a1` feat: add shared toolbar shell and window frame persistence

## Current diagnosis (best available)
Most likely the bad height is being applied in a post-init window show/restore/layout path, then persisted again. The strongest signal is frame changing from sane -> `1300x178` around `super.showWindow`.

Secondary possibility: a content-controller or toolbar timing path is forcing a tiny fitting height at first show, and the persistence layer then stores it.

## Proposed solution path for next engineer

### Phase A: Reproduce with clean, deterministic telemetry
1. Ensure both repos are built from current working tree (instrumented code actually in running app).
2. Delete `/tmp/librarian-window-debug.log`.
3. Run reset script.
4. Launch once and capture:
   - `/tmp/librarian-window-debug.log`
   - `defaults read com.chrislemarquand.Librarian 'NSWindow Frame Librarian.MainWindow'`
5. Confirm exact first bad write point.

### Phase B: Hard guard against writing invalid frames
In `WindowFramePersistenceController.persistFrame()`:
- Skip `saveFrame(usingName:)` when current frame/content height is below an enforced threshold.
- Optionally remove existing bad key when detected.

This prevents re-poisoning persisted state even if upstream layout still shrinks once.

### Phase C: Narrow show-time shrink source
Add temporary logs for:
- `window.minSize`, `window.maxSize`, `window.styleMask`, and `contentViewController.preferredContentSize`
- `viewWillAppear/viewDidAppear/viewDidLayout` in main split/content controller to catch first drop to 178

Goal: identify exact component mutating window frame at show-time.

### Phase D: Fix at source
Depending on findings:
- If restoration path: keep restoration disabled for main window permanently.
- If toolbar/style timing: move/guard secondary toolbar configuration to avoid frame recomputation.
- If content-layout driven: remove/adjust preferred/fitting-size constraints causing tiny host height.

## Suggested immediate defensive patch (low risk)
Even before root-cause is fully proven:
- Add persistence write guard in `persistFrame()` to never save frame heights below safe minimum (e.g. 500 frame height / min content threshold).

This stops repeated user lock-in to tiny windows.

## Commands used during diagnosis
- `defaults read com.chrislemarquand.Librarian 'NSWindow Frame Librarian.MainWindow'`
- `defaults read com.chrislemarquand.Librarian 'NSSplitView Subview Frames Librarian.MainSplitView'`
- `defaults read com.chrislemarquand.Librarian 'NSSplitView Subview Frames Librarian.InnerSplitView'`
- `git status --short` in both repos
- `git diff` in modified files
- `tail -n 120 /tmp/librarian-window-debug.log`

## Current local status
At handoff, there are uncommitted modifications in both repos (see files listed above). No final fix commit for this regression has been completed yet.

## Recommendation
Treat this as a release-blocking regression. Prioritise:
1. Preventing bad frame persistence (defensive guard), and
2. Isolating exact post-show mutation source.

Do not ship with current behavior.
