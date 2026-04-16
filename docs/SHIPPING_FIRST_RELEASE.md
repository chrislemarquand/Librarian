# Shipping the First Release

This document covers what to do once Librarian is ready to ship — signing, notarizing, packaging, and wiring up Sparkle so users receive the update.

## What's already done

- Sparkle 2.9.1 is integrated and configured
- `SUFeedURL` points to `https://chrislemarquand.github.io/Librarian/appcast.xml`
- ED25519 public key is baked into the app via `Base.xcconfig`
- The private key is in your Mac keychain (account: `Sparkle`) — back it up to 1Password
- GitHub repo is at `https://github.com/chrislemarquand/Librarian`
- GitHub Pages is live at `https://chrislemarquand.github.io/Librarian/`
- `appcast.xml` placeholder is published on the `gh-pages` branch
- Release scripts exist in `scripts/release/`

## Prerequisites before you can ship

### 1. Developer ID Application certificate

You need a paid Apple Developer account ($99/year) and a Developer ID Application certificate.

- Log into developer.apple.com → Certificates, IDs & Profiles → create a Developer ID Application certificate
- Download and double-click to install into your keychain
- Find your Team ID (10-character alphanumeric string, shown on your account page)

### 2. Notarization profile

Run this once from Terminal, substituting your details:

```bash
xcrun notarytool store-credentials "LIBRARIAN_NOTARY" \
  --apple-id "you@apple.com" \
  --team-id "YOUR_TEAM_ID" \
  --password "app-specific-password"
```

The app-specific password is generated at appleid.apple.com → Sign-In and Security → App-Specific Passwords.

### 3. Set environment variables

Before running release scripts, export these in your terminal session:

```bash
export DEVELOPMENT_TEAM="YOUR_TEAM_ID"
export DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (YOUR_TEAM_ID)"
export NOTARY_PROFILE="LIBRARIAN_NOTARY"
export SPARKLE_PRIVATE_KEY="YOUR_SPARKLE_PRIVATE_KEY"
```

The Sparkle private key is in your Mac keychain under the name `Sparkle`. You can also export it
to a file with:

```bash
~/path/to/Sparkle/bin/generate_keys -x /tmp/sparkle_key.txt
cat /tmp/sparkle_key.txt
rm /tmp/sparkle_key.txt
```

## Shipping a release

### 1. Bump the version

In `Config/Base.xcconfig`:
- `MARKETING_VERSION` — the user-facing version, e.g. `1.0`
- `CURRENT_PROJECT_VERSION` — an integer build number, increment by 1 each release

### 2. Build, sign, notarize, and package

```bash
cd "/Users/chrislemarquand/Xcode Projects/Librarian"
GENERATE_APPCAST=1 ./scripts/release/release.sh
```

This will:
1. Archive a signed Release build
2. Zip and notarize it
3. Create and notarize a DMG
4. Generate a signed `appcast.xml` entry using your Sparkle private key

The DMG lands at `build/dmg/Librarian.dmg`.

### 3. Publish the appcast

The appcast entry is generated into `appcast.xml` in the project root (or alongside the ZIP). Take that file and push it to the `gh-pages` branch:

```bash
git checkout gh-pages
cp /path/to/generated/appcast.xml ./appcast.xml
git add appcast.xml
git commit -m "Publish appcast for vX.Y"
git push
git checkout -
```

GitHub Pages will serve it within a minute or so. Once live, any existing install of Librarian will pick up the update on next background check.

### 4. Distribute the DMG

Upload `build/dmg/Librarian.dmg` wherever you're distributing from (GitHub Releases is the obvious choice — create a release on the repo and attach the DMG).

## Key locations

| Thing | Location |
|---|---|
| Public key (in repo) | `Config/Base.xcconfig` → `SPARKLE_PUBLIC_ED_KEY` |
| Private key | macOS keychain, account name `Sparkle` — back up to 1Password |
| Appcast (live) | `https://chrislemarquand.github.io/Librarian/appcast.xml` |
| Appcast (source) | `gh-pages` branch, root of repo |
| Release scripts | `scripts/release/` |
| Release docs | `docs/RELEASE.md` |
