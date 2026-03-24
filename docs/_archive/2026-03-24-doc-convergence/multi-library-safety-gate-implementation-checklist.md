# Multi-Library Safety Gate Implementation Checklist

## Scope

Implementation checklist for `docs/multi-library-safety-gate.md`.

Conventions:

- Ticket IDs are ordered by dependency.
- Each ticket includes explicit file ownership.
- Acceptance criteria are binary.

## Milestone 1: Data Model + Fingerprint Foundation

### MLSG-001: Extend archive control schema to v2 with library binding

Owner: Core model  
Depends on: none

Files:

- `Sources/Librarian/Model/AppModel.swift`

Tasks:

1. Extend `ArchiveControlConfig` with optional `photoLibraryBinding`.
2. Add nested binding model types (`libraryFingerprint`, `libraryIDSource`, `libraryPathHint`, `boundAt`, `bindingMode`, `lastSeenMatchAt`).
3. Make decode backward-compatible with schema v1.
4. Add atomic write helper for config updates without touching unrelated fields.

Acceptance:

1. v1 `archive.json` decodes successfully.
2. v2 file writes with new binding fields intact.
3. Existing `archiveID` behavior unchanged.

### MLSG-002: Add photo library fingerprint service

Owner: Core model  
Depends on: MLSG-001

Files:

- `Sources/Librarian/Model/PhotoLibraryFingerprintService.swift` (new)
- `Sources/Librarian/Model/AppModel.swift` (wire-in only)

Tasks:

1. Implement `currentFingerprint()` API returning `(fingerprint, source, pathHint)`.
2. Implement fallback fingerprinting path when preferred ID source is unavailable.
3. Define error cases for unknown/unavailable fingerprint.

Acceptance:

1. Same active system library returns stable fingerprint across relaunch.
2. Service reports source used.
3. Failures are explicit and do not crash.

## Milestone 2: Binding Evaluation + Gate

### MLSG-003: Add archive-library binding evaluator

Owner: Core model  
Depends on: MLSG-002

Files:

- `Sources/Librarian/Model/ArchiveLibraryBindingEvaluator.swift` (new)
- `Sources/Librarian/Model/AppModel.swift` (integration points)

Tasks:

1. Implement evaluation states: `match`, `mismatch`, `unbound`, `unknown`.
2. Compare config binding vs current fingerprint.
3. Update `lastSeenMatchAt` on successful match.

Acceptance:

1. Evaluator returns deterministic state for all four cases.
2. Match path updates timestamp only.
3. No write-path side effects in evaluate-only mode.

### MLSG-003A: Add startup and live library-change detection

Owner: Core model + shell bridge  
Depends on: MLSG-002

Files:

- `Sources/Librarian/Model/AppModel.swift`
- `Sources/Librarian/AppDelegate.swift`
- `Sources/Librarian/Shell/MainSplitViewController.swift` (if presentation wiring needed)
- `Sources/Librarian/Shell/LibrarySettingsViewController.swift`

Tasks:

1. Run mismatch evaluation at startup after archive restore.
2. Add runtime system-library identity re-check trigger.
3. Debounce/coalesce checks and avoid duplicate prompt presentation.
4. Resolve change flow by checking known couplings before mismatch handling.
5. Post/update notification hooks so Settings Library breadcrumb/path UI refreshes immediately on system library change.

Acceptance:

1. Startup mismatch is detected before write flows.
2. In-session library switch triggers exactly one user-facing resolution prompt path.
3. Known-coupling change triggers friendly archive-switch prompt.
4. Unknown-coupling change triggers create-or-select archive prompt.
5. Settings Library breadcrumb/path never remains stale after system library switch.

### MLSG-004: Centralize write-flow preflight gate API

Owner: Core model + shell bridge  
Depends on: MLSG-003

Files:

- `Sources/Librarian/Model/AppModel.swift`
- `Sources/Librarian/Model/ArchiveImportCoordinator.swift`

Tasks:

1. Add single preflight API for write-capable archive flows.
2. Return structured result used by UI (`allowed`, `requiresResolution`, `error`).
3. Ensure import/organize/export call this API.

Acceptance:

1. No write flow bypasses gate API.
2. API can be called from Path A and Path B entry points.

### MLSG-004A: Add library/archive coupling registry

Owner: Core model  
Depends on: MLSG-002

Files:

- `Sources/Librarian/Model/ArchiveLibraryCouplingRegistry.swift` (new)
- `Sources/Librarian/Model/AppModel.swift`

Tasks:

1. Persist mapping: `libraryFingerprint -> archive bookmark/archiveID/display hints`.
2. Update coupling entry when archive binding is created or rebound.
3. Expose lookup API for current library fingerprint.

Acceptance:

1. Known library fingerprint resolves to linked archive metadata.
2. Registry updates are atomic and resilient to partial write failures.

## Milestone 3: UX and Flow Integration

### MLSG-005: Build reusable mismatch prompt controller

Owner: Shell/UI  
Depends on: MLSG-004

Files:

- `Sources/Librarian/Shell/ArchiveLibraryMismatchPrompt.swift` (new)
- `Sources/Librarian/Shell/MainSplitViewController.swift` (presentation hookup as needed)

Tasks:

1. Implement prompt copy and actions from spec.
2. Wire callbacks for: switch library, choose archive, rebind, cancel.
3. Add explicit rebind confirmation step.

Acceptance:

1. Prompt appears on mismatch with all required actions.
2. Rebind requires confirmation.
3. Cancel keeps flow blocked safely.

### MLSG-005A: Build known-coupling switch prompt

Owner: Shell/UI  
Depends on: MLSG-004A

Files:

- `Sources/Librarian/Shell/ArchiveLibraryMismatchPrompt.swift`
- `Sources/Librarian/Shell/MainSplitViewController.swift` (or equivalent presenter)

Tasks:

1. Add friendly prompt for switching to linked archive when a known coupling is found.
2. Support actions: `Switch to Linked Archive`, `Stay on Current Archive`.
3. Optional: persist a preference for auto-switch on known couplings.

Acceptance:

1. Prompt appears when system library changes to one with a known coupling.
2. Confirming switch updates active archive root and clears write-flow block.

### MLSG-005B: Build no-coupling create-or-select prompt

Owner: Shell/UI  
Depends on: MLSG-004A

Files:

- `Sources/Librarian/Shell/ArchiveLibraryMismatchPrompt.swift`
- `Sources/Librarian/Shell/ArchiveSettingsViewController.swift`

Tasks:

1. Add prompt for system libraries that have no coupled archive.
2. Wire actions: `Create New Archive`, `Choose Existing Archive`, `Continue Without Archive`.
3. Route create/select into existing archive setup/relink flows.

Acceptance:

1. Unknown-coupling flow always offers create-or-select.
2. Path A and Path B remain blocked until archive is selected/created or user enters limited mode.

### MLSG-006: Integrate gate into Path A entry points

Owner: Shell/UI  
Depends on: MLSG-005

Files:

- `Sources/Librarian/Shell/ArchiveSettingsViewController.swift`
- `Sources/Librarian/Shell/ContentController.swift`
- `Sources/Librarian/Shell/ArchiveImportSheetPresenter.swift`

Tasks:

1. Run gate before presenting import sheet from settings/menu.
2. If gate resolves to allowed, continue existing import sheet path.
3. If unresolved mismatch, do not open sheet.

Acceptance:

1. Path A always gates first.
2. No duplicate prompt presentations.

### MLSG-007: Integrate gate into Path B banner action

Owner: Shell/UI  
Depends on: MLSG-005

Files:

- `Sources/Librarian/Shell/ContentController.swift`
- `Sources/Librarian/Shell/ArchiveImportSheetPresenter.swift`

Tasks:

1. Run same gate before `Review Import...` action proceeds.
2. On success, continue existing Path B unified sheet flow.
3. On unresolved mismatch, keep banner actionable.

Acceptance:

1. Path B never bypasses gate.
2. Post-resolution flow opens exactly once.

## Milestone 4: Migration + Reporting + Tests

### MLSG-008: Implement v1->v2 migration path

Owner: Core model  
Depends on: MLSG-001, MLSG-002

Files:

- `Sources/Librarian/Model/AppModel.swift`

Tasks:

1. Detect schema v1 at load.
2. Upgrade to v2 and persist atomically.
3. If fingerprint unavailable, keep unbound state and defer binding to write flow.

Acceptance:

1. Migration is idempotent.
2. Failed migration does not break archive browsing.

### MLSG-009: Add gate diagnostics logging/report events

Owner: Core model  
Depends on: MLSG-004

Files:

- `Sources/Librarian/Model/AppModel.swift`
- `Sources/Librarian/Model/AppLog.swift` (if needed)

Tasks:

1. Log mismatch detection and chosen resolution path.
2. Add lightweight report artifact writes under `.librarian/reports` only where justified.
3. Avoid PII-heavy payloads.

Acceptance:

1. Logs allow reconstruction of why flow was blocked.
2. No sensitive data leakage.

### MLSG-010: Add tests for evaluator, migration, and flow gates

Owner: Tests  
Depends on: MLSG-003, MLSG-006, MLSG-007, MLSG-008

Files:

- `Tests/LibrarianTests/ArchiveLibraryBindingEvaluatorTests.swift` (new)
- `Tests/LibrarianTests/ArchiveConfigMigrationTests.swift` (new)
- `Tests/LibrarianTests/ArchiveImportFlowTests.swift` (extend)

Tasks:

1. Unit tests: match/mismatch/unbound/unknown states.
2. Unit tests: v1->v2 migration and idempotency.
3. Integration tests: Path A and Path B are blocked on mismatch and continue after resolution.

Acceptance:

1. New tests pass reliably.
2. Existing import/dedupe tests still pass.

## Execution Order

1. MLSG-001
2. MLSG-002
3. MLSG-003
4. MLSG-003A
5. MLSG-004
6. MLSG-004A
7. MLSG-005
8. MLSG-005A
9. MLSG-005B
10. MLSG-006
11. MLSG-007
12. MLSG-008
13. MLSG-009
14. MLSG-010

## Suggested PR Slices

1. PR-1: MLSG-001 + MLSG-002 + MLSG-003
2. PR-2: MLSG-003A + MLSG-004 + MLSG-004A
3. PR-3: MLSG-005 + MLSG-005A + MLSG-005B
4. PR-4: MLSG-006 + MLSG-007
5. PR-5: MLSG-008 + MLSG-009 + MLSG-010

## Ready-to-Start Ticket

Start with MLSG-001 in `AppModel.swift`, then MLSG-002 as a new isolated service file. This keeps risk low and unlocks all downstream work.
