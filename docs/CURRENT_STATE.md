# Current State

Date: 2026-03-24

This document is the factual implementation snapshot of Librarian today.

## Product/Flow State

- App shell: AppKit three-pane desktop UI with SharedUI infrastructure.
- Source of truth: PhotoKit for live library reads and mutations.
- Archive model: external folder with `.librarian/archive.json` control plane and canonical `Archive/YYYY/MM/DD` layout.
- v1 media scope: photos only.

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
- Analysis query and export now pass explicit `--library` path when resolvable.

## Dependency Mode

- SharedUI is currently local-path lockstep (`.package(path: "../SharedUI")`).
- Release tagging/pinning workflow is explicit and separate from normal development mode.

## Testing/Quality State

- Automated tests are currently concentrated in `Tests/LibrarianTests/LibrarianTests.swift`.
- Core unit/integration-style checks pass in current branch.
- End-to-end manual trust-boundary flow validation remains a required pre-ship step.
