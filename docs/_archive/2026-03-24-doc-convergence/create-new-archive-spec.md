# Create New Archive - Implementation Spec (v1)

## Goal

Add a user-initiated workflow to create a new active archive root and ingest photos from selected folders into Librarian's archive structure, while preventing duplicates:

- within imported folders
- against PhotoKit library

Resulting archive layout remains canonical: `Archive/YYYY/MM/DD`.

## UX Flow

1. In Settings, user clicks `Create New Archive…`.
2. Step 1: choose new archive root folder.
3. Step 2: choose one or more source folders to import from.
4. App runs preflight scan and shows report with:
   - total discovered
   - exact duplicates in sources (to skip)
   - items already in PhotoKit (to skip)
   - items to import
5. User confirms `Create Archive`.
6. App imports into new root, indexes Archived view, and switches active archive root to new location.
7. Completion summary shown with `View Log` / `Open Archived View`.

## Dedupe Rules (v1)

- In-source dedupe: exact hash match (`SHA-256`) on file bytes.
- Against PhotoKit: exact match only in v1.
- Preferred key: existing fingerprint if available in DB.
- Fallback: hash of exported/original resource when needed.
- No near-duplicate matching in v1 (avoid false positives).

## Import and Organization Rules

- Eligible files: same supported archived-media set currently used by Archived indexer.
- Destination path: `Archive/YYYY/MM/DD/<filename>`.
- Date source: EXIF capture date for supported image formats, fallback to file modification date.
- Name collisions: suffix (`-2`, `-3`, ...).
- Cleanup: remove empty intermediate folders created/left over during import only when empty.
- Source folders are never modified: no deletions, moves, renames, or writes of any kind. The import reads files and nothing else.

## Data and State Changes

- Add import job type: `archiveImport`.
- Add persisted import run summary (counts + skipped reasons + failures).
- Reuse current archive root bookmark as single source of truth.
- On successful completion:
  - update archive root setting
  - post archive root changed + archive queue changed notifications
  - refresh archived index + sidebar counts

## Services and Architecture

- New service: `ArchiveImportCoordinator` with:
  - preflight scan
  - dedupe decisions
  - copy/import execution
  - progress callbacks
- Reuse `ArchiveOrganizer` strategy system (future layout options compatible).
- Reuse `ArchiveIndexer` for final indexing pass.

## Failure Handling

- Partial failures allowed; continue import where safe.
- Always produce final report with:
  - imported
  - skipped duplicate-in-source
  - skipped exists-in-PhotoKit
  - failed
- Never switch active archive root if import fails before any valid archive state is created (atomic finalize step).

## Acceptance Tests

1. Import from two folders with overlapping identical files -> one copied.
2. File already present in PhotoKit -> skipped with reason.
3. Mixed dated/undated media -> all routed into valid `YYYY/MM/DD`.
4. Filename collision in destination -> suffixed copy created.
5. Large import interruption -> resumable-safe behavior or clean failure report, no data loss.
6. On completion, Archived view shows imported content under new active root.

## Explicit v1 Defaults

- Exact dedupe only.
- No destructive operations on source folders.
- Single active archive root model retained.
- Fixed layout strategy: `Archive/YYYY/MM/DD` (future strategy options can be added later).
