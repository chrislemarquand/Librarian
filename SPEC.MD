# Librarian — Product and Engineering Spec (v0.5)

## 1. Product summary

**Librarian** is a native macOS companion app for Apple Photos that helps a user reduce an overwhelming photo library into a smaller, more meaningful active library, while **never permanently deleting anything without archiving it first**.

It is not a replacement for Photos.app. It sits alongside Photos and provides:

- review queues for clutter and weak images
- context-aware curation within days, trips, and events
- safe archive/export-before-removal workflows
- local-first analysis and classification
- a standard native Mac photo-utility UI

The app should feel like a simple, serious Mac utility, not an AI toy.

## 2. Core product principles

1. **Photos.app remains the source of truth.**
2. **Nothing is destroyed outright.** Anything removed from the active library must first be exported and verified in an archive.
3. **Native-first.** Prefer Apple APIs and frameworks wherever practical.
4. **AppKit-first.** SwiftUI may be used only in strict islands, not as the main app shell.
5. **Low-cost intelligence.** Core functionality should work without paid cloud AI.
6. **Context matters.** Recommendations should often be made relative to nearby photos from the same day/event/trip, not just on isolated images.
7. **Human approval remains central.** The app suggests; the user decides.
8. **Librarian owns its own intelligence.** Categories, scores, queues, and review state live in Librarian, not in Photos.
9. **v1 Photos mutations are limited.** In v1, the only write to Photos is deletion, and only after verified archival export.
10. **Future Photos write actions remain architecturally possible.** Features like album creation may be added later through a separate mutation layer.

## 3. Primary user problem

The user has a very large Apple Photos library, potentially 100,000+ photos, and wants:

- no screenshots in the main library
- fewer duplicates and near-duplicates
- fewer bad or accidental photos
- a library that tells the story of their life
- a way to remove clutter without losing anything permanently

## 4. Non-goals

- Replacing Photos.app as the primary library browser
- Building a custom DAM from scratch
- App Store distribution
- Heavy cloud dependence
- Large amounts of custom UI/chrome
- Permanent deletion workflows as a default interaction model
- Writing metadata, keywords, captions, or organisational changes back into Photos in v1

## 5. Product model

Librarian should be understood as:

- a **reader of Photos**
- a **thinker beside Photos**
- an **archivist outside Photos**
- and a **careful remover from Photos**

In v1, Librarian reads from Photos, computes categories and review queues for itself, archives selected items to a user-controlled archive, verifies the archive, and then deletes selected items from Photos.

It does **not** write metadata, keywords, captions, or albums back into Photos in v1.

## 6. Target platform

- **macOS only**
- Assume **Apple silicon** as the primary target
- Personal-use / direct distribution / notarized app is acceptable
- No requirement for App Store distribution
- **Primary release model:** Developer ID signed + notarized direct distribution (DMG/zip)
- **No App Sandbox requirement for v1** (future App Store track is optional, separate scope)

## 7. Technical architecture

### 7.1 High-level stack

- **AppKit** for the main application shell
- **PhotoKit** for live Photos library access, fetches, thumbnails, and change tracking
- **Vision** for OCR and image-analysis tasks
- **Core ML** for local classification/scoring where useful
- **Foundation Models** for on-device language tasks on supported systems
- **GRDB** as the Swift SQLite layer, using its built-in migration system
- **osxphotos** (bundled, pinned version) as a helper for archival export

### 7.2 Architectural principle

**Use Apple frameworks for the app's live behaviour. Use osxphotos for archive/export muscle.**

#### Apple-native layer owns
- browsing and selection
- asset identity
- thumbnails and previews
- change tracking
- local analysis
- review queues
- search/index state
- archive status tracking
- future Photos mutation interface

#### osxphotos helper owns
- export jobs
- export templating
- archive folder layout execution
- sidecar/metadata-preserving export workflows

### 7.3 Critical rule

**Do not use osxphotos as the primary live read path for the app UI.**

PhotoKit is the main runtime interface for browsing, selection, thumbnails, metadata reads, and change tracking. `osxphotos` is tightly scoped to export/archive tasks only.

### 7.4 osxphotos provisioning

**osxphotos is bundled inside the app at a pinned version.** The app does not depend on any user-installed Python or osxphotos. The app controls:

- which version of osxphotos is used
- how the Python environment is provisioned and isolated
- how failures are logged and surfaced
- how long-running export tasks are monitored and cancelled

For direct distribution, bundled tools must be shipped, code-signed, and runtime-validated as part of the app. XPC is an optional isolation mechanism, not a mandatory distribution requirement.

### 7.5 Runtime security posture

The release target is **notarized direct distribution**. Security requirements include:

- Hardened Runtime enabled for release builds
- Developer ID code signing for app and bundled helper executables
- Notarization + stapling for shipped artifacts
- Security-scoped bookmarks for persistent archive-root access across launches

App Sandbox/App Store entitlements are explicitly out of scope for v1.

### 7.6 Process model

- Main macOS app process in Swift/AppKit
- Background worker(s) for indexing and analysis
- Internal task runner process boundary for `osxphotos` jobs (direct subprocess or XPC service)
- Job queue persisted in GRDB/SQLite

Do not block the UI on full-library scans or export tasks.

## 8. Persistence

### 8.1 Database

**GRDB** is the Swift SQLite layer. Use GRDB's built-in migration system for all schema changes.

Migration policy:
- All schema changes are expressed as named, sequential GRDB migrations registered at startup
- Migrations are applied automatically on launch before any database access occurs
- Migrations are append-only — never modify an existing migration
- Migration names should be descriptive: e.g. `"v1_initial_schema"`, `"v2_add_icloud_download_state"`

This gives explicit control over large-library queries, easy bulk inserts/updates, straightforward job/state/cache tables, and good transparency and debuggability.

### 8.2 Database location

Store the GRDB database in the app's Application Support container directory. Preserve the database if Photos library access is revoked — the user can still browse their existing local index in a read-only locked state.

## 9. Reuse from Ledger

Librarian reuses Ledger's existing native window/shell work wherever practical.

Reuse:
- window shell
- split-view setup
- toolbar style/philosophy
- inspector pattern
- command/menu structure
- keyboard navigation
- contextual menu patterns
- any existing task/progress infrastructure that fits

Do **not** inherit Ledger's domain-specific centre-pane assumptions. Reuse the frame, not the purpose. Ledger's centre pane is list/table-oriented; Librarian's is primarily a photo grid with group and context modes. The centre pane is where the two apps diverge most significantly.

## 10. Data model

### 10.1 Asset
One row per Photos asset.

Fields:
- `localIdentifier`
- `creationDate`
- `modificationDate`
- `mediaType`
- `mediaSubtypes`
- `pixelWidth`
- `pixelHeight`
- `duration`
- `isFavorite`
- `isHidden`
- `isScreenshot`
- `isCloudOnly`
- `hasLocalThumbnail`
- `hasLocalOriginal`
- `iCloudDownloadState` — enum: `notRequired` / `pending` / `inProgress` / `retrying` / `failed` / `complete`
- `previewCachePath`
- `analysisVersion`
- `lastSeenInLibraryAt`
- `isDeletedFromPhotos`

### 10.2 AssetResource
One row per exported file. One Photos asset may produce multiple resources.

Fields:
- `id`
- `assetLocalIdentifier`
- `resourceType` — e.g. `original`, `edited`, `pairedVideo`, `alternateOriginal`, `fullSizeVideo`
- `originalFilename`
- `uti`
- `isPrimaryArchiveResource`
- `archivePath`
- `fileSize`
- `checksum`
- `exportJobID`

**Multi-file asset rules:**
- **Edited photos:** both original and edited versions exported — two rows
- **Live Photos:** JPEG + MOV exported as a pair — two rows
- **RAW+JPEG pairs:** both files exported — two rows
- **Bursts:** each burst member is a separate PHAsset, treated individually

### 10.3 Context
A grouping: day, trip, event, album, location cluster, or auto-generated cluster.

Fields:
- `id`
- `type`
- `title`
- `startDate`
- `endDate`
- `locationSummary`
- `assetCount`

### 10.4 Collection
A Librarian-owned grouping or projection (Screenshots, Duplicates, Review Later, Story Picks, Archive Candidates, etc.).

Fields:
- `id`
- `type`
- `title`
- `description`
- `isSystemCollection`
- `createdAt`
- `updatedAt`

### 10.5 CollectionMembership
Fields:
- `collectionID`
- `assetLocalIdentifier`
- `score`
- `role`
- `explanation`

### 10.6 Analysis
Per-asset computed outputs.

Fields:
- `assetLocalIdentifier`
- `ocrText`
- `clutterCategory`
- `qualityScore`
- `duplicateClusterID`
- `storyScore`
- `archiveRecommendation`
- `explanationSnippet`
- `computedAt`
- `analysisVersion`

### 10.7 ReviewDecision
User decisions.

Fields:
- `id`
- `assetLocalIdentifier`
- `decision` — `keepInLibrary` / `archiveFromLibrary` / `keepAsAlternate` / `reviewLater`
- `reason`
- `createdAt`
- `updatedAt`

### 10.8 ArchiveRecord
Tracks archival state per asset.

Fields:
- `id`
- `assetLocalIdentifier`
- `archiveJobID`
- `archiveCategory`
- `archiveRoot`
- `archivePath`
- `exportMode`
- `exportedAt`
- `verificationStatus`
- `deletionStatus`
- `notes`

### 10.9 Job
Tracks long-running work.

Fields:
- `id`
- `type`
- `state`
- `progress`
- `createdAt`
- `startedAt`
- `finishedAt`
- `payloadJSON`
- `errorText`

Job types:
- `initialIndex`
- `incrementalSync`
- `thumbnailWarmup`
- `iCloudDownload`
- `ocrAnalysis`
- `duplicateAnalysis`
- `contextClustering`
- `archiveExport`
- `archiveVerification`
- `photosDeletion`
- `archiveRootMigration`

## 11. Photos integration model

### 11.1 Authorization

On first launch, request full Photos library access. If the user grants limited access, refuse it and present a clear explanation that Librarian requires full access to function, with a prompt to change this in System Settings.

If access is denied or revoked while the app is running, show a locked state UI with a prompt to re-authorise in System Settings. Disable all live features. Preserve the local GRDB database — the user can still browse their existing index in read-only mode.

### 11.2 Read model

PhotoKit is used for:
- fetching assets
- reading metadata
- reading albums/folders
- requesting thumbnails/previews
- observing library changes
- requesting iCloud downloads on demand

### 11.3 Write model (v1)

The **only** Photos mutation in v1 is asset deletion. This happens **only after**:

1. User approval (via archive queue)
2. Successful iCloud download (if required)
3. Successful export
4. Successful verification
5. Archive record written

### 11.4 Future write model

Preserve a general Photos mutation layer architecturally. Album creation and similar features may be added later but are not required for v1.

## 12. Main workflows

### 12.1 First launch / onboarding
1. Request full Photos library access
2. Let user choose archive destination root (store as security-scoped bookmark)
3. Configure basic archive rules
4. Run initial indexing pass
5. Make the app usable as early as possible while analysis continues

### 12.2 Initial indexing
1. Read basic asset metadata from PhotoKit
2. Insert lightweight index rows via GRDB
3. Request/cache thumbnails
4. Run simple classifiers
5. Queue deeper analysis optionally

### 12.3 Incremental sync
Use PhotoKit change tracking to detect new, removed, and changed assets. Invalidate stale analysis as needed. Do not rescan the full library on every launch.

### 12.4 Review workflow

User selects a sidebar category. Main area shows a flat grid, grouped comparison, or context view. User marks images:

- **Keep in Library**
- **Archive from Library**
- **Review Later**

**Marking behaviour:** pressing "Archive from Library" commits the asset to the archive queue immediately with no confirmation dialog. The archive queue view is the primary safety net — it must be easy to reach and easy to edit before the export job fires.

### 12.5 iCloud download workflow

1. Check `hasLocalOriginal` for each archive candidate
2. For non-local assets, request download via PhotoKit
3. Auto-retry on failure: 3 attempts with exponential backoff
4. After retry exhaustion, set `iCloudDownloadState` to `failed`, skip from current batch, surface for manual retry
5. An asset must not proceed to export until `iCloudDownloadState` is `complete` or `notRequired`

### 12.6 Archive workflow

1. User reviews and confirms archive queue
2. App creates archive job
3. App downloads any non-local originals (12.5)
4. App launches export via bundled `osxphotos`
5. App verifies expected outputs exist (file count, file existence, archive record written)
6. Only then may app delete assets from Photos
7. App records completion state

**Edited photos:** both original and edited versions are exported. Two AssetResource rows per edited asset.

### 12.7 Archive file naming

On filename collision at the destination path, append a numeric suffix before the extension: `IMG_1234_2.jpg`, `IMG_1234_3.jpg`. The archive record stores the actual written path.

### 12.8 Archive root migration

If the user changes the archive root after items have already been archived:

1. App detects existing ArchiveRecords pointing to old root
2. App presents a migration sheet: move archives to new root, or leave in place
3. If user chooses to move, app creates an `archiveRootMigration` job
4. Job moves files, updates ArchiveRecord paths, verifies new locations
5. Old root is not deleted automatically
6. Until migration is complete or explicitly declined, surface a clear indicator that the archive is split

### 12.9 Delete workflow

Deletion is a transaction pipeline:
- Candidate list is frozen at execution time
- Archive verification must already be complete
- Failed partial batches are visible and recoverable
- In-flight delete sets are immutable — UI selection changes do not affect them

### 12.10 Restore workflow

Not required for MVP. Architecture should support it later: browse archived items, reveal archive paths, optionally reimport into Photos.

## 13. Preview strategy

- **Grid:** thumbnail only — never trigger iCloud downloads from browsing
- **Inspector (asset is local):** thumbnail shown immediately; full-resolution image auto-loads in background and swaps in when ready
- **Inspector (asset is cloud-only):** thumbnail shown; full-resolution does not auto-load — user must explicitly trigger download
- **Quick Look:** `QLPreviewPanel` for on-demand full preview

This keeps the grid fast on large libraries and avoids unintentional iCloud data usage.

## 14. Explanation snippets

Contextual explanation snippets (e.g. "Similar to 4 photos taken within 2 minutes; keep this one") are generated as follows:

- **Where Foundation Models is available (Apple silicon, supported OS):** on-device language model generates natural-language snippets from structured analysis fields
- **Elsewhere:** heuristic fallback — strings assembled programmatically from structured analysis fields (duplicate cluster size, time delta, quality score, context role, etc.)

Snippets are stored in `Analysis.explanationSnippet`. They are display strings only — no decisions are made from them. The underlying structured fields drive all logic.

The explanation layer is a first-class UI problem. Snippets must be readable in grid, group, and context modes without cluttering the layout. Where and how they appear needs explicit design attention.

## 15. Logging and diagnostics

- Structured log file written to Application Support
- Log entries include timestamp, level, subsystem, job ID where relevant, and message
- Log is viewable in a Tasks/Log pane within the app
- Use `os_log` for system-level integration in addition to the structured file log
- Log file should rotate to avoid unbounded growth

## 16. Media type support (v1)

v1 supports all five primary media types.

| Type | PHAsset model | Archive resources |
|---|---|---|
| Still photo (unedited) | Single asset | 1 file |
| Still photo (edited) | Single asset | 2 files: original + edited |
| Video | Single asset | 1 or 2 files |
| Live Photo | Single asset | 2 files: JPEG + MOV |
| RAW+JPEG pair | Single asset | 2 files: RAW + JPEG |
| Burst | One PHAsset per member | 1 file per member |

The UI unit is always the PHAsset. AssetResource handles the one-to-many mapping for export.

## 17. Context model

### 17.1 Category-first views
Screenshots, Duplicates, Likely Bad Photos, Archive Ready. Efficient cleanup.

### 17.2 Context-first views
Day, Event, Trip, Album, Auto-generated cluster, Miscellaneous day cluster. Preserve narrative meaning.

### 17.3 Design rule
Recommendations should be contextual when context exists. Examples:
- "Similar to 4 photos taken within 2 minutes; keep this one"
- "Only candid from this day; worth keeping"
- "Screenshot inside trip cluster; likely no story value"
- "Weak alternate within sequence"

## 18. UI spec

### 18.1 Philosophy
Simple native macOS photo-app frame. Minimal custom UI. Reuse Ledger shell. Originality lives in workflow, not chrome. The explanation layer is a first-class design problem even though the visual surface stays minimal.

### 18.2 Main window
Standard three-pane AppKit window: left sidebar, centre content browser, right inspector, standard toolbar.

### 18.3 Sidebar sections

**Library:** All Photos, Recents, Favourites

**Review:** Screenshots, Duplicates, Near-Duplicates, Likely Bad Photos, Review Later

**Story:** Trips & Events, Daily Life, Strong Keepers, Miscellaneous Days

**Archive:** Ready to Archive, Archived Recently, Export Failures

**Tasks:** Indexing, Analysis, Export Jobs, Log

### 18.4 Centre content modes

**Grid mode** — screenshots, clutter queues, all photos, archive queues

**Group mode** — duplicate sets, burst review, best-in-set decisions

**Context mode** — trip/day/event review, archive suggestions in sequence

One centre pane, swap presentation. Do not build separate app shells per mode.

### 18.5 Archive queue view

The archive queue is the last human checkpoint before export fires. It must be:
- easy to reach from any review context
- clearly distinct from review queues (post-decision, pre-action)
- editable: users can remove individual items before triggering export
- informative: show iCloud download state, estimated export size, flagged items

This is the primary safety net given single-press marking. It deserves explicit design work in v1.

### 18.6 Inspector

Show: larger preview, date/time/location/metadata, recommendation state, explanation snippet, archive status, iCloud availability state.

Actions: Keep in Library, Archive from Library, Review Later, Open in Photos, Reveal in Archive.

Preview behaviour: see section 13.

### 18.7 Toolbar

Sidebar toggle, view mode control, search field, Keep, Archive, Open in Photos, progress/task indicator.

## 19. Suggested AppKit implementation

- `NSWindowController`
- `NSSplitViewController`
- Source-list sidebar via `NSOutlineView`
- Centre browser via `NSCollectionView`
- Inspector controller
- `NSSearchField`
- `NSToolbar`
- `QLPreviewPanel`

## 20. Module breakdown

### 20.1 App shell
`AppCoordinator`, `MainWindowController`, `MainSplitViewController`, `SidebarController`, `ContentController`, `InspectorController`

### 20.2 Photos layer
`PhotosLibraryService`, `PhotosFetchController`, `PhotosThumbnailService`, `PhotosChangeTracker`, `PhotosMutationController`, `iCloudDownloadService`

### 20.3 Index/data layer
`DatabaseManager` (GRDB), `AssetRepository`, `CollectionRepository`, `ArchiveRepository`, `JobRepository`

### 20.4 Analysis layer
`AnalysisCoordinator`, `ScreenshotClassifier`, `DuplicateClusterer`, `ContextClusterer`, `QualityScorer`, `StoryScorer`, `OCRService`, `ExplanationGenerator`

### 20.5 Archive layer
`ArchiveCoordinator`, `OsxPhotosRunner`, `ArchiveVerifier`, `ArchivePathPlanner`, `ArchiveRootMigrator`, `NamingCollisionResolver`

### 20.6 Task layer
`JobScheduler`, `TaskProgressController`, `RetryPolicy`

### 20.7 Logging
`LogStore` — writes structured entries to Application Support log file and `os_log`

## 21. AI/ML split

### 21.1 Local-first
Use Apple-native frameworks for: OCR, screenshot/document detection, duplicate grouping, clutter classification, local search, cluster summaries.

### 21.2 Heuristics
Much of Librarian's value comes from scoring logic you own: story value, redundant-in-context, only-photo-from-that-period, supports-sequence vs weak alternate, archive confidence.

### 21.3 Explanation generation
Foundation Models where available (Apple silicon, supported OS). Heuristic string assembly as fallback. See section 14.

### 21.4 OpenAI
Optional only. Not required for MVP. Good future candidates: trip story selection, album generation, tie-breaking. Default spend is zero.

## 22. Key technical risks

### 22.1 Asset identity and archive mapping
The mapping between PHAsset → AssetResource(s) → ArchiveRecord → deleted asset must be reliable. AssetResource is a first-class schema table, not an afterthought.

### 22.2 iCloud / Optimize Mac Storage
Four states: metadata available / thumbnail available / original local / export succeeded. An asset is not safely removable until export succeeds. Download-on-demand with retry. See section 12.5.

### 22.3 Thumbnail performance
Request correctly sized thumbnails, cache aggressively, never eagerly load full-size in the grid.

### 22.4 Change tracking and stale analysis
Clear invalidation rules when the Photos library changes outside Librarian.

### 22.5 Deletion safety
Frozen candidate list, verification gate, partial failure handling, immutable in-flight sets.

### 22.6 Bundled toolchain integrity
The bundled osxphotos/exiftool toolchain must be deterministic and self-contained: pinned versions, valid signatures, predictable runtime environment, and explicit launch diagnostics.

### 22.7 Archive model
Policy is locked: export both original and edited for edited assets; suffix on collision; migration job on archive root change; two-folder structure (`Photos/` and `Other/`) with queue-driven routing; deterministic paths within each.

### 22.8 Scope creep
Story/meaning logic must not overcomplicate v1. Trustworthy archive/delete pipeline first.

## 23. Archive/export requirements

### 23.1 Rules
- Files written to user-chosen archive root (security-scoped bookmark)
- Deterministic folder structure
- Archive category represented in path
- Export verified before Photos deletion
- Both original and edited exported for edited assets

### 23.2 Archive routing

The archive root contains two top-level folders: `Photos/` and `Other/`. The distinction reflects the nature of the content, not just the queue it came from.

**Routing rules:**

| Source queue | Archive path |
|---|---|
| Screenshots | `Other/Screenshots/YYYY/MM` |
| Likely Bad Photos | `Other/Low Priority/YYYY/MM` |
| Review Later | `Other/Review Later/YYYY/MM` |
| Duplicates / Near-Duplicates | `Photos/YYYY/MM` |
| Context review / story curation | `Photos/YYYY/MM` |
| Manual archive decisions | `Photos/YYYY/MM` |

**Rationale:** Duplicates are real photographs — just redundant ones. They belong in `Photos/` alongside other intentionally archived images. Screenshots, junk, and bad shots are non-photo content kept for safety only; they go to `Other/`. The `Photos/` archive is something the user may want to browse or restore from. `Other/` is a safety net.

`ArchiveRecord` stores the `archiveRoot` (top-level) and `archivePath` (full path including `Photos/` or `Other/` prefix) so the routing is always recoverable from the database.

### 23.3 Verification
Minimum: expected file count matches, destination files exist, archive record written.
Optional later: checksum verification, export manifest, replay/recovery.

## 24. Build order

### Phase 1 — shell and indexing
Adapt Ledger window shell. Add sidebar/content/inspector. Integrate PhotoKit with full-access requirement. Create GRDB schema with migrations. Build initial asset index.

### Phase 2 — basic browsing
Grid browser, thumbnail loading/caching (preview strategy per section 13), selection model, inspector, open in Photos.

### Phase 3 — first review queue
Screenshots only. Get one queue working end-to-end before adding more.

### Phase 4 — archive pipeline
Archive queue view (editable). iCloud download-on-demand with retry. Bundled osxphotos tool runner. Naming collision handling. Export verification. Delete only after success.

### Phase 5 — additional review queues
Duplicates, likely bad photos, review later.

### Phase 6 — context review
Day/event/trip clustering. Suggested removals in context. Hero/supporting/redundant roles.

### Phase 7 — polish
Task/job UI. Log pane. Better explanations. Archive browser. Archive root migration UI. Restore groundwork. Optional richer local AI.

## 25. v1 cut list

- OpenAI integration
- Full meaningfulness engine
- Story coverage scoring
- Photos album creation
- Restore UI
- Deep media-type edge cases beyond what is necessary
- Extensive custom UI

v1 proves: fast browsing, one or two trustworthy queues, safe archive pipeline with correct multi-file handling, safe delete pipeline, stable local state.

## 26. Definition of success

Librarian succeeds if a user can safely:
- browse a large Apple Photos library in a native-feeling Mac app
- remove screenshots from the active library
- collapse duplicate/near-duplicate sets
- reduce random clutter
- review photos in context of a day/trip/event
- keep a more meaningful active Photos library
- archive removed items in an orderly, verified way
- do all of this with little or no cloud cost

## 27. One-sentence brief

**Build a native AppKit macOS companion app called Librarian for direct signed/notarized distribution, reusing Ledger's shell, using PhotoKit for live Apple Photos access (full access required, download-on-demand with retry for iCloud assets), GRDB/SQLite for local indexing and state with sequential migrations, Apple-native ML and Foundation Models for local analysis and explanation generation, and a bundled pinned osxphotos toolchain for verified archival export of both originals and edited versions, with a strict rule that nothing is deleted from Photos until it has been safely archived and verified.**
