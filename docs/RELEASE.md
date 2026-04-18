# Release, Signing, Notarization, and DMG

This project includes scripts for direct-download signed/notarized macOS releases.

## Prerequisites

- Xcode command line tools installed.
- A valid `Developer ID Application` certificate in your keychain.
- Apple team ID.
- A configured notarytool keychain profile.

Create notary profile once:

```bash
xcrun notarytool store-credentials "LIBRARIAN_NOTARY" \
  --apple-id "you@example.com" \
  --team-id "YOUR_TEAM_ID" \
  --password "app-specific-password"
```

## Environment variables

```bash
export DEVELOPMENT_TEAM="YOUR_TEAM_ID"
export DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (YOUR_TEAM_ID)"
export NOTARY_PROFILE="LIBRARIAN_NOTARY"
```

## Build, notarize, and package

```bash
./scripts/release/release.sh
```

The final artifact is produced at:

- `build/dmg/Librarian.dmg` (or `build/dmg/<AppName>.dmg` when `APP_NAME` is overridden)

## Versioning

`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` are derived automatically from the git tag by `archive.sh` — do not edit them in `Config/Base.xcconfig` before a release. Push a tag of the form `vMAJOR.MINOR` or `vMAJOR.MINOR.PATCH` and CI does the rest.

Build number formula: `MAJOR×10000 + MINOR×100 + PATCH`. This is always monotonically increasing and avoids the shallow-clone `git rev-list` issue.

## CI pipeline

Pushing a version tag triggers the GitHub Actions release workflow, which:
1. Archives a signed Release build with version derived from the tag.
2. Zips and notarises the app.
3. Creates and notarises a DMG.
4. Generates a signed `appcast.xml` and attaches all artifacts to a GitHub release.
5. Publishes `appcast.xml` to the `gh-pages` branch so Sparkle picks it up.

The appcast enclosure URL points at GitHub release assets (not GitHub Pages), so Sparkle downloads the correct artifact.

## Script breakdown

- `scripts/release/archive.sh`: archives signed Release build; derives version/build from git tag.
- `scripts/release/notarize.sh`: submits artifact to Apple notarization and staples ticket.
- `scripts/release/create_dmg.sh`: creates and signs DMG from archived app.
- `scripts/release/release.sh`: orchestrates zip notarization + DMG creation/notarization.
- `scripts/release/generate_appcast.sh`: generates signed `appcast.xml` with correct download URL prefix.
- `scripts/release/release_check.sh`: preflight quality gates for package resolve/build/test/warnings.
