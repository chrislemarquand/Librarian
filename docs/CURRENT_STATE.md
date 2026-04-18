# Current State

Date: 2026-04-18

This document is the factual implementation snapshot of Librarian today.

## Product/Flow State

- App shell: AppKit three-pane desktop UI with SharedUI infrastructure.
- Source of truth: PhotoKit for live library reads and mutations.
- Archive model: external folder with `.librarian/archive.json` control plane and canonical `Archive/YYYY/MM/DD` layout.
- v1 media scope: photos only.

## Queues

- All Photos, Recents, Favourites, Screenshots, Duplicates, Low Quality, Receipts & Documents, WhatsApp, Archived.
- **Not in Album**: photos belonging to no user album in Photos. Shown between Low Quality and Screenshots. Album membership is rescanned from PhotoKit at every launch (background, utility priority) so the queue stays current without a full re-index.
- Set Aside for Archive: staging queue before export.

## Analysis and Indexing

- Indexing runs from PhotoKit and supports manual catalogue updates.
- Analysis pipeline includes:
  - osxphotos query ingestion,
  - Vision OCR/feature print pass,
  - queue-driving fields persisted to GRDB.
- Analysis can resume automatically after interruption when pending work exists and runtime conditions are suitable.

## Archive and Dedupe

- Archive send/import/organisation flows are implemented with progress/status surfaces.
- Exact archive dedupe foundations exist (fingerprint/event tables and integration paths).
- Duplicates queue is driven by `nearDuplicateClusterID` clustering (not legacy fingerprint OR logic).
- Current near-duplicate tuning is stricter than early builds (time window, distance threshold, tie tolerance, dimension gates).

## Multi-Library Behaviour

- Current behaviour is a launch/runtime library path change check with informational alerting.
- There is no strict write gate tied to fingerprinted library binding in current code.

## osxphotos Runtime Boundary

- osxphotos is bundled and invoked only through `OsxPhotosRunner`.
- No external fallback execution path is used.
- Analysis query and export pass explicit `--library` path when resolvable.

## Release Pipeline

- CI (GitHub Actions) builds, signs, notarises, packages DMG, generates signed appcast, and attaches artifacts to a GitHub release on push of a version tag.
- Version and build number are derived from the tag (`vMAJOR.MINOR.PATCH` → `MAJOR×10000 + MINOR×100 + PATCH`), avoiding shallow-clone issues.
- Sparkle auto-update delivery is proven end-to-end as of v0.2.

## Dependency Mode

- SharedUI is currently local-path lockstep (`.package(path: "../SharedUI")`).
- Release tagging/pinning workflow is explicit and separate from normal development mode.

## Testing/Quality State

- Automated tests are organised by domain under `Tests/LibrarianTests/` (archive boundary/config/import, osxphotos runner, app model state, trust-boundary flows).
- Core unit/integration-style checks pass in current branch.
- A dedicated trust-boundary smoke command exists: `./scripts/release/trust_boundary_smoke.sh`.
- End-to-end manual Photos-library trust-boundary flow validation remains the sole required pre-v1 step.
