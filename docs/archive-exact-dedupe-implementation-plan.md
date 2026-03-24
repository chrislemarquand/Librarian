# Archive Exact Dedupe Implementation Plan

## Goal

Ensure Archive keeps a single copy of exact-content duplicates across all ingest paths, with silent auto-resolution:

- Exact SHA-256 match: keep one canonical file.
- Indeterminate/failed verification: keep both.
- No user prompts.

## Ticket Breakdown

### Phase 1: Foundations

- [x] `DB-1` Add `archive_file_fingerprint` table for canonical dedupe index.
- [x] `DB-2` Add `archive_duplicate_event` table for audit trail.
- [x] `DB-3` Add unique partial index to enforce one canonical row per SHA-256.
- [x] `REPO-1` Add repository APIs for fingerprint upsert, canonical claim, and duplicate event logging.
- [x] `MODEL-1` Add `ArchiveDedupeService` scaffold for hashing, canonical selection, and event emission.

### Phase 2: Integrate Path A (Add Photos to Archive)

- [x] `PATHA-1` Preflight against archive content in addition to source and Photos Library checks.
- [x] `PATHA-2` Exclude archive-exact duplicates from copy candidates.
- [ ] `PATHA-3` Write duplicate events for suppressed candidates.
- [x] `PATHA-4` Update import summary/status copy to include Archive skip counts.

### Phase 3: Integrate Path B (Review/Organise Existing Archive)

- [x] `PATHB-1` Run exact archive dedupe before organisation move stage.
- [x] `PATHB-2` Suppress exact duplicates to canonical.
- [x] `PATHB-3` Route indeterminate files to review area.
- [x] `PATHB-4` Keep existing Photos Library duplicate handling alongside archive dedupe.

### Phase 4: Integrate Set Aside Export

- [x] `EXPORT-1` Post-export reconcile pass over newly exported files.
- [x] `EXPORT-2` Suppress any exact duplicates already present in Archive.
- [x] `EXPORT-3` Log events and update status text/notification summary.

### Phase 5: Finder/Manual Additions

- [x] `WATCH-1` Add archive monitor queue for new/changed files (timer-driven polling).
- [x] `WATCH-2` Run dedupe worker over newly observed paths.
- [x] `WATCH-3` Ensure monitor pipeline is debounced/idempotent and race-guarded.

### Phase 6: UX + Observability

- [ ] `UX-1` Show counts in settings/notice bar: duplicates suppressed, needs review.
- [ ] `UX-2` Keep copy prompt-free and deterministic.
- [ ] `OBS-1` Add debug logs/metrics for dedupe throughput and error reasons.

## Acceptance Criteria

- [ ] Same photo entering via any path results in one canonical archive file.
- [ ] Hash/read failures never remove files automatically.
- [ ] Deterministic canonical selection is stable across reruns.
- [ ] Duplicate event log aligns with on-disk outcomes.
