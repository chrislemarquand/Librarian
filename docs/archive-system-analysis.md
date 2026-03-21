# Archive System — Current State Analysis

Last updated: 2026-03-21

---

## What exists and where

The archive is built across four layers:

### Data model (`Migrations.swift`, `AssetRepository.swift`)

- **`archive_candidate`** — tracks assets queued for export with a state machine: `pending → exporting → exported → deleted` (or `failed`). Includes crash recovery: stale `exporting` rows are reset to `failed` on startup.
- **`archived_item`** — an index of files physically on disk in the archive tree, built by the indexer. Stores relative path, file metadata, EXIF capture date, pixel dimensions, thumbnail cache path.
- **`archive_import_run`** — history log of "Create New Archive" import jobs.

### Settings/availability layer (`AppModel.ArchiveSettings`)

- Archive root stored as a security-scoped bookmark in UserDefaults.
- Control folder (`.librarian/archive.json`) at the archive root holds a stable UUID archive ID, schema version, and creation metadata.
- Availability checking covers: not configured, available, path-missing (external drive offline), read-only volume, permission denied.

### Coordination layer

- **`ArchiveImportCoordinator`** — imports files from external folders into the archive tree. SHA-256 dedup within source, EXIF-based matching against PhotoKit, YYYY/MM/DD destination structure.
- **`ArchiveOrganizer`** — normalises files already in the archive that aren't in YYYY/MM/DD layout.
- **`ArchiveIndexer`** — walks the archive tree on disk and syncs it into the `archived_item` table. Runs on every archive view load.
- **`ArchivedThumbnailService`** — on-demand thumbnail generation and disk/memory caching for archive gallery items.

### UI layer

- Archive Settings pane: Change location (with move-or-new-archive choice), Organize Archive, Create New Archive.
- "Set Aside" sidebar queue — shows `pending/exporting/failed` candidates.
- "Archive" sidebar view — gallery of `archived_item` records with organize-banner if unorganized files detected.
- Export options sheet (keep originals alongside edits, keep Live Photos components).

---

## The incoherence — what's haphazard

### 1. Three separate "add things to the archive" paths with different entry points and UX

- **Set Aside → Export** — the primary workflow: queue a photo from a review box, then export it. This is the core product loop.
- **Create New Archive** — imports files from existing folders on disk. Designed for one-time bootstrap.
- **Organize Archive** — reorganises files already at the archive root that aren't in YYYY/MM/DD layout.

These three paths share some infrastructure but have separate UI surfaces with no clear conceptual hierarchy. The settings pane is the only place all three are accessible, but it frames them as peer settings options rather than a coherent workflow.

### 2. Archive folder structure diverges from spec

**Spec:** `Photos/YYYY/MM` and `Other/{Category}/YYYY/MM` (screenshots, low quality, etc. go to `Other/`).
**Reality:** everything goes to a flat `Archive/YYYY/MM/DD/` regardless of category. The implication that different queue types should land in different archive subfolders is entirely unimplemented.

### 3. ArchiveOrganizer, ArchiveIndexer, and ArchivedThumbnailService live in ContentController.swift

These are substantial utilities (~500 lines combined) sitting inside the view controller file. They work but are architecturally misplaced — they belong in the model/service layer.

### 4. Export pipeline still has spec divergences

- `--skip-original-if-edited` is passed to osxphotos — exports edited version only, not both.
- `--skip-live` is passed — drops the video component of Live Photos.
- osxphotos runs as a direct subprocess (`Process()`), not an XPC service — breaks at distribution.

These are documented in `CLAUDE.md` as known bugs, not design choices.

### 5. The "Change archive location" UX is complicated

Selecting a folder triggers a 3-way branch: move existing archive, use as new archive, or cancel — plus separate confirmation prompts for archive ID mismatch and fresh initialisation. The copy-and-verify move is a multi-step async flow that can fail mid-way. This is all correct and safe, but it's exposed as a single button labelled "Change…" with no affordance that it's a high-stakes operation.

### 6. No archive-level relink for moved archives

If the user moves the archive folder on disk outside the app (e.g., Finder drag to a new external drive), there's no relink flow — the bookmark just goes stale. `ROADMAP.md` marks this as `[Partial]`.

### 7. Export sheet options have unclear defaults

`keepOriginalsAlongsideEdits` and `keepLivePhotos` toggles exist in the sheet, but the underlying osxphotos flags currently contradict whatever the user selects (the flags are hardcoded, not wired to the toggles).

---

## What's solid

- The `archive_candidate` state machine and crash recovery are well-implemented.
- The `.librarian/archive.json` control folder with a stable archive UUID is the right foundation for relink, multi-archive handling, and identity tracking.
- Security-scoped bookmark handling is correct throughout.
- The availability checking enum covers all meaningful offline/permission states.
- Archive move preflight (free space, conflict detection, recursive-copy guard) is thorough.
- The `archived_item` indexer and thumbnail cache are functional.

---

## Summary of what needs coherence work

| Issue | Severity | Location |
|---|---|---|
| Export flags hardcoded, contradicting UI toggles | Critical | `AppModel.runOsxPhotosExportBatch` |
| osxphotos as direct subprocess, not XPC | Critical (distribution) | `AppModel.runOsxPhotos` |
| Archive folder structure ignores queue category | Design gap | `ArchiveImportCoordinator`, export batch |
| ArchiveOrganizer/Indexer/Thumbnails in ContentController | Architecture debt | `ContentController.swift` |
| No relink flow for externally moved archives | Missing feature | `ArchiveSettings`, Settings UI |
| Change… button UX doesn't signal high-stakes operation | UX roughness | `ArchiveSettingsViewController` |
| Create New Archive is peer to Change Location in settings | Conceptual framing | `ArchiveSettingsViewController` |
