# Ledger / Librarian Alignment Plan

This document captures the remaining work to align the Ledger and Librarian macOS apps with each other and with Apple's latest Xcode / macOS 26 best practices. Both apps already share a `SharedUI` Swift package for desktop shell components and have aligned engineering baselines, xcconfig structures, release scripts, and architecture docs.

**Repos:**
- Ledger: `/Users/chrislemarquand/Xcode Projects/Ledger`
- Librarian: `/Users/chrislemarquand/Xcode Projects/Librarian`
- SharedUI: `/Users/chrislemarquand/Xcode Projects/SharedUI`

**Shared foundation already in place:**
- Identical `Config/` layout: `Base.xcconfig`, `Debug.xcconfig`, `Release.xcconfig`, app-specific `Info.plist` and entitlements
- Same `docs/` structure: `Engineering Baseline.md`, `ARCHITECTURE.md`, `DEPENDENCY_POLICY.md`, `RELEASE_CHECKLIST.md`, `Swift6 Migration Backlog.md`
- Same `scripts/release/` layout: `release.sh`, `release_check.sh`, `archive.sh`, `notarize.sh`, `create_dmg.sh`
- Both consume SharedUI (pinned tag) for: `ThreePaneSplitViewController`, `AppKitSidebarController`, `SharedGalleryCollectionView`, `SharedGalleryLayout`, `PinchZoomAccumulator`, `ToolbarAppearanceAdapter`, `makeStandardAppMenu()`, `makeStandardWindowMenu()`, `SettingsWindowController`, `NSAlert.runSheetOrModal()`
- Both target macOS 26, Swift 6, AppKit shell with SwiftUI islands, `@MainActor AppModel` single source of truth
- Debug and Release xcconfig files are identical between the two apps

---

## Phase A — Project Structure Alignment

All items touch the project/package definition, build settings, or target identity. Land together to avoid repeated pbxproj churn.

### A1. Move Librarian to SPM-first structure

**Current state:** Librarian is Xcode-project-first with no `Package.swift` at root. Dependencies (SharedUI, GRDB) are managed through Xcode's SPM integration. `Package.resolved` lives at `Librarian.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.

**Target state:** Librarian has a `Package.swift` at root (like Ledger), with `Librarian.xcodeproj` as a thin wrapper. This enables `swift build` / `swift test` from CLI, standardises `Package.resolved` at root, and opens the door to extracting a `LibrarianCore` library target later.

**Reference — Ledger's Package.swift:**
```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ExifEdit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ExifEditCore", targets: ["ExifEditCore"]),
        .executable(name: "ExifEditMac", targets: ["ExifEditMac"])
    ],
    dependencies: [
        .package(url: "https://github.com/chrislemarquand/SharedUI.git", exact: "1.0.0")
    ],
    targets: [
        .target(name: "ExifEditCore"),
        .executableTarget(
            name: "ExifEditMac",
            dependencies: ["ExifEditCore", .product(name: "SharedUI", package: "SharedUI")],
            path: "Sources/Ledger"
        ),
        .testTarget(name: "ExifEditCoreTests", dependencies: ["ExifEditCore"]),
        .testTarget(name: "ExifEditMacTests", dependencies: ["ExifEditMac", "ExifEditCore"], path: "Tests/LedgerTests")
    ]
)
```

**Librarian equivalent shape:**
- Package name: `Librarian`
- Executable target: `Librarian` (path: `Sources/Librarian`)
- Dependencies: `SharedUI` (exact tag), `GRDB` (from `https://github.com/groue/GRDB.swift`, currently at v6.29.3)
- Test target: `LibrarianTests` (path: `Tests/LibrarianTests`)
- The bundled `osxphotos` binary in `Sources/Librarian/Tools/` will need to be excluded from SPM sources or modelled as a resource

**Gotchas:**
- Non-source files under `Sources/Librarian/` (Assets.xcassets, AppIcon.icon, entitlements, Tools/osxphotos binary) need `exclude:` or `resources:` entries in the target definition. Ledger has a known backlog item for this same issue.
- GRDB has known Swift 6 strictness issues when `SWIFT_VERSION=6.0` is forced from the command line (documented in Librarian's Swift6 Migration Backlog). The app-level xcconfig setting works fine; avoid command-line global override in release scripts.
- After adding Package.swift, move `Package.resolved` to root and remove the nested one from `.xcodeproj`.

### A2. Entry point: `main.swift` to `@main enum`

**Current state:** Librarian uses `Sources/Librarian/main.swift`:
```swift
import Cocoa
let app = NSApplication.shared
let delegate = AppDelegate()
MainActor.assumeIsolated {
    app.delegate = delegate
}
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
```

**Target state:** Delete `main.swift`. Add `@main` to a new entry-point enum (matching Ledger's pattern):
```swift
@MainActor
@main
enum LibrarianMain {
    private static var appDelegate: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        self.appDelegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
```

This can live in `AppDelegate.swift` or a new `LibrarianApp.swift` file.

**Also:** Remove `NSPrincipalClass = NSApplication` from `Config/Librarian-Info.plist` — it's unnecessary with `@main` and Ledger doesn't have it.

### A3. Bundle identifier

**Current state:** Librarian's `Config/Base.xcconfig` has `APP_BUNDLE_IDENTIFIER = com.librarian.app` (placeholder-style).

**Target state:** `APP_BUNDLE_IDENTIFIER = com.chrislemarquand.Librarian` to match Ledger's `com.chrislemarquand.Ledger` convention.

**Impact:** Also update the frame autosave name in AppDelegate (`com.librarian.app.MainWindow` → use `AppBrand.identifierPrefix` once Phase C adds it), toolbar identifier, database path (`~/Library/Application Support/com.librarian.app/` → new identifier), and any security-scoped bookmark storage keys. Existing user data at the old path will need a one-time migration or documented manual step.

### A4. Consolidate entitlements

**Current state:** Librarian has two entitlements files:
- `Config/Librarian.entitlements` — currently used by the app target
- `Sources/Librarian/Librarian.entitlements` — legacy/duplicate path in older layout

Ledger has one: `Config/Ledger.entitlements` (sandbox=false, required for ExifTool).

**Target state:** Single entitlements file at `Config/Librarian.entitlements` aligned to the direct-distribution posture (no App Sandbox requirement for v1). Delete `Sources/Librarian/Librarian.entitlements` if still present. Keep only the minimum keys actually required for runtime behavior.

### A5. Privacy manifest for both apps

**Current state:** Neither app has a `PrivacyInfo.xcprivacy` file.

**Target state:** Both apps include `PrivacyInfo.xcprivacy` declaring any covered API usage (file timestamps, UserDefaults, disk space, etc.). Required since Xcode 15 / macOS 14 for notarisation and future App Store submission. Apple documents the required format at the privacy manifest documentation.

**Likely declarations:**
- Both apps: `NSPrivacyAccessedAPICategoryFileTimestamp` (file metadata reading), `NSPrivacyAccessedAPICategoryUserDefaults` (preferences/state persistence)
- Librarian specifically: may need `NSPrivacyAccessedAPICategoryDiskSpace` if checking available space for archive

---

## Phase B — Window & App Lifecycle

Small, self-contained AppDelegate / window-level changes. Can land as individual commits.

### B1. Window creation alignment

**Current state — Librarian's AppDelegate:**
```swift
let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 1300, height: 800),
    styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
    backing: .buffered,
    defer: false
)
window.contentViewController = splitVC
splitVC.loadViewIfNeeded()
window.minSize = NSSize(width: 1100, height: 680)
configureWindowForToolbar(window)
```

**Target state — match Ledger's pattern:**
```swift
let window = NSWindow(contentViewController: splitVC)
window.setContentSize(ThreePaneSplitViewController.Metrics.windowDefault)
window.minSize = ThreePaneSplitViewController.Metrics.windowMinimum
```

On macOS 26 with Liquid Glass, `NSWindow(contentViewController:)` applies the correct toolbar appearance automatically. The explicit `.fullSizeContentView` style mask and `configureWindowForToolbar()` call become unnecessary. SharedUI's `ThreePaneSplitViewController.Metrics` already defines `windowDefault` (1300x800) and `windowMinimum` (1100x720).

**Reference — Ledger's MainWindowController:**
```swift
let window = NSWindow(contentViewController: contentController)
window.setContentSize(ThreePaneSplitViewController.Metrics.windowDefault)
window.minSize = ThreePaneSplitViewController.Metrics.windowMinimum
window.title = AppBrand.displayName
window.isReleasedWhenClosed = false
window.isRestorable = true
window.setFrameAutosaveName("\(AppBrand.identifierPrefix).MainWindow")
window.center()
```

**Also consider:** Librarian's AppDelegate creates the window directly in `applicationDidFinishLaunching`. Ledger wraps it in a `MainWindowController: NSWindowController`. The window controller pattern is cleaner for ownership and could be aligned, but is not strictly required.

### B2. Secure restorable state

**Current state:**
- Ledger: implements `applicationShouldSaveApplicationState → true` and `applicationShouldRestoreApplicationState → true` but does NOT implement `applicationSupportsSecureRestorableState`.
- Librarian: implements `applicationSupportsSecureRestorableState → false`.

**Target state:** Both apps implement:
```swift
func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    true
}
```

Xcode generates a warning if this method is missing or returns false. Apple requires secure coding for state restoration.

### B3. Window restoration for Librarian

**Current state:** Librarian sets `window.isRestorable = false`.

**Target state:** `window.isRestorable = true` with a frame autosave name, matching Ledger. Also add `applicationShouldSaveApplicationState → true` and `applicationShouldRestoreApplicationState → true` to Librarian's AppDelegate.

### B4. Terminate guard for Librarian

**Current state:** Librarian has no `applicationShouldTerminate` implementation. If the user quits during an active archive export or indexing operation, work is silently abandoned. The CLAUDE.md notes that stale `exporting` rows are already a known issue.

**Target state:** Implement `applicationShouldTerminate` that checks for in-flight operations (active export, active indexing) and shows a confirmation sheet, matching Ledger's pattern:

**Reference — Ledger's pattern (LedgerApp.swift:166-214):**
- Checks `appModel.hasUnsavedEdits`
- Shows warning alert via `alert.runSheetOrModal(for:)`
- Uses `allowImmediateTermination` flag to avoid re-entrant confirmation
- Returns `.terminateCancel` while sheet is showing

Librarian's equivalent would check `appModel` for active export/indexing state.

---

## Phase C — App Identity & Polish

Branding and cosmetic alignment. No build structure impact.

### C1. AppBrand pattern for Librarian

**Current state:** Librarian hardcodes `"Librarian"` in AppDelegate (window title, menu item title, menu builder call). Ledger has an `AppBrand` enum in `AppModel.swift`:
```swift
enum AppBrand {
    private static let fallbackDisplayName = "Ledger"
    static let legacyDisplayNames = ["Logbook", "ExifEditMac"]
    static let migrationSentinelKey = "Ledger.Migration.v1Completed"
    static var displayName: String { /* reads CFBundleDisplayName, falls back */ }
    static var identifierPrefix: String { /* reads bundle identifier prefix */ }
}
```

**Target state:** Add equivalent `AppBrand` enum to Librarian with appropriate values. Used for: window title, menu labels, frame autosave names, toolbar identifiers, UserDefaults key prefixes.

### C2. Info.plist cleanup

**Librarian `Config/Librarian-Info.plist` changes needed:**
- `NSHumanReadableCopyright`: currently empty → add `Copyright © $(CURRENT_YEAR) Chris Le Marquand` (or match Ledger's template pattern)
- `NSPrincipalClass`: remove entirely (done in Phase A2 if landing together)
- `CFBundleDisplayName`: consider adding explicitly (currently absent in both apps)

**Ledger `Config/Ledger-Info.plist`:**
- `CFBundleDisplayName`: consider adding explicitly for localisation readiness

**Accent color naming:**
- Ledger uses `NSAccentColorName = BrandAccent`
- Librarian uses `NSAccentColorName = AccentColor` (Xcode default)
- Not a bug, but should be an intentional choice. If both apps should share a brand accent, align the name.

### C3. Custom about panel for Librarian

**Current state:** Librarian's `makeStandardAppMenu()` call does not pass an `aboutAction`. The default About panel is shown.

**Target state:** Add `showAboutPanel()` method to Librarian's AppDelegate and pass it as `aboutAction` to `makeStandardAppMenu()`. Include app description and any attribution (e.g., osxphotos credit).

**Reference:** Ledger's `showAboutPanel()` in `LedgerApp.swift:27-71` builds an `NSAttributedString` credits block and calls `NSApp.orderFrontStandardAboutPanel(options:)`.

### C4. Document Ledger's `ENABLE_USER_SCRIPT_SANDBOXING = NO`

**Current state:** Ledger's `Config/Base.xcconfig` sets `ENABLE_USER_SCRIPT_SANDBOXING = NO`. Librarian correctly has `YES` (Apple's recommended default). The reason for Ledger's `NO` is not documented — it's needed for build scripts that bundle ExifTool.

**Target state:** Add a comment in Ledger's `Base.xcconfig` or a note in `Engineering Baseline.md` explaining why this deviates from the default.

---

## Phase D — Release Infrastructure

Bring Librarian's release tooling up to Ledger's maturity. Independent of other phases.

### D1. Harden release_check.sh

**Current state — Librarian's release_check.sh:**
- Basic: resolves dependencies, runs `swift test | tee`, runs xcodebuild, checks warnings
- No lock file, no timeout, no stale-process detection

**Current state — Ledger's release_check.sh (the target):**
- Script-level lock file to prevent concurrent runs
- Stale SwiftPM `.build/.lock` cleanup
- Detection of active SwiftPM processes using the same scratch path
- `run_with_timeout` wrapper (default 900s) to kill hung `swift test` runs
- Dedicated `--scratch-path` for isolated SPM builds
- All of this prevents the known issue where SwiftPM locks stall release checks

**Target state:** Port Ledger's hardened patterns to Librarian's script, substituting project/scheme names.

### D2. GitHub Actions workflow for Librarian

**Current state:** Librarian has no `.github/workflows/` directory.

**Target state:** Add `.github/workflows/release.yml` matching Ledger's pattern:
- Manual trigger (workflow_dispatch)
- macOS runner, Xcode selection
- Developer ID certificate import from secrets
- Notarytool credential configuration
- Run `release.sh` (archive → notarise → DMG → notarise)
- Upload DMG artifact

**Reference:** Ledger's workflow at `.github/workflows/release.yml`.

### D3. Test infrastructure

**Current state:** Librarian has an empty `Tests/LibrarianTests/` scaffold with no test files. Ledger has 4,060 lines of tests across 6 files covering ImportMatcher, ImportSystem, AppModel, BackupManager, ExifToolCommandBuilder, MetadataValidator.

**Target state:** Not all of Librarian's code is testable yet (UI-heavy, PhotoKit-dependent). Prioritise tests for:
- Database migrations (GRDB migration correctness)
- AssetRepository queries (can test against in-memory GRDB)
- ImportMatcher / archive coordinate logic
- Any pure logic in the indexing pipeline

This is ongoing work, not a single deliverable.

---

## Execution Notes

- **Phase A** is the heavy lift and should land as one atomic change. The SPM restructure (A1), entry point (A2), bundle identifier (A3), and entitlements consolidation (A4) all modify the project definition. Privacy manifest (A5) can technically be separate but is small enough to include.
- **Phase B** and **Phase C** can be done in either order. Each item within them is an independent commit.
- **Phase D** is fully independent and can happen at any time.
- After Phase A lands, update Librarian's `DEPENDENCY_POLICY.md` to reference `Package.resolved` at root instead of nested in `.xcodeproj`.
