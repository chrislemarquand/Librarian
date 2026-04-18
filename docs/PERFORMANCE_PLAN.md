# Performance Improvement Plan

## Background

An audit of Librarian identified four areas for improvement: main-thread database blocking, expensive badge count queries, a large app bundle, and missing materialised flags for computed queue membership. This document is the execution plan.

---

## Phase 1 — Eliminate the sync N+1 badge path
**1 commit**

Remove the sync `buildSidebarItemsWithBadges(model:) -> [SidebarItem]` overload entirely. Every call site that uses it (`modelStateChanged`, `refreshWindowSubtitle`, the init-time build) gets routed through the existing async overload, which fetches all counts in a single database transaction. The `sidebarBadgeTask` cancellation pattern already in place handles the async scheduling correctly.

Also fix `refreshWindowSubtitle` — it calls `countForSidebarKind` synchronously on the main thread for the subtitle count. That becomes a second async path or (simpler) reuses the count already fetched during the badge refresh.

---

## Phase 2 — Materialise `isDocument` flag
**2 commits**

The receipts/documents queue runs 7 `LOWER(visionOcrText) LIKE '%keyword%'` conditions plus a `labelsJSON LIKE` check on every badge count refresh. No index can help `LIKE '%…%'` wildcard searches.

**Commit 1 — Migration:** Add `isDocument INTEGER NOT NULL DEFAULT 0` column to `asset` and an index on it. Next migration number: `v22`.

**Commit 2 — Pipeline + query:** Populate `isDocument` during the analysis pass (same place `visionOcrText` and `labelsJSON` are written — evaluate the existing conditions there and set the flag). Update both the count query and the grid fetch query to use `WHERE isDocument = 1` instead of the LIKE chain.

---

## Phase 3 — Materialise duplicate group membership
**2 commits**

The duplicates badge count runs a correlated subquery with `GROUP BY nearDuplicateClusterID HAVING COUNT(*) > 1` against the full asset table on every refresh. This is the most expensive single query.

**Commit 1 — Migration:** Add `nearDuplicateGroupSize INTEGER NOT NULL DEFAULT 0` column to `asset`. Next migration: `v23`. The column stores the size of the cluster this asset belongs to (0 = not in any cluster, 1 = singleton — effectively not a duplicate, ≥2 = true duplicate).

**Commit 2 — Clustering update + query:** When `storeDuplicateClusters` writes cluster IDs, also write the group size for each member. Update the count query and grid fetch to `WHERE nearDuplicateGroupSize >= 2` — a simple indexed lookup replacing the subquery.

---

## Phase 4 — ExifTool bundle audit
**1–2 commits**

Three directories are candidates for removal:
- `lib/Test/` (84 KB) — test harness modules, never needed at runtime
- `lib/Capture/` (32 KB) — Perl output capture, development tooling only
- `lib/FFI/` (24 KB) — foreign function interface, not used by ExifTool's image parsing path

`lib/Image/` (19 MB) and `lib/darwin-thread-multi-2level/` (18 MB) need careful testing — these are the core image parsing and Perl runtime modules respectively. `lib/Alien/` (720 KB) and `lib/Mozilla/` (224 KB) may also be prunable but need runtime verification first.

**Commit 1:** Remove the clearly safe candidates (Test, Capture, FFI) and run a full export smoke test.
**Commit 2:** After testing confirms nothing breaks, remove any additional directories confirmed unused.

---

## Summary

| Phase | Commits | Impact | Risk |
|---|---|---|---|
| 1 — Async badge path | 1 | Eliminates main-thread blocking on every sidebar interaction | Low — async path already exists and is tested |
| 2 — isDocument flag | 2 | Replaces 8-condition LIKE chain with indexed lookup | Low — additive migration, flag populated at analysis time |
| 3 — Duplicate group size | 2 | Replaces GROUP BY subquery with indexed integer check | Medium — clustering write path needs updating |
| 4 — Bundle audit | 1–2 | Reduces app size by potentially 1–3 MB | Low-medium — requires smoke testing after each removal |
