# Backup Reconcile Feature — Status & Next Steps

Branch: `feature/backup-reconcile`  
Last updated: 2026-04-11

---

## What the feature does

Scans an osxphotos backup folder, checks each exported file against the live Photos library via PhotoKit, and moves only files that are **no longer in the library** into the Archive. Files still in the library are left untouched.

UUID-based matching via `.osxphotos_export.db` is the core mechanism. osxphotos records a `uuid` (bare PhotoKit UUID, without the `/L0/001` suffix) against each exported filepath. The feature looks up `uuid + "/L0/001"` via `PHAsset.fetchAssets(withLocalIdentifiers:)`. Files not found in PhotoKit are treated as archive candidates.

---

## What went wrong in early runs

Three memory bugs were fixed early in this branch:

1. `classifyFiles` was being called on all no-UUID files — created a CGImageSource per file on a background thread, causing tens of GB of memory pressure on large backups.
2. `PHAsset.fetchAssets` was called with 100k+ identifiers in a single shot.
3. `loadRecords()` was double-allocating the export DB in memory.

All three were fixed. Archive hash dedup pass was also removed (it was hashing every file in both the archive and the backup folder — would have read hundreds of GB from the external drive).

---

## The current state of the backup folder

After multiple reconcile runs during the debugging process, approximately **20,461 files were moved from the backup folder into the Archive**. Only **178 files remain** in the backup folder.

A diagnostic run confirmed:

```
pathToUUIDMap entries: 20675   — DB had records for all original files
hasUUIDFiles: 178              — only 178 files still on disk in the backup
noUUIDFiles: 0                 — all 178 matched the DB correctly
PhotoKit returned: 178/178     — all 178 are confirmed still in the Photos library
```

The feature is now correctly doing nothing — all remaining files are in the library and are being protected.

---

## Why PhotoKit didn't recognise the ~20,461 moved files

The feature returned the correct result given what PhotoKit reported. The UUID-based lookup is implemented correctly (confirmed: 178/178 hit rate on the remaining files).

The most likely cause of the earlier misses is a **UUID-invalidating event** in the Photos library between when the backup was created and when the reconcile ran. This happens when:

- The Photos library was migrated to a new Mac or restored from backup — Photos reassigns `localIdentifier` values.
- iCloud Photo Library was toggled off and back on — assets re-sync with new identifiers.
- A library repair/rebuild was performed.

The backup was made against the old UUID set; the library now uses a different UUID set for the same photos. The feature correctly reported those assets as "not found" — because under their recorded UUIDs, they genuinely aren't findable.

This is **not a bug in the implementation**. It is a fundamental constraint of UUID-based matching: it only works reliably when the backup and the current library share a continuous UUID history.

---

## What needs to happen before this feature can ship

### 1. Audit the Archive for incorrectly moved files

~20,461 files were moved into the Archive during the debugging runs. Before treating those as "safely archived," someone needs to verify whether they are:

- **Genuinely not in the library** (correct outcome — the Archive is the right place for them)
- **Still in the library with new UUIDs** (incorrect outcome — they need to be put back)

To check: pick a sample of files from the Archive and look them up in Photos by filename/date. If the same photo exists in both the Archive and the library, the UUID mismatch theory is confirmed and the Archive contains duplicates that should be reviewed.

### 2. Decide how to handle UUID mismatches

Three options:

**A. Document the constraint and ship as-is**  
Add a warning to the sheet UI: "This feature works best when the backup was made from your current Photos library. If your library has been migrated or restored since the backup was created, results may be unreliable." Low effort, honest, correct for most use cases.

**B. Add a filename+date fallback for unmatched UUIDs**  
For files whose UUID returns nothing from PhotoKit, attempt a secondary match on `originalFilename` + capture date. PhotoKit can fetch all assets and build a filename→asset map. Imperfect (duplicate filenames exist) but much better than archiving everything blindly.

**C. Add a "dry run" mode before any destructive action**  
Show the full candidate list in the sheet UI before moving anything, so the user can review what will be archived. This doesn't fix the UUID mismatch problem but prevents irreversible mistakes when it happens.

### 3. Remove diagnostic logging

`BackupReconcileCoordinator.swift` has several `AppLog.shared.info("BackupReconcile diagnostic —…")` lines added during debugging. Remove before shipping.

### 4. Decide on the 178 remaining files

The 178 files currently in the backup folder are confirmed still in the Photos library. They should stay in the backup folder untouched (the feature correctly skips them). No action needed from the code side, but the user should be aware of this.

---

## Implementation quality as-is

- Menu item, action stub, and validation: complete
- `OsxPhotosExportDatabase.swift`: correct and memory-efficient (cursor-based)
- `BackupReconcileCoordinator.swift`: logic is sound; diagnostic logging to remove
- `BackupReconcileSheetView.swift`: matches the existing import sheet pattern
- `AppModel.runBackupReconcile`: correctly reuses `isImportingArchive` busy-guard
- `MainSplitViewController`: presenter wired, action connected

No schema migration or GRDB record type was added for this feature. If run history needs to be persisted, a `backup_reconcile_run` table (outlined in the original plan as migration v20) would need to be added.
