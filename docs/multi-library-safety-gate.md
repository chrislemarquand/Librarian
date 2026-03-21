# Multi-Library Safety Gate Spec

## Goal

Prevent incorrect dedupe/import behavior when the active macOS Photos system library changes and no longer matches the library an archive was created for.

This spec adds a **library binding safety gate** to the existing archive control plane (`Archive/.librarian/archive.json`) without converting archives into bundles.

## Non-Goals

- No automatic rewrite, move, or deletion of existing archive files during rebind.
- No hard dependency on a single method of Photos library identity (we support fallback fingerprinting).
- No change to the user-visible archive folder structure (`Archive/YYYY/MM/DD`, etc.).

## Current Baseline

- Archive identity exists in `archive.json` via `archiveID`.
- Import Path A and Path B dedupe against current PhotoKit state.
- User can switch system library externally, which can silently change dedupe semantics.

## Proposed Data Model

Bump `archive.json` schema to v2 and add `photoLibraryBinding`.

```json
{
  "schemaVersion": 2,
  "archiveID": "3EF15843-0F02-4382-B2A2-FB930FED80BC",
  "createdAt": "2026-03-21T12:31:04Z",
  "createdByVersion": "1.0",
  "layoutMode": "YYYY/MM/DD",
  "paths": {
    "reports": "reports",
    "thumbnails": "thumbnails"
  },
  "photoLibraryBinding": {
    "libraryFingerprint": "sha256:...",
    "libraryIDSource": "photosdb-primary-key",
    "libraryPathHint": "/Users/chris/Pictures/Photos Library.photoslibrary",
    "boundAt": "2026-03-21T12:31:04Z",
    "bindingMode": "strict",
    "lastSeenMatchAt": "2026-03-21T12:45:10Z"
  }
}
```

### Field Semantics

- `libraryFingerprint`: stable identifier for the current Photos system library.
- `libraryIDSource`: provenance of fingerprint (for diagnostics and future migrations).
- `libraryPathHint`: non-authoritative display hint for UI text only.
- `boundAt`: when this archive was bound to that library fingerprint.
- `bindingMode`: `"strict"` (default) or `"advisory"` (future/debug).
- `lastSeenMatchAt`: last successful fingerprint match.

## Library Fingerprint Strategy

Use best-available stable identity, with fallback:

1. Preferred: library-internal identifier from supported metadata path.
2. Fallback: canonical URL + creation date + stable file resource values hashed together.

Requirements:

- Deterministic within machine after normal restarts.
- Resilient to display-name changes.
- Fast enough to compute at launch/import-gate time.

## Runtime Behavior

### State Machine

- `unbound`: archive has no `photoLibraryBinding`.
- `bound-match`: current system library matches binding.
- `bound-mismatch`: mismatch detected.
- `unknown`: fingerprint cannot be computed reliably (error state with explicit prompt).

### Detection Timing

Detect library-binding mismatches in two places:

1. **At startup** after archive config load and before enabling write-capable archive actions.
2. **While app is running** whenever the system photo library identity changes.

While-loaded detection should be debounced and coalesced so the user sees a single prompt, not repeated alerts.

### Settings Breadcrumb Synchronization

When the system photo library changes (startup or live), the Settings Library pane breadcrumb/path UI must refresh immediately to the newly active system library.

Requirements:

- The breadcrumb is updated before or at the same time as any mismatch/coupling prompt is shown.
- The breadcrumb must never display a stale previous library path after a detected switch.
- If the current system library path is temporarily unresolved, breadcrumb should show a clear fallback state (`Current System Library`) rather than stale data.

### Coupling Registry

Maintain an app-level registry of known library/archive couplings:

- `libraryFingerprint -> archiveRootBookmark + archiveID + display hints`

Purpose:

- Fast, friendly switching when user changes to a system library that already has a known coupled archive.
- Deterministic fallback when current library has no known coupled archive.

### Gate Rules

- `bound-match`: all features proceed normally.
- `library-switched-known-coupling`:
  - If active archive is not the coupled archive for the new library, offer friendly archive switch dialog.
  - On confirm, switch active archive automatically and continue.
- `bound-mismatch` and `strict`:
  - Allow archive browsing/read operations.
  - Block import/organize/export flows that rely on dedupe.
  - Show resolution prompt immediately if user is in an archive-related workflow, otherwise surface a banner and prompt on interaction.
- `unbound`:
  - Bind on first write operation (or explicit bind action) after user confirmation.

## UX Specification

### Mismatch Prompt

Title: `Archive Linked to Different Photo Library`

Body:
`This archive is linked to “{oldLibraryName}”. You are currently using “{currentLibraryName}”. To prevent incorrect duplicate handling, choose how to continue.`

Actions:

1. `Switch Photo Library`
2. `Choose Different Archive`
3. `Rebind Archive to Current Library…`
4. `Cancel`

Presentation:

- Startup: app-modal sheet after main window appears, before user starts write actions.
- While loaded: document-modal sheet anchored to main window if user attempts blocked action; otherwise a non-intrusive banner with `Resolve...`.

### Known-Coupling Switch Prompt

Title: `Switched to {LibraryName}`

Body:
`Librarian found the archive linked to this photo library: “{ArchiveName}”. Do you want to switch to it now?`

Actions:

1. `Switch to Linked Archive`
2. `Stay on Current Archive`
3. `Always switch automatically for known libraries` (optional preference checkbox)

Behavior:

- If user confirms, switch archive root and proceed.
- If user declines, keep current archive but apply mismatch gate to write flows where relevant.

### No-Coupling Prompt

Title: `No Archive Linked to This Photo Library`

Body:
`You switched to “{LibraryName}”, but no linked archive was found. Choose how you want to continue.`

Actions:

1. `Create New Archive`
2. `Choose Existing Archive`
3. `Continue Without Archive` (read-only limited mode)

### Rebind Confirmation

Title: `Rebind Archive?`

Body:
`Rebinding changes duplicate detection for future imports. Existing files in this archive will not be moved or deleted automatically.`

Actions:

1. `Cancel`
2. `Rebind`

### Path A and Path B Entry Behavior

- Path A (`Import Photos into Archive...`):
  - If mismatch: show gate before import sheet starts.
- Path B (banner `Review Import...`):
  - If mismatch: open same gate first.
  - Only proceed to review/import sheet after match or explicit rebind.
- If known coupling exists for current system library and user accepted switch:
  - both Path A and Path B proceed on the switched archive without additional prompts.

### Messaging Requirements

- Use concrete library names when available:
  - old: from binding path hint/display name
  - current: from active system library hint/display name
- Avoid technical error phrasing in primary body text.
- Include one-line consequence text:
  - `Import is paused to prevent incorrect duplicate handling.`

## Dedupe Semantics (Post-Gate)

- Dedupe always compares against the **currently bound** Photo library.
- Rebind changes dedupe target for future operations only.
- Existing archive files are treated as immutable historical content unless user runs separate cleanup tooling.

## Migration Plan

### v1 -> v2 `archive.json`

On first load of v1:

1. Preserve all existing fields.
2. Set `schemaVersion` to `2`.
3. Add `photoLibraryBinding`:
   - If current library fingerprint is available, bind immediately with `strict`.
   - If unavailable, leave unbound and require bind confirmation before next write.
4. Write atomically.

Do not block archive browsing during migration failure; block only write flows that require binding.

## Implementation Slices

### Slice 1: Data Structures and Read/Write

- Extend `ArchiveControlConfig` in `AppModel.swift` with:
  - new schema version support
  - `photoLibraryBinding` payload
- Add backward-compatible decode for v1 files.
- Add atomic writer helpers for binding updates.

Acceptance:

- v1 file opens and rewrites to valid v2 with no data loss.

### Slice 2: Library Fingerprint Service

- Add `PhotoLibraryFingerprintService`.
- Return:
  - fingerprint string
  - source enum
  - path hint
- Add robust error surface for unknown state.

Acceptance:

- Fingerprint stable across app relaunch with unchanged system library.

### Slice 3: Binding Evaluator + Gate API

- Add `ArchiveLibraryBindingEvaluator`:
  - evaluate current archive vs current system library
  - return enum: `match/mismatch/unbound/unknown`
- Centralize checks used by:
  - Path A trigger
  - Path B banner action
  - any export/organize entry points

Acceptance:

- All write-capable flows call one evaluator path.

### Slice 4: Prompt + Resolution Actions

- Build single reusable mismatch prompt controller.
- Wire actions:
  - `Switch Photo Library` -> existing library switch guidance/action path
  - `Choose Different Archive` -> archive chooser flow
  - `Rebind...` -> explicit confirmation then binding write

Acceptance:

- Mismatch blocks import until one resolution path is completed.

### Slice 5: Path A / Path B Integration

- Path A menu + settings action call gate before presenting import sheet.
- Path B banner action calls same gate before review/import flow.

Acceptance:

- Both entry points converge through same gate behavior.

### Slice 5a: Startup and Live Change Detection

- Add startup check after archive config restore.
- Add observer/poll hook for system library identity changes while loaded.
- Coalesce repeated change events and avoid re-presenting prompt if already shown.
- Resolve changed-library flow in this order:
  1. fingerprint current system library
  2. lookup coupling registry
  3. if known coupling exists, show friendly switch prompt
  4. if no coupling exists, show create-or-select prompt
  5. apply mismatch gate only when user stays on uncoupled archive

Acceptance:

- Startup mismatch always surfaces resolution UI before write actions.
- In-session library switch triggers one clear resolution path without alert spam.
- Known coupling path can switch archives in one confirmation.
- Unknown coupling path always offers create-or-select archive options.
- Settings Library breadcrumb/path reflects the new system library in both startup and live-switch cases without stale values.

### Slice 6: Telemetry, Logging, and Reports

- Log binding mismatches and user resolutions (non-PII).
- Append gate events to `.librarian/reports` optional diagnostic artifacts.

Acceptance:

- Support can diagnose why import was blocked/rebound.

### Slice 7: Test Coverage

- Unit tests:
  - v1->v2 migration
  - evaluator match/mismatch/unbound/unknown
  - rebind updates only binding fields
- Integration tests:
  - Path A mismatch blocks then continues after rebind
  - Path B mismatch blocks banner action until resolved

Acceptance:

- No regression in existing import sheet and dedupe tests.

## Open Questions

1. What is the most stable library identifier available within app sandbox constraints?
2. Should `bindingMode=advisory` be exposed in UI or remain internal only?
3. Should we support intentional one-off import bypass under mismatch (currently no)?

## Recommendation

Proceed with strict default binding and explicit rebind flow. This delivers safety without sacrificing the current Finder-visible archive model or Path B behavior.
