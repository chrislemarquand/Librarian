# Engineering Baseline

This document defines the required engineering baseline for Librarian and Ledger.

## Platform and Language

- Deployment target: `macOS 26`.
- Swift language mode: `Swift 6`.
- Release branches must build without Swift compiler warnings.

## Project Configuration

- Use explicit `Config/Base.xcconfig`, `Config/Debug.xcconfig`, and `Config/Release.xcconfig`.
- Keep policy settings in xcconfig files instead of duplicating them in `project.pbxproj`.
- Use explicit `Info.plist` and entitlements file paths.

## Dependencies

- Cross-repo shared dependencies (for example `SharedUI`) must use remote Git package references pinned to tags.
- Do not use local path package references on release branches.
- Commit `Package.resolved` for reproducible builds.

## Release and Quality Gates

- Provide scripted release checks in `scripts/release/`.
- Minimum checks: app build + tests.
- Release tags should only be created from a warning-free release branch.

## SharedUI Release Order

1. Tag and release `SharedUI`.
2. Update app repo to pinned SharedUI tag.
3. Tag and release app repo.
