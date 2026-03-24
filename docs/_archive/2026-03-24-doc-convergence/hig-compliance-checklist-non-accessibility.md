# HIG Compliance Checklist (Non-Accessibility)

Scope: macOS HIG + Apple style guidance, excluding accessibility work (handled later in a dedicated pass).

Date: 2026-03-21

## Current Status

Librarian is broadly aligned with macOS conventions (windowing, split view, toolbar, settings window, menu bar commands). The main remaining gaps are alert strategy, command validation/discoverability, and consistency of nonmodal status communication.

## Gaps and Actions

### 1) Reduce launch-time modal interruptions

Issue:
- On launch/library-change flows can produce blocking alerts for archive relink/library-link resolution.

HIG direction:
- Avoid unnecessary alerts, especially at startup; prefer progressive disclosure and inline guidance where possible.

Action:
- Gate launch alerts behind a single startup coordinator.
- Prefer nonmodal banner/status first when safe; escalate to modal only when user action is required to proceed.

Acceptance:
- Cold launch with valid archive/library link shows no modal.
- Cold launch with recoverable mismatch shows one clear decision prompt max.
- No repeated alert loop when user cancels.

---

### 2) Convert informational success alerts to inline status

Issue:
- Some operations still end with informational `NSAlert` success dialogs.

Targets:
- `Archive Move Complete`
- Add-photos completion where no action is required

Action:
- Replace with nonmodal status text and/or inline banner in the active surface.
- Keep modal alerts only for errors or explicit confirmations.

Acceptance:
- Successful move/import completion does not block interaction with an extra OK step.
- Errors still use alerts or inline error banners based on severity/context.

---

### 3) Tighten destructive/confirmation alert semantics

Issue:
- Some alert copy/buttons are close but not fully action-specific/consistent.

Action:
- Ensure confirmation alerts use explicit action labels (already mostly true) and keep `Cancel` present.
- Reserve `OK` for informational acknowledgment only.
- Ensure default button is the recommended/safest next step for the context.

Acceptance:
- All warning alerts have clear action labels and `Cancel`.
- No destructive action is bound to ambiguous button text.

---

### 4) Ensure complete menu command parity for primary actions

Issue:
- Core actions are present in menu/toolbar/context menu, but validation and parity should be fully audited.

Action:
- Confirm every primary command has:
  - menu bar route
  - enabled/disabled logic (`validateUserInterfaceItem`)
  - keyboard shortcut where appropriate
- Add missing validation for commands currently executable in invalid state.

Acceptance:
- Menu bar accurately reflects current command availability.
- No menu command triggers confusing no-op behavior.

---

### 5) Standardize nonmodal progress/status language by operation surface

Issue:
- Progress/status messaging has improved, but pattern should be explicit and enforced:
  - Sheet-owned operations -> status in sheet
  - App-global operations -> status/subtitle

Action:
- Document this ownership model in code comments or internal docs.
- Remove any remaining duplicate status surfaces for same operation phase.

Acceptance:
- No operation shows competing status in multiple places unless intentionally redundant for safety.
- Export/import/status copy remains consistent in tone and tense.

---

### 6) Polish copy casing/ellipsis consistency in command labels

Issue:
- Most labels are compliant; run a final consistency sweep after feature work stabilizes.

Action:
- Use title-style capitalization for menu items.
- Use ellipsis (`…`) only when another decision/input step follows.

Acceptance:
- Menu/context labels are consistent and predictable across app.

## Recommended Execution Order

1. Slice A: Launch alert coordinator + dedupe
2. Slice B: Replace informational success alerts with inline/nonmodal status
3. Slice C: Menu parity + command validation audit
4. Slice D: Status-surface ownership cleanup
5. Slice E: Final copy consistency sweep

## Notes

- Accessibility is intentionally excluded here and should be run as a dedicated program later.
- This checklist is implementation-oriented and intended to track engineering completion, not just copy edits.
