# Archive Relink — Handoff Document

**Status:** Broken. Multiple attempts made. Handing off for a clean implementation.
**Date:** 2026-03-21

---

## What should happen

When the user moves or trashes their archive folder outside of Librarian:

1. On next app open, a sheet/alert prompts them to locate the archive ("Archive Not Found — Locate it to continue").
2. The archive gallery view shows **"Archive Missing"** rather than "No Archive Photos".
3. The Settings breadcrumb reflects the actual current state (either the resolved new path, or a blank/unavailable state).

---

## The data model — read this first

The archive root is stored as a **security-scoped bookmark** in `UserDefaults` (key: `com.librarian.app.archiveRootBookmark`).

**Critical detail:** the bookmark points to the **user-chosen parent folder** (e.g. `Testing/`), NOT to the `Archive/` subfolder. The actual archive lives at:

```
Testing/             ← this is what the bookmark tracks
  Archive/           ← .librarian/ lives here; this has the red custom icon
    .librarian/
      archive.json   ← contains the archiveID UUID
      thumbnails/
      reports/
    Photos/          (or YYYY/MM/DD/ directly for dateOnly layout)
      2024/
        ...
```

`ArchiveSettings.archiveTreeRootURL(from: rootURL)` → `rootURL/Archive/`
`ArchiveControlPaths(rootURL:).controlRootURL` → `rootURL/Archive/.librarian/`

The **archive root URL** that all code talks about is `Testing/` — NOT `Testing/Archive/`.

---

## The core bug that was never fixed

### `archiveRootAvailability(for: rootURL)` only checks the parent, not the archive subfolder

`ArchiveSettings.archiveRootAvailability(for: rootURL)` checks:
- Does `Testing/` exist on disk? (`fileManager.fileExists`)
- Is it a directory?
- Is the volume writable?

It does **not** check whether `Testing/Archive/` exists, nor whether `Testing/Archive/.librarian/archive.json` exists.

**Consequence:** If the user moves `Testing/Archive/` to the desktop (which is what happens when they drag the red-icon folder — the visually prominent one) while leaving `Testing/` behind, then:

- `Testing/` still exists → availability returns `.available`
- No relink prompt fires
- The gallery loads zero results (archive DB is empty or records don't match)
- The empty state shows **"No Archive Photos"** instead of "Archive Missing"
- The breadcrumb shows `Testing/Archive/` with a white icon (the path control shows the computed `archiveTreeRootURL` which no longer exists on disk)

**This is the primary unfixed root cause.**

---

## What was tried (and why it didn't fully work)

### Attempt 1: Trash detection in `archiveRootAvailability`

Added a check after `fileExists`:

```swift
let trashURL = fileManager.homeDirectoryForCurrentUser
    .appendingPathComponent(".Trash").standardized
if rootURL.standardized.path.hasPrefix(trashURL.path + "/") {
    return .unavailable
}
```

**Why it didn't solve the problem:** This only helps if the user trashed `Testing/` (the root). If they moved `Testing/Archive/` (the visible red-icon folder) to the desktop or trash, `Testing/` still passes the check and returns `.available`. The trash detection is correct for the scenario it covers but is insufficient on its own.

### Attempt 2: `@Published var archiveRootURL: URL?` + Combine subscription

Added `@Published var archiveRootURL: URL?` to `AppModel`, updated in `refreshArchiveRootAvailability()`. Intended to drive UI reactively. Not wired up to change any actual detection logic — purely structural. Does not fix the root cause.

### Attempt 3: Remove `photosAuthState == .authorized` guard for archived sidebar

In `ContentController.loadAssetsIfNeeded` and `loadNextPageIfNeeded`, bypassed the Photos auth guard when `sidebarKind == .archived`. In `updateOverlay`, added an early-return path for the archived sidebar that shows archive-specific empty states immediately without waiting for Photos auth.

**Effect:** This is actually a correct improvement — the archive view no longer shows "Requesting Access" while Photos auth is pending. But it doesn't fire the relink prompt, and it doesn't detect the missing-subfolder case, so the empty state is still "No Archive Photos" (because `emptyContent(for: .archived)` reads `archiveRootAvailability` which still says `.available`).

---

## Current state of the code

### `AppModel.archiveRootAvailability(for:)` — `AppModel.swift` ~line 265

```swift
static func archiveRootAvailability(for rootURL: URL) -> ArchiveRootAvailability {
    let didAccess = rootURL.startAccessingSecurityScopedResource()
    defer { if didAccess { rootURL.stopAccessingSecurityScopedResource() } }

    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: rootURL.path) else { return .unavailable }

    // ✅ Added: trash detection
    let trashURL = fileManager.homeDirectoryForCurrentUser
        .appendingPathComponent(".Trash").standardized
    if rootURL.standardized.path.hasPrefix(trashURL.path + "/") { return .unavailable }

    // ❌ MISSING: check that rootURL/Archive/ and rootURL/Archive/.librarian/ exist

    // ... directory/volume checks ...
    return .available
}
```

### `AppModel.setup()` — ~line 409

```swift
let availability = refreshArchiveRootAvailability()
NotificationCenter.default.post(name: .librarianArchiveRootChanged, object: nil)
if availability == .unavailable {
    NotificationCenter.default.post(name: .librarianArchiveNeedsRelink, object: nil)
}
await requestPhotosAccess()
```

### `AppDelegate.applicationDidFinishLaunching` — `AppDelegate.swift` ~line 62

```swift
NotificationCenter.default.addObserver(
    forName: .librarianArchiveNeedsRelink, object: nil, queue: .main
) { [weak self] _ in
    Task { @MainActor [weak self] in
        guard let self else { return }
        await runArchiveRelinkFlow(model: model, presentingWindow: self.mainWindowController?.window)
    }
}
Task { await model.setup() }
```

The observer is registered **before** `setup()` runs, so the timing is fine — once `setup()` posts `librarianArchiveNeedsRelink`, the delegate receives it. The problem is that `setup()` never posts it because availability is `.available`.

### `ArchiveSettingsViewController.refreshArchivePath()` — ~line 204

```swift
private func refreshArchivePath() {
    guard let treeRoot = ArchiveSettings.currentArchiveTreeRootURL() else {
        archivePathControl.url = nil
        return
    }
    archivePathControl.url = treeRoot
    let all = archivePathControl.pathItems
    if all.count > 4 { archivePathControl.pathItems = Array(all.suffix(4)) }
}
```

`currentArchiveTreeRootURL()` → `restoreArchiveRootURL()` → resolves bookmark to current path of the root → appends `Archive/`. If `Archive/` was moved, this returns `Testing/Archive/` (a path that no longer exists). `NSPathControl` shows the path text but with a blank/white icon because the folder doesn't exist at that location.

**The breadcrumb shows a stale path because `archiveTreeRootURL` blindly appends `Archive/` to whatever the bookmark resolves to, without checking if that subfolder exists.**

### `ContentController.emptyContent(for: .archived)` — ~line 623

```swift
case .archived:
    let availability = model.refreshArchiveRootAvailability()
    switch availability {
    case .notConfigured:
        return .unavailable(title: "No Archive Destination", ...)
    case .unavailable:
        return .unavailable(title: "Archive Missing", ...)   // ← never reached in the broken case
    case .available:
        break
    }
    return .unavailable(title: "No Archive Photos", ...)   // ← always lands here
```

---

## What needs to be done

### Fix 1 — Extend `archiveRootAvailability` to check the archive subfolder

After the existing checks pass (root exists, is writable, not in trash), additionally verify:

```swift
// The root exists but the Archive/ subfolder and its control folder must also be present.
// If Archive/ was moved out of the root, the archive is gone even if the root is still accessible.
let paths = ArchiveControlPaths(rootURL: rootURL)
guard fileManager.fileExists(atPath: paths.archiveFolderURL.path) else {
    return .unavailable
}
guard fileManager.fileExists(atPath: paths.controlRootURL.path) else {
    return .unavailable
}
```

This single change causes `.unavailable` to be returned when the user has moved `Archive/` out of the root. That in turn:
- Makes `setup()` post `librarianArchiveNeedsRelink` → relink prompt fires ✅
- Makes `emptyContent(for: .archived)` return "Archive Missing" ✅

### Fix 2 — Breadcrumb shows unavailable state when archive subfolder is missing

`refreshArchivePath()` currently always shows a path (even a non-existent one). When availability is `.unavailable` and the archive subfolder is missing, the breadcrumb should either go blank or show a disabled/greyed indicator.

Option A — simplest: check `model.archiveRootAvailability` before setting the URL:

```swift
private func refreshArchivePath() {
    guard model.archiveRootAvailability != .unavailable,
          let treeRoot = ArchiveSettings.currentArchiveTreeRootURL() else {
        archivePathControl.url = nil
        return
    }
    archivePathControl.url = treeRoot
    ...
}
```

Option B — show the path but leave it visually distinct (NSPathControl naturally shows a white icon for a non-existent path). This is already happening but feels broken. Option A is cleaner.

### Fix 3 (already applied, keep) — Archive view bypasses Photos auth guard

`ContentController.loadAssetsIfNeeded`, `loadNextPageIfNeeded`, and `updateOverlay` no longer block the archive sidebar behind `photosAuthState == .authorized`. This is correct — archive data is local DB + filesystem, no PhotoKit needed.

### Fix 4 (already applied, keep) — Trash detection in root availability

The trash path check remains useful for the case where the user trashes `Testing/` (the root). Keep it.

---

## Other notes

- `restoreArchiveRootURL()` silently calls `persistArchiveRootURL(url)` when the bookmark is stale (same-volume move of the root). `persistArchiveRootURL` calls `ensureControlFolder` which **creates** the `.librarian/` directory structure if it doesn't exist. This means a stale bookmark resolution on a valid root will recreate missing control folders, which is probably fine, but worth knowing.

- The `runArchiveRelinkFlow` in `ArchiveRelinkFlow.swift` correctly handles both the "user selects the parent folder" and "user selects the `Archive/` folder directly" cases via `resolveArchiveRoot(from:)`. The relink flow itself is fine — the problem is exclusively in detection, not resolution.

- The `@Published var archiveRootURL: URL?` added to `AppModel` is not currently wired up to anything beyond being kept in sync by `refreshArchiveRootAvailability()`. It can be used by future Combine subscribers but is inert at present.

- `librarianArchiveNeedsRelink` fires at most once per launch (posted in `setup()`). If the user dismisses the relink dialog, there is no way to re-trigger it without restarting the app, except via Settings. This is acceptable for now but worth noting.
