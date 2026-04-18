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

### 1. Push a version tag

Do not edit `MARKETING_VERSION` or `CURRENT_PROJECT_VERSION` manually. Push an annotated tag and CI derives them automatically:

```bash
git tag -a v1.0 -m "Librarian v1.0"
git push origin v1.0
```

The build number is computed as `MAJOR×10000 + MINOR×100 + PATCH` (e.g. `v1.0` → `10000`).

### 2. CI does the rest

Pushing the tag triggers the GitHub Actions release workflow, which:
1. Archives a signed Release build with version from the tag.
2. Zips and notarises the app.
3. Creates and notarises a DMG.
4. Generates a signed `appcast.xml` pointed at the GitHub release assets.
5. Creates a GitHub release with all artifacts attached.
6. Pushes `appcast.xml` to the `gh-pages` branch.

Monitor the Actions tab on GitHub. When complete, Sparkle will detect the update on next background check in any existing install.

### 3. Distribute the DMG

The DMG is attached to the GitHub release automatically. Share the release URL or link directly to the DMG asset.

## Key locations

| Thing | Location |
|---|---|
| Public key (in repo) | `Config/Base.xcconfig` → `SPARKLE_PUBLIC_ED_KEY` |
| Private key | macOS keychain, account name `Sparkle` — back up to 1Password |
| Appcast (live) | `https://chrislemarquand.github.io/Librarian/appcast.xml` |
| Appcast (source) | `gh-pages` branch, root of repo |
| Release scripts | `scripts/release/` |
| Release docs | `docs/RELEASE.md` |
