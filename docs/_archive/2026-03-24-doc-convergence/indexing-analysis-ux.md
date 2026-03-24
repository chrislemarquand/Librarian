# Indexing & Analysis UX Plan

Last updated: 2026-03-21

## Context

Indexing and analysis are two distinct passes. Indexing (PhotoKit metadata scan) runs automatically on first launch and background-syncs on library changes. Analysis (osxphotos quality scores + Vision pass) is slower, user-initiated, and unlocks score-dependent features like the Low Quality queue.

The current implementation has three correctness gaps and one discoverability gap relative to the spec.

---

## Current State

### Indexing

- Auto-starts on first launch when the index is empty ✓
- Background-syncs silently on library changes ✓
- Progress shown in window subtitle and toolbar spinner ✓
- Manual rebuild available in Settings ✓
- `.indexing` sidebar item exists as a selectable destination — purpose unclear

### Analysis

- Only trigger is "Analyse Library" button in Settings — completely hidden unless the user goes looking for it ✗
- No prompt offered after initial index completes (spec requires one) ✗
- Low Quality sidebar item always visible even before analysis has run (spec requires it to be hidden) ✗
- No last-analysed date visible anywhere ✗
- No staleness signal if the library has grown significantly since last analysis ✗

Net effect: most users will never discover analysis exists, and Low Quality will show "No Low Quality Photos" indefinitely, which looks like a broken feature.

---

## Proposed Changes

### 1 — Hide Low Quality until analysis has run [Correctness fix]

**Spec requirement:** "Hidden (not greyed out) until analysis has been run at least once."

Low Quality scores only exist post-analysis. Showing the item before that is actively misleading.

**Behaviour:**
- AppModel exposes `lastAnalysedAt: Date?` (already stored in GRDB; needs publishing)
- `SidebarItem.allItems` becomes computed: Low Quality is excluded when `lastAnalysedAt == nil`
- After analysis completes, the sidebar refreshes and Low Quality appears permanently
- Once visible, it stays — even if the result set happens to be empty on a given day

**Effort:** Small. Boolean gate on a fact the model already knows.

---

### 2 — Post-index analysis prompt (non-modal info bar) [Discoverability]

**Spec requirement:** "Offered (non-modal prompt) after initial index completes; re-runnable from Settings. Never a blocking setup step."

After the initial index completes, show a dismissable info bar in the content pane. Not a sheet, not an alert.

**Trigger condition:** initial index just completed AND `lastAnalysedAt == nil`

**Copy:**
> **Library indexed.** Run Library Analysis to unlock quality scores, near-duplicate detection, and the Low Quality queue.
> [Run Analysis]  [Not Now]

**Behaviour:**
- "Run Analysis" calls `model.runLibraryAnalysis()` and dismisses the bar
- "Not Now" dismisses and sets a `UserDefaults` flag so it doesn't reappear on relaunch
- Bar is not shown on subsequent launches once dismissed or after analysis has run at least once
- Settings → Library remains the persistent re-run control

**Implementation:** A thin `InfoBarViewController` that ContentController or MainSplitViewController can insert/remove at the top of the content area. Driven by model state.

---

### 3 — Last-analysed date in Settings [Transparency]

**Spec requirement:** "Display 'last analysed' date in Settings."

Currently Settings shows "Analyse Library" with no date context.

**Change:** Add a formatted date line next to the Analyse button: "Last analysed: [date]" or "Never analysed" if `lastAnalysedAt == nil`. No change to triggering logic.

**Effort:** Trivial.

---

### 4 — Remove the `.indexing` sidebar item [Cleanup]

The `.indexing` sidebar item exists in code but its role is redundant — the window subtitle and toolbar spinner already communicate indexing state. As a selectable sidebar destination it just shows an empty placeholder, which is confusing.

**Change:** Remove `.indexing` from `SidebarItem.Kind` and all switch cases. Audit for any code paths that depend on it.

**Effort:** Small, but requires touching AssetRepository, ContentController, ToolbarDelegate, and MainSplitViewController switch cases. Low risk.

---

### 5 — Staleness nudge [Deferred]

If `lastAnalysedAt != nil` and the asset count has grown significantly since last analysis, a passive indicator could prompt re-analysis.

**Decision:** Skip for v1. The last-analysed date in Settings is enough. No nagging.

---

## Priority & Sequencing

| # | Change | Priority | Reason |
|---|---|---|---|
| 1 | Hide Low Quality until analysis run | High — do in v1.0 | Spec-mandated correctness; currently misleading |
| 2 | Post-index analysis prompt | High — do in v1.0 | Required for analysis to be discoverable at all |
| 3 | Last-analysed date in Settings | Medium — v1.1 | Transparency; trivial once analysis prompt exists |
| 4 | Remove `.indexing` sidebar item | Low — v1.1 | Cleanup; no user-visible correctness impact |
| 5 | Staleness nudge | Skip v1 | Low value; risks nagging |
