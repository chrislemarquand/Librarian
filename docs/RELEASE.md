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

## Script breakdown

- `scripts/release/archive.sh`: archives signed Release build (project/scheme configurable via env vars).
- `scripts/release/notarize.sh`: submits artifact to Apple notarization and staples ticket.
- `scripts/release/create_dmg.sh`: creates and signs DMG from archived app.
- `scripts/release/release.sh`: orchestrates zip notarization + DMG creation/notarization.
- `scripts/release/release_check.sh`: preflight quality gates for package resolve/build/test/warnings.
