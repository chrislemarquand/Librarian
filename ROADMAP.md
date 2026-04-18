# Roadmap

Last updated: 2026-04-18

This is the single planning document for Librarian. It replaces `docs/SHIPPING_PLAN.md` and earlier roadmap variants.

## Current State

- Core archive/export safety boundary is implemented and stable in day-to-day use.
- Import and archive-organisation flows are unified around the archive import sheet.
- Multi-library handling is a simple launch-time/current-path change check with an informational prompt.
- osxphotos is bundled and executed through a dedicated runner boundary for analysis/export.
- Duplicates queue uses Vision near-duplicate clustering only (not legacy fingerprint OR logic).
- "Not in Album" queue is implemented; album membership is rescanned from PhotoKit on each launch.
- Release pipeline is proven end-to-end: CI builds, signs, notarises, generates appcast, and delivers via Sparkle. v0.2 shipped successfully.

## Completed Blocks

### Block 1: Export correctness

- Fixed export defaults.
- Added stale export-state recovery at launch.
- Removed alternate archive layout mode; canonical layout is `YYYY/MM/DD`.

### Block 2: Safety gates simplification

- Archive relink detection and availability handling are in place.
- Removed complex library fingerprint/coupling gate system; replaced with simple library path change warning.

### Block 3: Discoverability and notice bars

- Analysis-dependent placeholder states and actions are in place.
- SharedUI NoticeBar integrated for archive organisation and analysis-in-progress messaging.
- Analysis status copy and settings wording updated to current product language.

### Block 4: Pre-ship cleanup

- Archive services moved out of `ContentController` into model services.
- Redundant indexing sidebar destination removed.

## Remaining Before v1 Ship

1. Full manual flow validation pass on primary Photos library:
   - index → analyse → review queues → set aside → export → verify Archive → delete from Photos.
2. ~~Release dry run using release scripts and checklist~~ — done: v0.2 proven end-to-end via CI and Sparkle.

## Out of Scope for v1

- Restore workflow from Archive back to Photos.
- Album creation in Photos.
- Story/meaningfulness engine.
- OpenAI/cloud intelligence features.
- App Sandbox/App Store distribution track.
