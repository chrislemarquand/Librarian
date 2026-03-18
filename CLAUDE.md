# CLAUDE.md — Librarian

## Read these before doing anything else

1. Read this file fully.
2. Read `Librarian_Spec_v0_5.md` in this directory for the full product and engineering spec.
3. Read the Ledger source at `/Users/chrislemarquand/Xcode Projects/Ledger` before writing any window shell, split-view, toolbar, inspector, or navigation code. Understand the patterns and adapt them — do not copy-paste blindly. Ledger's centre pane is list/table-oriented and should not be inherited; reuse the frame, not the purpose.

Do not write any code until you have read all three and confirmed your understanding.

## What this project is

Librarian is a native macOS companion app for Apple Photos. It helps users reduce a large photo library into a smaller, more meaningful one by providing review queues, safe archival export, and contextual curation. It never permanently deletes anything without archiving and verifying first.

The full spec is in `Librarian_Spec_v0_5.md`.

## Stack — no deviations without discussion

- **AppKit** for the app shell — not SwiftUI (SwiftUI in strict islands only if necessary)
- **PhotoKit** for all live Photos access — not osxphotos for live reads
- **GRDB** as the SQLite layer — use its built-in migration system for all schema changes
- **osxphotos** bundled at a pinned version — invoked via XPC helper, not direct subprocess
- **Foundation Models** for explanation generation where available, heuristic fallback elsewhere
- **Vision / Core ML** for local analysis

## Architecture rules

1. PhotoKit is the live runtime interface. osxphotos is invoked only for explicit user-initiated actions — never passively, never as a live data source. Never blur this boundary. Currently approved actions: archive export, library analysis pass (see Key decisions).
2. All schema changes are GRDB migrations — named, sequential, append-only, applied at startup before any database access.
3. The app is sandboxed. The archive root is accessed via a security-scoped bookmark. The osxphotos helper runs in an XPC service. Design entitlements explicitly.
4. Nothing is deleted from Photos until: iCloud download complete → export succeeded → verification passed → ArchiveRecord written.
5. The UI unit is always the PHAsset. One asset may produce multiple archive files (AssetResource table handles this).

## Key decisions already made — do not re-open these

| Topic | Decision |
|---|---|
| Edited photo export | Both original and edited versions |
| iCloud asset not local | Download on demand, retry 3× with backoff, then flag |
| Filename collision in archive | Append numeric suffix (_2, _3, …) |
| Archive root change | Offer migration job to move existing archives |
| Photos access denied/revoked | Locked state UI, preserve local database |
| Limited Photos access | Refuse — require full access |
| Archive folder structure | Two top-level folders: `Photos/` and `Other/`. Duplicates → `Photos/YYYY/MM`. Screenshots, Likely Bad, Review Later → `Other/{Category}/YYYY/MM`. |
| Sandboxing | Sandboxed with entitlements |
| Media types in v1 | All five: stills, video, Live Photos, RAW+JPEG, bursts |
| Review marking behaviour | Single-press commits to archive queue, no confirmation dialog |
| Inspector preview | Thumbnail immediately; full-res auto-loads if asset is local; cloud-only assets do not auto-load |
| Explanation snippets | Foundation Models where available, heuristic fallback |
| Logging | Structured log file in Application Support + os_log, viewable in Tasks/Log pane |
| Schema migrations | GRDB built-in migration system |
| osxphotos scope | User-initiated actions only: archive export and library analysis pass. Never passive or automatic. |
| Library analysis — trigger | Offered (non-modal prompt) after initial index completes; re-runnable from Settings. Never a blocking setup step — app must be fully usable without it. |
| Library analysis — data imported | Quality scores (overall + components), file size in bytes, named-person presence + count, ML content labels, perceptual fingerprint. Specific columns in `asset` table — no full JSON blob storage. |
| Library analysis — UUID join | osxphotos returns bare UUIDs; `localIdentifier` in GRDB is `UUID/L0/001` format. Strip suffix before joining (same logic as export batch). |
| Library analysis — staleness | Display "last analysed" date in Settings (and near any score-dependent queue). Offer refresh if asset count has grown significantly but do not nag. |
| Low Quality queue | Hidden (not greyed out) until analysis has been run at least once. Show one-line explanation and direct link to run analysis if user navigates to where it will appear. |

## Build order

Follow the phases in spec section 24. Do not skip ahead to Phase 5+ before Phase 4 (the archive pipeline) is solid. The archive/delete pipeline is the trust boundary of the whole app.

**Phase 1** — shell and indexing  
**Phase 2** — basic browsing  
**Phase 3** — screenshots queue  
**Phase 4** — archive pipeline (this is the critical one)  
**Phase 5** — additional queues  
**Phase 6** — context review  
**Phase 7** — polish  

## What to reuse from Ledger

Ledger lives at `/Users/chrislemarquand/Xcode Projects/Ledger`. Read it before writing any shell code.

Reuse: window shell, split-view, toolbar philosophy, inspector pattern, command/menu structure, keyboard navigation, contextual menu patterns, and task/progress infrastructure. Do not inherit Ledger's centre-pane assumptions — Librarian's centre pane is a photo grid, not a list or table.

## What not to build in v1

- OpenAI integration
- Story/meaningfulness engine
- Photos album creation
- Restore UI
- Extensive custom UI

## Known divergences from spec (must be resolved)

These are places where the current implementation contradicts a locked decision above.
Do not treat them as design choices — they are bugs to fix.

| Topic | Spec decision | Current behaviour | Where |
|---|---|---|---|
| Edited photo export | Both original and edited versions | `--skip-original-if-edited` passed to osxphotos — exports edited only | `AppModel.swift` → `runOsxPhotosExportBatch` |
| Live Photos | All five media types including Live Photos | `--skip-live` passed to osxphotos — drops the video component | `AppModel.swift` → `runOsxPhotosExportBatch` |
| osxphotos invocation | Runs in XPC service | Direct `Process()` subprocess in main app — works in development but will fail sandbox entitlement checks at distribution | `AppModel.swift` → `runOsxPhotos` |
| Stale export state | Partial failures visible and recoverable | `exporting` rows survive an app crash and are never retried | `AppModel.swift` → `setup()` (no reset on launch) |

## The one thing that must not go wrong

**Deletion safety.** The candidate list is frozen at execution time. Verification must be complete before deletion fires. Partial failures must be visible and recoverable. In-flight delete sets are immutable. If in doubt, do less and surface the state clearly.
