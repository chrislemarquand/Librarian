# Swift 6 Migration Backlog

## Policy

- App target uses Swift 6.
- Migrate app code module-by-module; avoid broad unsafe suppressions.
- Keep dependency upgrades explicit and pinned.

## Current Status (2026-03-20)

- `SWIFT_VERSION` has been set to `6.0` in `Config/Base.xcconfig` and Librarian build configs.
- Standard Librarian debug build remains the source-of-truth gate.

## Known Blockers

1. Third-party package Swift 6 strictness under global override.
- A probe build that forced `SWIFT_VERSION=6.0` from the command line causes GRDB package compile errors:
  - `Utils.swift`: static mutable state concurrency-safety error.
  - `ValueObservation.swift`: non-Sendable capture in `@Sendable` closure.
- This is a package-level issue when forcing all targets; do not use command-line global `SWIFT_VERSION` override in release scripts.

2. App-side Swift 6 warning cleanup.
- Existing warnings in database model files (`@preconcurrency` conformance markers with no effect).
- Action: remove redundant annotations and keep build clean.

## Backlog

1. UI layer pass (`Shell/*`).
- Validate actor isolation for controller coordination paths.
- Remove ad-hoc nonisolated escapes where possible.

2. Data/indexing pass (`Database/*`, `Indexing/*`, `Photos/*`).
- Confirm task boundaries and shared mutable state patterns.
- Add targeted `Sendable` conformances only where semantically correct.

3. Dependency strategy.
- Track GRDB release notes for Swift 6 concurrency compatibility.
- Upgrade GRDB only via pinned version update + full gate run.

## Execution Order

1. Remove no-op `@preconcurrency` usage.
2. UI actor isolation cleanup.
3. Data/indexing sendability cleanup.
4. Re-probe dependency set and update if needed.
