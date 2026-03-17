# Roadmap

## Near Term

### 1) Export Progress Sheet (Ledger-style)
- Add an export sheet visually aligned with Ledger's import sheet.
- Keep SwiftUI content fully wrapped in AppKit presentation.
- Include:
  - header + status line,
  - progress indicator,
  - processed counts,
  - completion/partial-failure states,
  - actions (`Done`, `View Log`, optional `Cancel` if cancellation is safely wired).

### 2) Archive UX Hardening
- Improve per-item failure visibility in UI (not just logs), especially in Set Aside view.
- Add explicit retry action for failed archive items.
- Show clearer end-state summaries for partial success (exported vs failed vs deleted counts).

### 3) Inspector Enhancements
- Continue visual alignment with Ledger where appropriate.
- Ensure archive metadata/error fields remain clear and non-editable.
- Add compact formatting for long identifiers/paths while preserving full-value access.

### 4) Settings Expansion
- Add user-configurable export template settings (future-safe for folder/file naming rules).
- Persist and expose export-related toggles that currently live in code defaults.

## Medium Term

### 5) Smart Views + Archive-Oriented Views
- Expand smart/sidebar views using query model rather than one-off hardcoded filters.
- Ensure queued-for-archive visibility rules remain central and reusable across future views.

### 6) Incremental Indexing and Data Integrity
- Continue reducing full rebuild scenarios.
- Add explicit integrity/reconciliation tools and diagnostics for edge cases (recovered photos, missing assets, external changes).

### 7) Test Coverage
- Add focused tests for:
  - archive state machine transitions,
  - mixed export outcomes,
  - deletion reconciliation,
  - photo library change deltas.

## Later

### 8) Archive Pipeline Extensions
- Optional export profiles/presets.
- Better post-export auditing and reporting UI.
- Optional automation hooks for downstream archive workflows.

