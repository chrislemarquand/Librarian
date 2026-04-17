# Backup Reconcile Feature — Implementation Plan

## Overview

Add a **"Reconcile Backup Folder…"** flow to Librarian that reads an osxphotos backup
folder, checks each photo against the live PhotoKit library, and moves only photos that
are **no longer in the library** into the Archive. Photos still in the library are left
untouched. This is the inverse of the existing `ArchiveAddPhotosFlow` (which skips
things already in Photos; this one specifically targets them).

**The core principle matches the app's philosophy:** the Archive should only contain
things that have left the Photos library. This feature automates the sift between a
backup and the current library state.

---

## Key Insight: Use UUID, Not SHA-256

The existing `ArchiveImportCoordinator` dedupes against PhotoKit by SHA-256. This
**won't work reliably for osxphotos exports** because `--exiftool` rewrites metadata
into each exported file, meaning the same photo exported twice has a different hash.

The right approach: **every file in an osxphotos backup folder has a PhotoKit UUID**,
recorded in `.osxphotos_export.db` (`export_data.uuid`). PhotoKit's
`PHAsset.fetchAssets(withLocalIdentifiers:)` is a direct, cheap O(1) lookup:

- UUID **found** in PhotoKit → photo is still in the library → skip
- UUID **not found** → photo was removed/deleted → archive candidate

For files with no UUID record (e.g. files copied into the backup folder without going
through osxphotos), fall back to the existing `ArchiveExactDedupeService` (size + date
prefilter + SHA-256 against `PHAssetResource`).

---

## Files to Create

### 1. `Sources/Librarian/Model/OsxPhotosExportDatabase.swift`

Thin SQLite reader for `.osxphotos_export.db`. No dependency on the rest of the app.

```swift
/// Reads an osxphotos `.osxphotos_export.db` file.
struct OsxPhotosExportDatabase {

    struct ExportRecord {
        let relativePath: String   // e.g. "2023/06/30/IMG_6173.HEIC"
        let uuid: String?          // Apple Photos localIdentifier
        let digest: String?        // SHA-1 of the exported file (written by osxphotos)
        let srcSize: Int?          // size of original in Photos library
    }

    let url: URL

    /// Returns nil if no .osxphotos_export.db exists in the folder.
    static func locate(in backupFolder: URL) -> URL? {
        let candidate = backupFolder.appendingPathComponent(".osxphotos_export.db")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    /// Loads all export_data rows. Throws if the DB can't be opened.
    func loadRecords() throws -> [ExportRecord]

    /// Returns Set<String> of all non-nil UUIDs in the database.
    func allUUIDs() throws -> Set<String>
}
```

**Implementation notes:**
- Use `sqlite3` C API directly (already available, no new dependencies needed)
- Or open with a temporary `GRDB.DatabaseQueue` — but keep it isolated, not the app's
  main database
- Query: `SELECT filepath, uuid, digest, src_size FROM export_data`

---

### 2. `Sources/Librarian/Model/BackupReconcileCoordinator.swift`

The main logic class. Modelled directly on `ArchiveImportCoordinator`.

```swift
final class BackupReconcileCoordinator: @unchecked Sendable {

    private let backupFolder: URL
    private let archiveRoot: URL
    private let photosService: PhotosLibraryService
    private let database: DatabaseManager
    private let exactDedupeClassifier: ArchiveExactDedupeClassifying

    init(
        backupFolder: URL,
        archiveRoot: URL,
        photosService: PhotosLibraryService,
        database: DatabaseManager,
        exactDedupeClassifier: ArchiveExactDedupeClassifying? = nil
    )

    func runPreflight() async throws -> BackupReconcilePreflightResult
    func runReconcile(preflight: BackupReconcilePreflightResult)
        -> AsyncThrowingStream<BackupReconcileProgressEvent, Error>
}
```

#### Preflight algorithm

```
1. Locate backup folder's .osxphotos_export.db
   → if missing: warn user, offer to proceed with full dedup-only fallback

2. Load all ExportRecords from the DB
   → build: [relativeFilePath → uuid?] map

3. Enumerate actual files in the backup folder
   → match each file to its DB record by relative path
   → group into: hasUUID[], noUUID[]

4. Batch UUID lookup via PhotoKit
   → PHAsset.fetchAssets(withLocalIdentifiers: allUUIDs, options: nil)
   → split hasUUID[] into:
       stillInLibrary[]   (UUID found → skip)
       notInLibrary[]     (UUID not found → archive candidate)

5. For noUUID[] files:
   → run ArchiveExactDedupeService.classifyFiles(noUUID, allowNetworkAccess: false)
   → .exactMatch → stillInLibrary (skip)
   → .noMatch / .indeterminate → archive candidate (precautionary)

6. Check all candidates against existing archive hashes
   → already in archive → skip

7. Return BackupReconcilePreflightResult
```

#### Reconcile execution

- **MOVE** files from backup folder into `{archiveRoot}/Archive/YYYY/MM/DD/`
  (use `bestAvailableDate` logic identical to `ArchiveImportCoordinator`)
- Use `uniqueDestinationURL` for collision handling
- Write a `backup_reconcile_run` audit row on completion
- Update `isImportingArchive` published state on `AppModel` (reuse existing busy-guard)

---

### 3. `Sources/Librarian/Model/BackupReconcileFlow.swift`

Top-level flow function, mirrors `ArchiveAddPhotosFlow.swift`.

```swift
@MainActor
func runBackupReconcileFlow(model: AppModel, presentingWindow: NSWindow?) async

// Steps:
// 1. Guard archive configured
// 2. NSOpenPanel: pick a backup folder (canChooseDirectories: true, canChooseFiles: false)
//    → check for .osxphotos_export.db, warn if missing
// 3. Run preflight (Task.detached priority: .utility)
// 4. Show preflight confirmation sheet
// 5. Run reconcile (streams progress)
// 6. Show completion summary
```

#### Preflight confirmation message

```
"Reconcile Backup Folder?"

Scanned 27,500 photos in the backup folder.

• 22,230 photos are still in your Photos Library and will be left in place.
• 4,812 photos are no longer in your library and will be moved to the Archive.
• 156 photos are already in your Archive and will be skipped.
• 302 photos couldn't be matched — they will be moved to the Archive as a precaution.

5,270 photos will be moved into the Archive.
```

---

### 4. `Sources/Librarian/Shell/BackupReconcileSheetView.swift`

Progress sheet. Can reuse / closely mirror `ArchiveImportSheetView.swift`.

- Shows: spinner + "Reconciling backup… X / Y"
- Cancel button (sets a cancellation flag checked between file moves)
- On completion: switches to summary view before dismissing

---

## Files to Modify

### `Database/Migrations.swift` — add v20

```swift
migrator.registerMigration("v20_add_backup_reconcile_run") { db in
    try db.create(table: "backup_reconcile_run") { t in
        t.primaryKey("id", .text)
        t.column("runAt", .datetime).notNull()
        t.column("backupFolderPath", .text).notNull()
        t.column("discovered", .integer).notNull().defaults(to: 0)
        t.column("archived", .integer).notNull().defaults(to: 0)
        t.column("skippedInLibrary", .integer).notNull().defaults(to: 0)
        t.column("skippedInArchive", .integer).notNull().defaults(to: 0)
        t.column("noUUIDArchived", .integer).notNull().defaults(to: 0)
        t.column("failed", .integer).notNull().defaults(to: 0)
    }
}
```

### `Database/AssetRepositoryModels.swift` — add record

```swift
struct BackupReconcileRun: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "backup_reconcile_run"
    var id: String
    var runAt: Date
    var backupFolderPath: String
    var discovered: Int
    var archived: Int
    var skippedInLibrary: Int
    var skippedInArchive: Int
    var noUUIDArchived: Int
    var failed: Int
}
```

### `Model/AppModel.swift` — wire the new flow

- Add `runBackupReconcile(backupFolder:preflight:)` method (mirrors `runArchiveImport`)
- Reuse `isImportingArchive` busy-guard — reconcile and import are mutually exclusive

### `Shell/SidebarController.swift` or `ArchiveSettingsViewController.swift`

Add entry point. Two options:

**Option A (preferred):** "Reconcile Backup Folder…" button in
`ArchiveSettingsViewController`, below the archive root picker. Descriptive subtitle:
*"Move photos from an osxphotos backup that are no longer in your library into the Archive."*

**Option B:** New sidebar item under the Archive section. Less prominent, may suit
later when the feature is more visible.

---

## New Result Types

```swift
struct BackupReconcilePreflightResult: Sendable {
    let totalDiscovered: Int
    let stillInLibrary: Int         // UUID found in PhotoKit
    let toArchive: Int              // UUID not found (or no UUID + no dedup match)
    let alreadyInArchive: Int       // hash matches existing archive item
    let noUUIDCount: Int            // files with no UUID record in export DB
    let hasExportDatabase: Bool     // false = no .osxphotos_export.db found
    let candidateURLs: [URL]
}

struct BackupReconcileRunSummary: Sendable {
    let archived: Int
    let skippedInLibrary: Int
    let skippedInArchive: Int
    let failed: Int
    let failures: [(path: String, reason: String)]
    let completedAt: Date
}

enum BackupReconcileProgressEvent: Sendable {
    case progress(completed: Int, total: Int)
    case done(summary: BackupReconcileRunSummary)
}
```

---

## Edge Cases & Notes

### No `.osxphotos_export.db` present
If the backup folder has no export DB (e.g. files copied in manually), the coordinator
falls back entirely to `ArchiveExactDedupeService`. Show a warning in the preflight:
*"No osxphotos database found. Matching by file content only — this may be slower and
less accurate."* The option `hasExportDatabase: false` in the preflight result drives
this message.

### `--cleanup` risk
**Do not run this reconcile flow on the same folder that osxphotos actively exports to**
if the user ever adds `--cleanup` to their export command. `--cleanup` deletes any file
in the export folder that's not in the export DB — which would wipe moved/added files.
Add a note in the confirmation sheet: *"After reconciling, keep this backup folder as
read-only or stop running osxphotos exports to it."*

### Videos (`.mov`, `.mp4`, `.m4v`)
`ArchiveImportCoordinator.supportedExtensions` currently only lists image types. The
osxphotos backup includes video files. Extend `supportedExtensions` in
`BackupReconcileCoordinator` to include `mov`, `mp4`, `m4v`, `mpg`, `avi`, `3gp`.
The `ArchiveIndexer` should also be checked for video support.

### iCloud-only assets
If a photo's UUID is in PhotoKit but `isCloudOnly == true` and not downloaded locally,
`ArchiveExactDedupeService` will return `.indeterminate`. The UUID lookup path sidesteps
this: if the UUID is found in PhotoKit it's "still in library" regardless of download
state, so the file is correctly skipped. No special handling needed.

### Partial runs / resume
If the user cancels mid-reconcile, already-moved files are committed (no rollback).
On next run, preflight will correctly skip them (they'll show as `alreadyInArchive`).
This is the same behaviour as `ArchiveImportCoordinator`.

---

## Sequence Diagram

```
User clicks "Reconcile Backup Folder…"
    │
    ▼
runBackupReconcileFlow()
    │
    ├─ NSOpenPanel → picks backup folder
    │
    ├─ BackupReconcileCoordinator.runPreflight()   [Task.detached]
    │     ├─ OsxPhotosExportDatabase.loadRecords()
    │     ├─ enumerate files in backup folder
    │     ├─ PHAsset.fetchAssets(withLocalIdentifiers:)   ← UUID batch lookup
    │     ├─ ArchiveExactDedupeService.classifyFiles()    ← fallback for no-UUID files
    │     └─ existingArchiveHashes()
    │
    ├─ Show preflight confirmation sheet
    │
    └─ BackupReconcileCoordinator.runReconcile()   [AsyncThrowingStream]
          ├─ move files → Archive/YYYY/MM/DD/
          ├─ stream .progress events → UI
          ├─ write backup_reconcile_run audit row
          └─ yield .done(summary)
```

---

## Testing

Mirror existing test structure in `Tests/LibrarianTests/`.

- `BackupReconcileCoordinatorTests.swift`
  - `testAllUUIDsFoundInPhotoKit_nothingArchived`
  - `testNoUUIDsFoundInPhotoKit_allArchived`
  - `testMixedUUIDs_correctPartition`
  - `testNoExportDatabase_fallsBackToDedup`
  - `testAlreadyInArchive_skipped`
  - `testCancelMidRun_partialResultCommitted`
  - `testVideoFilesIncluded`

- `OsxPhotosExportDatabaseTests.swift`
  - `testLoadsRecordsFromRealDB` (use one of the real `.osxphotos_export.db` files as fixture)
  - `testLocate_findsDB`
  - `testLocate_returnsNilWhenMissing`

---

## Implementation Order

1. `OsxPhotosExportDatabase.swift` + tests — isolated, no dependencies
2. `Migrations.swift` v20 + `AssetRepositoryModels` additions
3. `BackupReconcileCoordinator.swift` (preflight only) + tests
4. `BackupReconcileCoordinator.swift` (reconcile execution)
5. `BackupReconcileFlow.swift` + `BackupReconcileSheetView.swift`
6. Wire into `AppModel` + `ArchiveSettingsViewController`
7. Manual smoke test with the real backup folders
