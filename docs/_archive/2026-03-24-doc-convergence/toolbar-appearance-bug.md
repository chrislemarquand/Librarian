# Toolbar Appearance Bug — Engineering Handoff

**Status**: Unresolved as of 2026-03-22.
**Affects**: Librarian only. Ledger (sibling app, same SharedUI) works correctly.
**macOS**: 26 (Liquid Glass). Not tested on earlier versions.

---

## The Bug

When the user toggles system appearance (light ↔ dark) after app launch, all custom toolbar items in Librarian fail to update their visual appearance. They remain stuck in whatever mode they were rendered in at launch.

**What works:**
- `.toggleSidebar` — system-provided item, AppKit manages it natively, always updates correctly.

**What fails:**
- `.librarianZoomOut`, `.librarianZoomIn` (SF Symbol images)
- `.librarianSetAside`, `.librarianSendToArchive`, `.librarianPutBack` (SF Symbol images)
- `.librarianToggleInspector` (SF Symbol image)
- `.librarianIndexingProgress` (spinner — not image-based, but still fails)

Items load correctly at app launch in whichever mode is active. The bug is exclusively a post-launch toggle issue.

---

## What Works in Ledger (Reference Implementation)

Ledger uses an identical SharedUI, the same `ToolbarAppearanceAdapter`, the same `ToolbarItemFactory`, and the same `ThreePaneSplitViewController` base class. It works correctly — all items update on appearance toggle.

Ledger's toolbar mechanism:
- `NativeThreePaneSplitViewController` (the content view controller) owns **all** toolbar logic
- `viewWillAppear` → `configureWindowIfNeeded()` → installs toolbar using `view.window`
- `viewDidAppear` → creates `ToolbarAppearanceAdapter(window: view.window)`
- On adapter callback: creates a new `NSToolbar` with identifier `"...MainToolbar.v5"`, sets it on the window, calls `refreshFromModel()`, calls `validateVisibleItems()`
- Inspector toggle gets `item.label` mutated in `refreshFromModel()` which triggers a redraw

---

## Relevant Code Locations

| File | Role |
|---|---|
| `Sources/Librarian/Shell/MainWindowController.swift` | Window controller — currently just creates window, no toolbar logic |
| `Sources/Librarian/Shell/MainSplitViewController.swift` | Split VC — now owns toolbar install, adapter, and rebuild |
| `Sources/Librarian/Shell/ToolbarDelegate.swift` | `NSToolbarDelegate` — creates items, holds weak refs, refreshes state |
| `Sources/SharedUI/Toolbar/ToolbarAppearanceAdapter.swift` | KVO on `window.effectiveAppearance`, fires rebuild closure |
| `Sources/SharedUI/Toolbar/ToolbarItemFactory.swift` | Factory for zoom and inspector toggle items |
| `Sources/SharedUI/Toolbar/WindowToolbarSetup.swift` | `configureWindowForToolbar()` — sets styleMask, toolbarStyle etc. |
| `/Users/chrislemarquand/Xcode Projects/Ledger/Sources/Ledger/MainContentView.swift` | Ledger reference — lines 133–371 cover the full working implementation |

---

## Current State of the Code

After all fixes applied to date, Librarian's toolbar is managed entirely within `MainSplitViewController`:

```swift
// viewWillAppear — installs toolbar before window is visible
override func viewWillAppear() {
    super.viewWillAppear()
    guard !didConfigureToolbar, let window = view.window else { return }
    didConfigureToolbar = true
    configureWindowForToolbar(window)
    installToolbar(resetDelegateState: true)
}

// viewDidAppear — creates adapter after window is fully on screen
override func viewDidAppear() {
    super.viewDidAppear()
    if toolbarAppearanceAdapter == nil, let window = view.window {
        toolbarAppearanceAdapter = ToolbarAppearanceAdapter(window: window) { [weak self] in
            self?.rebuildToolbarForCurrentAppearance()
        }
    }
    // ... rest of viewDidAppear
}

private func installToolbar(resetDelegateState: Bool) {
    guard let window = view.window else { return }
    if resetDelegateState { toolbarDelegate.resetCachedToolbarReferences() }
    let toolbar = NSToolbar(identifier: "\(AppBrand.identifierPrefix).MainToolbar.v1")
    toolbar.delegate = toolbarDelegate
    toolbar.displayMode = .iconOnly
    toolbar.allowsUserCustomization = false
    toolbar.autosavesConfiguration = false
    window.toolbar = toolbar
}

private func rebuildToolbarForCurrentAppearance() {
    installToolbar(resetDelegateState: true)
    toolbarDelegate.refresh(model: model)
    view.window?.toolbar?.validateVisibleItems()
}
```

This is structurally identical to Ledger's working implementation. It does not fix the bug.

`MainWindowController` is now a thin shell with no toolbar involvement.

---

## Everything That Has Been Tried (Chronological)

### 1. `isBordered = true` on all image-bearing items
**Hypothesis**: `isBordered = true` causes AppKit to back items with a live `NSButton` that participates in appearance invalidation natively, making `ToolbarAppearanceAdapter` unnecessary.
**Result**: Partially fixed Ledger's Open Folder item (which also has `autovalidates = true`). Made Ledger's zoom and Apply Changes items **worse** (broke them). No change in Librarian.
**Conclusion**: `isBordered = true` + `autovalidates = false` is actually harmful — NSButton backing does not re-render without a validation trigger. Reverted on all items except Ledger's Open Folder.

### 2. Version the toolbar identifier (`.v1` suffix in Librarian)
**Hypothesis**: AppKit caches toolbar items by identifier. Librarian used an unversioned identifier, so rebuilds reused cached item instances, the delegate was never re-called, and weak refs in `ToolbarDelegate` were never repopulated. Ledger uses `.v5` suffix which bypasses the cache.
**Result**: No change.
**Conclusion**: Either AppKit does not cache items by toolbar identifier when `autosavesConfiguration = false`, or this was not the primary issue. The `.v1` suffix has been left in place as it is still correct practice.

### 3. Move adapter creation from `showWindow` to `viewDidAppear` (via `window.windowController` cast)
**Hypothesis**: The adapter was created in `showWindow` before `super.showWindow`, before the window's `effectiveAppearance` was stable. A spurious KVO fire during the macOS 26 compositor's initial pass corrupted the toolbar state. Moving creation to `viewDidAppear` matches Ledger's timing.
**Result**: No change.
**Root cause of failure**: `window.windowController` is not guaranteed to be set for programmatically created `NSWindowController` instances (only set automatically when loading from a nib). The `as? MainWindowController` cast silently returned nil. `setUpToolbarAppearanceAdapterIfNeeded` was never called.

### 4. Move all toolbar logic into `MainSplitViewController` (current state)
**Hypothesis**: The `window.windowController` cast failure was the blocker. Owning the adapter and all toolbar logic directly in the split view controller (using `view.window` throughout) eliminates all indirect references and exactly mirrors Ledger's architecture.
**Result**: No change. Bug persists identically.
**Conclusion**: The architecture is now correct. The bug is elsewhere.

---

## What Is Known With Confidence

1. **The architecture is now correct.** `MainSplitViewController` owns the adapter and toolbar in exactly the same structure as Ledger's `NativeThreePaneSplitViewController`. The remaining bug is not an architectural/ownership issue.

2. **`isBordered` is not the fix.** Tried. Made things worse for some items.

3. **The toolbar identifier is not the fix.** Tried. No effect.

4. **Ledger's zoom items (also `autovalidates = false`, `isBordered = false`) work correctly.** This means fresh items created by the delegate during a rebuild DO render in the new appearance. The mechanism does not require label mutation or validation — it works by virtue of fresh item creation alone.

5. **Something specific to Librarian prevents the rebuild mechanism from working**, even though the code is now structurally identical to Ledger.

---

## What Is Not Known — Open Questions

### Q1: Is `rebuildToolbarForCurrentAppearance()` actually being called?

This is the most critical unknown. If the adapter's KVO never fires, the rebuild never happens, and all symptoms are explained. A simple `print()` or breakpoint in `rebuildToolbarForCurrentAppearance()` would confirm or rule this out immediately.

**Possible reasons the KVO might not fire:**
- `toolbarAppearanceAdapter` is nil (never created, or immediately deallocated)
- `view.window` is nil in `viewDidAppear` — unlikely but possible if the view lifecycle is abnormal
- `window.effectiveAppearance` does not change because it is pinned (see Q3)
- A bug in `ToolbarAppearanceAdapter` itself on macOS 26

### Q2: Is `window.toolbar = newToolbar` actually replacing the toolbar visually?

If the rebuild IS firing but the visual doesn't change, the new toolbar may not be taking effect. Possible reasons:
- AppKit ignores the new toolbar because of some compositor lock on macOS 26
- The new toolbar IS installed, items ARE created in the new appearance, but something re-renders them back in the old appearance immediately after

A `print()` in `installToolbar` and in `ToolbarDelegate.toolbar(_:itemForItemIdentifier:willBeInsertedIntoToolbar:)` would confirm whether the delegate is being called during a rebuild.

### Q3: Is `window.effectiveAppearance` actually changing in Librarian?

If something sets `window.appearance` explicitly (overriding system following), `effectiveAppearance` would never change and the KVO would never fire.

Search for `\.appearance` and `NSAppearance` assignments across the full Librarian source, including:
- `ContentController`
- `InspectorController`
- `AppKitSidebarController`
- Any SwiftUI-hosted views (`NSHostingController` subclasses)

**SwiftUI islands are a particular suspect.** When SwiftUI content is embedded via `NSHostingController`, SwiftUI sometimes sets an explicit `NSAppearance` on the hosting controller's view to match its own rendering context. If a hosting controller's view is a subview of the window's content view, this would affect child views but NOT `window.effectiveAppearance`. However, it's worth verifying.

### Q4: Does the bug reproduce from a cold launch in a freshly-built binary?

If the bug only appears after multiple hot-reloads or Xcode debug sessions, it could be a build artifact. Worth testing with an archive build or a clean derived data build.

### Q5: Does the bug reproduce on macOS versions before 26?

Untested. If it only occurs on macOS 26, the bug is in how Liquid Glass handles toolbar item layer management. On macOS 26, toolbar items may be composited into a cached layer that is not invalidated by `window.toolbar = newToolbar`.

### Q6: What is the actual `NSWindow` subclass in use?

`NSWindow(contentViewController:)` returns a plain `NSWindow`. But `configureWindowForToolbar` sets `window.toolbarStyle = .automatic`. On macOS 26, `.automatic` may cause AppKit to swap the window for a specialised subclass internally (similar to how `NSTexturedWindow` worked historically). If that swap happens, the window object the adapter is observing may no longer be the live window.

Log `ObjectIdentifier(view.window!)` in `viewWillAppear`, `viewDidAppear`, and inside `rebuildToolbarForCurrentAppearance()` to confirm they're all the same window instance.

---

## Suggested Next Debugging Steps

1. **Add a print/breakpoint in `rebuildToolbarForCurrentAppearance()`** to confirm whether it fires on appearance toggle. This one step eliminates half the hypothesis space.

2. **Add a print in `ToolbarDelegate.toolbar(_:itemForItemIdentifier:willBeInsertedIntoToolbar:)`** to confirm whether the delegate is called during a rebuild.

3. **Log `window.effectiveAppearance.name` in `viewDidAppear`** and after toggling — confirm the window's effective appearance actually changes.

4. **Search the entire Librarian source for `\.appearance =`** to rule out explicit appearance pinning.

5. **Compare `ObjectIdentifier(view.window!)` across `viewWillAppear`, `viewDidAppear`, and `rebuildToolbarForCurrentAppearance()`** to confirm the same window instance is used throughout.

6. **Test with a minimal reproduction** — add a single `NSToolbarItem` with an SF Symbol image to a fresh single-window AppKit app using the same `configureWindowForToolbar` + `ToolbarAppearanceAdapter` pattern and see if it updates on appearance change. If the minimal case works, the bug is Librarian-specific. If it doesn't, it's a macOS 26 / SharedUI bug.

---

## What Makes Librarian Structurally Different From Ledger

Despite the now-identical toolbar ownership architecture, there are still differences between the two apps that have not been ruled out:

| | Librarian | Ledger |
|---|---|---|
| Window class | `NSWindow` | `NSWindow` |
| Content VC class | `MainSplitViewController : ThreePaneSplitViewController` | `NativeThreePaneSplitViewController : ThreePaneSplitViewController` |
| SwiftUI islands | Yes — inspector, some settings panels | Yes — inspector, import sheets |
| `applicationShouldRestoreApplicationState` | Returns `true` | Unknown |
| `window.isRestorable` | `true` | Unknown |
| Welcome screen (first run) | `NSHostingController` presented as sheet on first launch | `NSHostingController` presented as sheet on first launch |
| Sidebar implementation | `AppKitSidebarController` (custom AppKit) | SwiftUI-based |
| Photos library access | PhotoKit + osxphotos subprocess | n/a |

The state restoration flags (`applicationShouldRestoreApplicationState = true`, `window.isRestorable = true`) have not been tested as a potential cause. AppKit state restoration can affect window lifecycle in subtle ways.

---

## Git History Reference

All changes described above are in the Librarian git history. The relevant commits from 2026-03-22:

- `isBordered = true` test — `45af192`
- Revert `isBordered`, identifier fix, rebuild reverts — `afab2e1`
- Adapter timing fix (viewDidAppear via windowController cast) — `47bc2af`
- Full migration to MainSplitViewController ownership — `2ea1559`

To return to the pre-investigation baseline: `git checkout` before `45af192`.
