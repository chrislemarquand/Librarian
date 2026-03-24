# Release Checklist

## 1. Preflight

- Confirm branch is up to date with `main`.
- Confirm release target versions are set in source and changelog.

## 2. Quality Gates

Run in order:

```bash
./scripts/deps/verify_shared_ui_pin.sh
xcodebuild -resolvePackageDependencies -project Librarian.xcodeproj -scheme Librarian
./scripts/release/release_check.sh
```

Release checks must pass with no Swift warnings.

Required gates before tagging:

- [ ] Automated trust-boundary smoke is green (`./scripts/release/trust_boundary_smoke.sh`).
- [ ] Full manual Photos flow pass recorded:
  index -> analyse -> review queues -> set aside -> export -> verify Archive -> delete from Photos.
- [ ] Duplicates quality sample pass recorded on a real library.

For SharedUI updates, use:

```bash
./scripts/deps/bump_sharedui.sh <version>
```

## 3. Git and Tag

- Commit release metadata updates.
- Create annotated tag (example):

```bash
git tag -a v0.1.0 -m "Librarian v0.1.0"
```

- Push branch and tag.

## 4. Artifacts (Signed/Notarized)

Set env vars:

```bash
export DEVELOPMENT_TEAM="YOUR_TEAM_ID"
export DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (YOUR_TEAM_ID)"
export NOTARY_PROFILE="YOUR_NOTARY_PROFILE"
```

Build notarized artifacts:

```bash
./scripts/release/release.sh
```

## 5. Publish

- Create GitHub release from the pushed tag.
- Attach built artifacts and release notes.
