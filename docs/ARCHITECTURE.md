# Architecture

Librarian is a macOS-only Photos-library curation and archive workflow app.

- Deployment target: `macOS 26`
- Swift language mode: `Swift 6`
- UI model: AppKit shell with SwiftUI feature surfaces
- Shared dependency: `SharedUI` (local lockstep path in normal development)

## Repo structure

```text
Sources/Librarian/
  AppDelegate.swift
  main.swift
  Model/
  Photos/
  Database/
  Indexing/
  Shell/
  Tools/
Tests/LibrarianTests/
Config/
  Base.xcconfig
  Debug.xcconfig
  Release.xcconfig
```

`Librarian.xcodeproj` is project-first (not package-first) and owns app build/test orchestration.

## Runtime architecture

```text
NSApplication + AppDelegate
  -> NSWindow
    -> MainSplitViewController : ThreePaneSplitViewController
       -> AppKitSidebarController (sidebar)
       -> ContentController (gallery/indexing/log/archive views)
       -> InspectorController

AppModel (@MainActor, single source of truth)
  -> PhotosLibraryService (PhotoKit access)
  -> DatabaseManager (GRDB-backed state)
  -> Indexing + analysis + archive coordinators
```

Main ownership:
- `AppModel` owns app state and long-running workflow orchestration.
- Shell controllers own window/pane UI composition and command routing.
- Services/repositories own Photos and database access.

## SharedUI integration (current)

Librarian consumes these shared primitives from `SharedUI`:

- `ThreePaneSplitViewController` (window split behavior and metrics)
- `AppKitSidebarController` (sidebar shell)
- `SharedGalleryCollectionView` + `SharedGalleryLayout` (gallery interaction/layout)
- `PinchZoomAccumulator` (gallery pinch zoom behavior)
- `ToolbarAppearanceAdapter` (toolbar appearance refresh)
- `NSAlert.runSheetOrModal(...)` helper (sheet/modal consistency)

This keeps desktop shell behavior aligned with Ledger while preserving app-specific logic.

## Domain boundaries

Librarian-specific logic that remains local:

- Photo source integration via PhotoKit (`PhotosLibraryService`, `PhotosChangeTracker`)
- Library indexing pipeline (`AssetIndexer`, `LibraryAnalyser`)
- Persistent state and queues via GRDB repositories (`AssetRepository`, `JobRepository`)
- Archive workflows (set-aside, export/import, archived indexing)
- Sidebar taxonomy and inspector fields specific to Librarian's domain

Notably, gallery item image sourcing remains app-specific:
- Librarian: PhotoKit thumbnails + archived-file thumbnail service.
- Ledger: file-backed thumbnail engine.

SharedUI provides the gallery shell/interaction model, not the thumbnail backend.

## UI composition notes

- The shell is AppKit-first for split behavior, keyboard routing, menu/toolbar command handling.
- Sidebar/inspector content is hosted in SwiftUI where appropriate.
- `ContentController` drives gallery/list-like content plus indexing/log/archive contextual panes.
- Toolbar state is refreshed from model state through `ToolbarDelegate` + shell observation.

## Logging

`AppLog` (defined at the bottom of `AppModel.swift`) is a lightweight structured logger used throughout the app. It writes timestamped `[INFO]` / `[ERROR]` lines to:

```
~/Library/Application Support/com.chrislemarquand.Librarian/librarian.log
```

This file is not exposed in the app UI — it is developer-only. To inspect it:

```bash
tail -f ~/Library/Application\ Support/com.chrislemarquand.Librarian/librarian.log
```

Or open it in Console.app by navigating to the path above. `AppLog` is not user-facing and has no in-app viewer.

## Concurrency and safety

- `AppModel` and shell coordination run on `@MainActor`.
- Background work is isolated to dedicated async tasks/services (indexing, analysis, archive, thumbnail generation).
- Swift 6 migration follow-ups are tracked in `docs/Swift6 Migration Backlog.md`.

## Key docs

- `docs/README.md`
- `docs/CURRENT_STATE.md`
- `docs/Engineering Baseline.md`
- `docs/RELEASE_CHECKLIST.md`
- `docs/Swift6 Migration Backlog.md`
- `ROADMAP.md`
