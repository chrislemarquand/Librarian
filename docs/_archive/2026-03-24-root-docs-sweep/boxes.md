# Boxes — Developer Reference

This document describes how each box view is populated, what data passes are required, and where to look to tune the classification logic.

---

## Shared concepts

**`asset_active` view** — all box queries run against this view, not the raw `asset` table. It excludes deleted assets (`isDeletedFromPhotos = 1`), non-image media (`mediaType != 1`), and assets currently queued for archiving. Any filtering change that should apply globally belongs in the `asset_active` view definition (migration `v8_photos_only_active_view` and `v5_refine_active_asset_view_filters`).

**Keep decisions** — every box excludes assets the user has kept. Kept assets are recorded in `queue_keep_decision (assetLocalIdentifier, queueKind)`. Each box has its own `queueKind` string (listed below). The LEFT JOIN / IS NULL pattern in each query is the exclusion mechanism.

**Data passes** — some boxes are populated at index time (no extra pass needed); others require the library analysis pass or the Vision analysis pass to have run first.

| Box | Data pass required |
|---|---|
| Screenshots | None — index time |
| Duplicates | Library analysis (fingerprint) + Vision analysis (near-duplicates) |
| Low Quality | Library analysis |
| Documents | Vision analysis (OCR) + optionally library analysis (labels) |
| WhatsApp | None — index time |
| Accidental | Vision analysis (saliency) |

---

## Screenshots

**`queueKind`**: `"screenshots"`

**Classification signal**: `PHAssetMediaSubtype.photoScreenshot`, a flag set by iOS/macOS at capture time and exposed via `PHAsset.mediaSubtypes`.

**Where it's set**: `IndexedAsset.init(from:lastSeenAt:)` in `AssetIndexer.swift`:
```swift
let isScreenshot = subtypes.contains(.photoScreenshot)
```
Written to `asset.isScreenshot` at index time. No analysis pass needed.

**Query** (`fetchScreenshotsForReview`):
```sql
SELECT a.* FROM asset_active a
LEFT JOIN queue_keep_decision qk
    ON qk.assetLocalIdentifier = a.localIdentifier AND qk.queueKind = 'screenshots'
WHERE a.isScreenshot = 1
  AND qk.assetLocalIdentifier IS NULL
ORDER BY a.creationDate DESC
```

**Tuning notes**:
- The `photoScreenshot` flag is set by the OS and cannot be changed in Librarian — classification is entirely PhotoKit's call.
- To exclude specific screenshot types (e.g. only show UI screenshots, not game captures), you would need a secondary signal such as OCR content or aspect ratio, added as an extra WHERE clause.

---

## Duplicates

**`queueKind`**: `"duplicates"`

**Classification signals** (union — either signal qualifies an asset):

1. **Perceptual fingerprint** (`asset.fingerprint`): an exact-duplicate hash produced by osxphotos during the library analysis pass. Two assets with the same non-null fingerprint are considered exact duplicates.

2. **Near-duplicate cluster** (`asset.nearDuplicateClusterID`): a UUID assigned by the Vision analysis stage using `VNGenerateImageFeaturePrintRequest`. Assets whose feature prints fall within a similarity threshold are grouped into the same cluster. Cluster assignment is computed in `buildNearDuplicateAssignments()` in `LibraryAnalyser.swift`.

**Where values are set**:
- `fingerprint`: library analysis pass → `LibraryAnalyser` → `upsertAnalysisData()`
- `nearDuplicateClusterID`: Vision analysis stage → `assignNearDuplicateClusters()`

**Query** (`fetchDuplicatesForGrid`): shows an asset if its fingerprint or clusterID appears on more than one non-deleted asset in the library, after excluding kept items.

**Tuning notes**:
- The near-duplicate similarity threshold is inside `buildNearDuplicateAssignments()` in `LibraryAnalyser.swift` — look for the `VNFeaturePrintObservation.computeDistance` comparison.
- Assets with no fingerprint and no clusterID (i.e. analysis hasn't run yet) are silently absent from the box — the box will be empty until at least one analysis pass completes.
- The query uses subqueries (`HAVING COUNT(*) > 1`) which can be slow on very large libraries. If performance becomes an issue, consider materialising cluster membership into a separate table.

---

## Low Quality

**`queueKind`**: `"lowQuality"`

**Classification signal**: `asset.overallScore < 0.3`, combined with `isFavorite = 0` (favourites are always excluded regardless of score).

`overallScore` is a `DOUBLE` (nullable) produced by the library analysis pass via osxphotos. It ranges from 0.0 to 1.0. The column is NULL until analysis has run.

**Where it's set**: library analysis pass → `LibraryAnalyser` → `upsertAnalysisData()` → writes `overallScore` per asset.

**Query** (`fetchLowQualityForGrid`):
```sql
WHERE a.overallScore IS NOT NULL
  AND a.overallScore < 0.3
  AND a.isFavorite = 0
  AND qk.assetLocalIdentifier IS NULL
```

**Tuning notes**:
- The threshold `0.3` is hardcoded in two places: `fetchLowQualityForGrid` and `countForSidebarKind(.lowQuality)` in `AssetRepository.swift`. Change both together.
- The box is hidden in the UI until analysis has run (the spec decision is that it should not appear as an empty box before the first analysis pass).
- Score is from osxphotos' aesthetic model — it reflects technical quality (blur, exposure, noise) but not semantic importance. Favourites are excluded as a hard override regardless of score.

---

## Documents

**`queueKind`**: `"receiptsAndDocuments"`

**Classification signals** (all must combine as described):

An asset qualifies if **all** of the following are true:
1. `visionOcrText` is not null and its trimmed length is ≥ 120 characters
2. At least one of:
   - `labelsJSON` contains the string `"document"` (from the osxphotos label classifier)
   - The OCR text (lowercased) contains one of: `invoice`, `statement`, `policy`, `account`, `contract`, `application`, `certificate`

**Where values are set**:
- `visionOcrText`: Vision analysis stage → `VNRecognizeTextRequest` → `upsertVisionAnalysisData()` in `AssetRepository.swift`
- `labelsJSON`: library analysis pass → osxphotos label classifier → `upsertAnalysisData()`

**Tuning notes**:
- The minimum OCR character count (`120`) is the constant `minimumDocumentOCRCharacters` at the top of `AssetRepository`. Lowering it will increase recall but add more false positives (e.g. photos with short text overlays).
- The keyword list is in `fetchReceiptsAndDocumentsForGrid` and duplicated in `countForSidebarKind(.receiptsAndDocuments)`. Both must be kept in sync when adding or removing keywords.
- `labelsJSON LIKE '%"document"%'` matches the exact JSON string `"document"` as a label value. The surrounding quotes are intentional — they prevent a label like `"documentary"` from matching.
- Assets without OCR text (Vision analysis not yet run, or no detected text) are always absent from this box.

---

## WhatsApp

**`queueKind`**: `"whatsapp"`

**Classification signals** (union — either signal sets `isWhatsApp = 1`):

1. **Filename prefix** (checked at index time): `PHAssetResource.originalFilename` starts with `"WhatsApp Image "` or `"WhatsApp Video "`. Matches the naming convention used by WhatsApp when saving media to the camera roll.

2. **Album membership** (checked after each index run): the asset is a member of a `PHAssetCollection` whose `localizedTitle` is exactly `"WhatsApp"`. WhatsApp creates this album automatically when "Save to Photos" is enabled.

**Where it's set**:
- Filename check: `IndexedAsset.init(from:lastSeenAt:)` in `AssetIndexer.swift`, via `AssetIndexer.isWhatsAppFilename(_:)`.
- Album scan: end of `AssetIndexer.run()`, bulk UPDATE via `AssetRepository.markWhatsAppFromAlbum(identifiers:)`.

Both paths write to `asset.isWhatsApp (BOOLEAN)`. The column defaults to `false` and is never reset to `false` once set — re-indexing will only ever add new matches, not remove existing ones. (Assets deleted from Photos are handled by `isDeletedFromPhotos`, not by clearing this flag.)

**Query** (`fetchWhatsAppForGrid`):
```sql
SELECT a.* FROM asset_active a
LEFT JOIN queue_keep_decision qk
    ON qk.assetLocalIdentifier = a.localIdentifier AND qk.queueKind = 'whatsapp'
WHERE a.isWhatsApp = 1
  AND qk.assetLocalIdentifier IS NULL
ORDER BY a.creationDate DESC
```

**Tuning notes**:
- `isWhatsAppFilename(_:)` in `AssetIndexer.swift` is a pure static function — easy to unit test and safe to extend. WhatsApp's filename convention has been stable but if it changes, this is the only place to update.
- The album name `"WhatsApp"` is matched as an exact string. If WhatsApp ever localises this album name (unlikely for a third-party app), the predicate in `AssetIndexer.run()` would need updating.
- The `asset_active` view excludes videos (`mediaType != 1`), so WhatsApp videos will not currently appear even if classified. If video support is added in a future version, this exclusion is in migration `v8_photos_only_active_view`.
- Unlike the other boxes, WhatsApp classification is purely structural (filename / album) — it does not depend on any analysis pass.

---

## Accidental

**`queueKind`**: `"accidental"`

**Classification signal**: `visionSaliencyScore < 0.05`, combined with `isFavorite = 0`.

`visionSaliencyScore` is a `DOUBLE` (nullable) produced by `VNGenerateAttentionBasedSaliencyImageRequest` during the Vision analysis stage. It ranges from 0.0 to 1.0, where higher means a more clearly defined subject with high visual attention. Very low scores indicate frames with no discernible subject — pocket fires, floor shots, accidental taps.

**Where it's set**: Vision analysis stage → `analyseVisionCandidate()` in `LibraryAnalyser.swift` → `upsertVisionAnalysisData()` in `AssetRepository.swift`.

**Query** (`fetchAccidentalForGrid`):
```sql
WHERE a.visionSaliencyScore IS NOT NULL
  AND a.visionSaliencyScore < 0.05
  AND a.isFavorite = 0
  AND qk.assetLocalIdentifier IS NULL
```

**Tuning notes**:
- The threshold `0.05` is intentionally conservative. `VNGenerateAttentionBasedSaliencyImageRequest` can return low scores for intentionally abstract or minimalist shots (plain sky, flat lay, dark room), so the threshold is set low to reduce false positives. If in practice the box misses obvious accidental shots, try raising to `0.08`–`0.10`. Both `fetchAccidentalForGrid` and `countForSidebarKind(.accidental)` in `AssetRepository.swift` must be updated together.
- Favourites are excluded as a hard override — the same policy as Low Quality.
- Assets with a NULL saliency score (Vision analysis not yet run) are never shown. The box will be empty until the Vision pass has run.
- Consider combining with `overallScore < 0.3` as a secondary filter if false positives remain an issue after threshold tuning.
