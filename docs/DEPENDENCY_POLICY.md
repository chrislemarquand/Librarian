# Dependency Policy

## Pinning

- Shared cross-repo dependencies (for example `SharedUI`) must be pinned to a released tag.
- Do not ship with local path package references.

## Update Procedure

1. Update package requirement in Xcode/project settings.
2. Resolve dependencies:

```bash
xcodebuild -resolvePackageDependencies -project Librarian.xcodeproj -scheme Librarian
```

3. Commit the lockfile:

- `Librarian.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`

4. Run release gates:

```bash
./scripts/release/release_check.sh
```

5. Include dependency bumps in release notes/changelog.
