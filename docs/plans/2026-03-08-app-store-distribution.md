# Mac App Store Distribution — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make Parkeet distributable through the Mac App Store while preserving the global hotkey + auto-paste UX.

**Architecture:** The app keeps its current UX (global hotkey triggers recording, CGEvent pastes result). These features work inside the App Sandbox when the user manually grants Accessibility permission — same approach used by Magnet, Rectangle Pro, and other top App Store apps. The build system moves from SPM+shell scripts to a proper Xcode project with signed frameworks. The 670MB model is bundled in-app (within App Store's 4GB limit).

**Tech Stack:** Swift 5.9, SwiftUI, Xcode 15+, sherpa-onnx (static or XCFramework), App Sandbox

**Reference apps on the App Store that use Accessibility:** Magnet, Rectangle Pro, Amphetamine, Pastebot

---

## Phase 1: Sandbox & Entitlements

### Task 1.1: Add App Sandbox entitlements

**Files:**
- Modify: `ParkeetSwift/Support/Parkeet.entitlements`

**Step 1: Update entitlements file**

Replace the empty `<dict/>` with:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.device.audio-input</key>
    <true/>
    <key>com.apple.security.files.user-selected.read-only</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
</dict>
</plist>
```

Entitlements explained:
- `app-sandbox` — Required for App Store
- `device.audio-input` — Microphone for recording
- `files.user-selected.read-only` — File transcription (user picks file via NSOpenPanel)
- `network.client` — Future: model download, update checks, crash reporting

**Step 2: Verify the app still launches with sandbox enabled**

Build and run. Expect: app launches, menu bar icon appears. Hotkey and paste will NOT work yet (Accessibility not granted under sandbox). That's expected.

**Step 3: Commit**

```bash
git add ParkeetSwift/Support/Parkeet.entitlements
git commit -m "feat: add App Sandbox entitlements for App Store distribution"
```

---

### Task 1.2: Replace Accessibility auto-prompt with manual guidance

**Context:** In a sandboxed app, `AXIsProcessTrustedWithOptions` with the prompt flag does NOT show the system dialog. The app must guide the user to manually add it in System Settings. The `AXIsProcessTrusted()` check still works — only the auto-prompt is blocked.

**Files:**
- Modify: `ParkeetSwift/Sources/Parkeet/App/PermissionChecker.swift`
- Modify: `ParkeetSwift/Sources/Parkeet/UI/WelcomeView.swift`

**Step 1: Update PermissionChecker to open System Settings directly**

In `PermissionChecker.swift`, replace the `checkAccessibility()` method:

```swift
private static func checkAccessibility() -> Bool {
    if AXIsProcessTrusted() {
        return true
    }

    log.warning("Accessibility permission not granted — user must add manually in System Settings")
    return false
}

/// Open System Settings to the Accessibility privacy pane.
static func openAccessibilitySettings() {
    log.info("Opening System Settings > Accessibility")
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
        NSWorkspace.shared.open(url)
    }
}
```

Remove the `AXIsProcessTrustedWithOptions` call entirely — it's a no-op in sandbox.

**Step 2: Update WelcomeView accessibility step**

In the accessibility permission card in `WelcomeView.swift`, replace the button action that calls `AXIsProcessTrustedWithOptions` with:

```swift
Button("Open System Settings") {
    PermissionChecker.openAccessibilitySettings()
}
```

Keep the existing numbered instructions (they already say "1. Open System Settings, 2. Find Parkeet, 3. Toggle switch"). The only change is the button action — it opens System Settings instead of triggering the now-blocked native prompt.

**Step 3: Test the onboarding flow**

1. Reset onboarding: set `hasCompletedOnboarding` to false in UserDefaults
2. Launch app
3. Step through onboarding — verify Accessibility step opens System Settings
4. Toggle Accessibility permission manually
5. Verify the polling detects it and enables "Continue"

**Step 4: Commit**

```bash
git add ParkeetSwift/Sources/Parkeet/App/PermissionChecker.swift ParkeetSwift/Sources/Parkeet/UI/WelcomeView.swift
git commit -m "feat: replace Accessibility auto-prompt with manual System Settings guidance"
```

---

### Task 1.3: Move history storage to sandbox-compatible location

**Context:** Currently history is stored at `~/.config/parkeet/history.json`. Sandboxed apps cannot write outside their container (`~/Library/Containers/<bundle-id>/`). `FileManager.default.homeDirectoryForCurrentUser` returns the container path in sandbox.

**Files:**
- Modify: `ParkeetSwift/Sources/Parkeet/Model/HistoryStore.swift`

**Step 1: Update the history file path**

Replace the hardcoded `~/.config/parkeet/` path with Application Support inside the sandbox container:

```swift
private static func historyFileURL() -> URL {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    let parkeetDir = appSupport.appendingPathComponent("Parkeet")
    try? FileManager.default.createDirectory(at: parkeetDir, withIntermediateDirectories: true)
    return parkeetDir.appendingPathComponent("history.json")
}
```

This resolves to `~/Library/Containers/com.parkeet.swift/Data/Library/Application Support/Parkeet/history.json` in sandbox, or `~/Library/Application Support/Parkeet/history.json` outside sandbox. Works in both environments.

**Step 2: Add migration from old path**

On first launch, check if the old `~/.config/parkeet/history.json` exists and copy it to the new location (only works before sandbox is enforced; useful during development transition):

```swift
private static func migrateIfNeeded(to newURL: URL) {
    let oldPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/parkeet/history.json")
    if FileManager.default.fileExists(atPath: oldPath.path),
       !FileManager.default.fileExists(atPath: newURL.path) {
        try? FileManager.default.copyItem(at: oldPath, to: newURL)
    }
}
```

**Step 3: Verify history persistence**

1. Launch app, record something
2. Check that history.json appears in Application Support
3. Relaunch, verify history is loaded

**Step 4: Commit**

```bash
git add ParkeetSwift/Sources/Parkeet/Model/HistoryStore.swift
git commit -m "feat: move history storage to Application Support (sandbox-compatible)"
```

---

### Task 1.4: Verify model loading from app bundle in sandbox

**Context:** The model is loaded from `Bundle.main.resourceURL` which works fine in sandbox. The fallback paths (`#file`-based dev path and `~/.config/parkeet/models/`) won't work in sandbox. This is fine — bundled model is the production path.

**Files:**
- Modify: `ParkeetSwift/Sources/Parkeet/Transcription/Transcriber.swift`

**Step 1: Add logging to clarify which path was used**

```swift
private static func findModelDirectory() throws -> URL {
    let log = Logger(subsystem: "com.parkeet.app", category: "Transcriber")

    // 1. Check app bundle Resources (production path)
    if let bundlePath = Bundle.main.resourceURL?.appendingPathComponent("models/\(modelDirName)"),
       FileManager.default.fileExists(atPath: bundlePath.path) {
        log.info("Model found in app bundle: \(bundlePath.path)")
        return bundlePath
    }

    // 2. Development fallback (won't work in sandbox, that's OK)
    let devPath = URL(fileURLWithPath: #file)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Resources/models/\(modelDirName)")
    if FileManager.default.fileExists(atPath: devPath.path) {
        log.info("Model found at dev path: \(devPath.path)")
        return devPath
    }

    log.error("Model not found in bundle or dev path")
    throw TranscriberError.modelNotFound
}
```

Remove the `~/.config/parkeet/models/` fallback — it's inaccessible in sandbox and no longer needed.

**Step 2: Commit**

```bash
git add ParkeetSwift/Sources/Parkeet/Transcription/Transcriber.swift
git commit -m "refactor: simplify model path lookup, remove sandbox-incompatible fallback"
```

---

## Phase 2: Build System (SPM → Xcode Project)

### Task 2.1: Create static libraries or XCFramework for sherpa-onnx

**Context:** The current build uses dynamic libraries (`.dylib`) linked via `unsafeFlags` in Package.swift. App Store requires either:
- (a) Static libraries linked into the executable, or
- (b) Properly signed `.framework` bundles in Frameworks/

Static linking is simpler and avoids dylib signing issues.

**Files:**
- Modify: `ParkeetSwift/Scripts/build-sherpa-onnx.sh`

**Step 1: Update build script to produce static libraries**

Change the CMake flag from `BUILD_SHARED_LIBS=ON` to `OFF`:

```bash
cmake \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
    -DBUILD_SHARED_LIBS=OFF \
    -DSHERPA_ONNX_ENABLE_C_API=ON \
    -DSHERPA_ONNX_ENABLE_PYTHON=OFF \
    -DSHERPA_ONNX_ENABLE_PORTAUDIO=OFF \
    ..
```

This produces `libsherpa-onnx-c-api.a` and `libonnxruntime.a` instead of `.dylib`.

Also add universal binary support (`arm64;x86_64`) for App Store requirement to support both Apple Silicon and Intel Macs.

**Step 2: Rebuild sherpa-onnx**

```bash
cd ParkeetSwift
bash Scripts/build-sherpa-onnx.sh
```

Verify: `ls ../sherpa-onnx/build-swift-macos/install/lib/*.a` should show static libraries.

**Step 3: Commit**

```bash
git add ParkeetSwift/Scripts/build-sherpa-onnx.sh
git commit -m "feat: build sherpa-onnx as static libraries for App Store"
```

---

### Task 2.2: Create proper Xcode project

**Context:** SPM's `unsafeFlags` are forbidden in App Store builds. We need a proper Xcode project that links the static libraries directly. The existing `project.yml` (XcodeGen) is a good starting point but needs updates.

**Files:**
- Modify: `ParkeetSwift/project.yml`
- Create: `ParkeetSwift/Assets.xcassets/` (app icon)

**Step 1: Update project.yml for static linking and sandbox**

```yaml
name: Parkeet
options:
  bundleIdPrefix: com.parkeet
  deploymentTarget:
    macOS: "14.0"
  xcodeVersion: "15.0"

targets:
  Parkeet:
    type: application
    platform: macOS
    sources:
      - path: Sources/Parkeet
      - path: Sources/CSherpaOnnx
    resources:
      - path: Resources
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.parkeet.app
        PRODUCT_NAME: Parkeet
        INFOPLIST_FILE: Support/Info.plist
        CODE_SIGN_ENTITLEMENTS: Support/Parkeet.entitlements
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        SWIFT_OBJC_BRIDGING_HEADER: ""
        HEADER_SEARCH_PATHS:
          - "$(PROJECT_DIR)/../sherpa-onnx/build-swift-macos/install/include"
        LIBRARY_SEARCH_PATHS:
          - "$(PROJECT_DIR)/../sherpa-onnx/build-swift-macos/install/lib"
        OTHER_LDFLAGS:
          - "-lsherpa-onnx-c-api"
          - "-lonnxruntime"
          - "-lc++"
        MACOSX_DEPLOYMENT_TARGET: "14.0"
        CODE_SIGN_STYLE: Automatic
        DEVELOPMENT_TEAM: "" # Fill in with Apple Developer Team ID
        ENABLE_HARDENED_RUNTIME: YES
      configs:
        Release:
          SWIFT_OPTIMIZATION_LEVEL: "-O"
```

**Step 2: Create Assets.xcassets with AppIcon**

Create `ParkeetSwift/Assets.xcassets/AppIcon.appiconset/Contents.json` with the required icon sizes (16, 32, 128, 256, 512 @1x and @2x). For now, use a placeholder — the icon can be designed later.

**Step 3: Regenerate Xcode project**

```bash
cd ParkeetSwift
xcodegen generate
```

**Step 4: Open in Xcode, verify it builds**

```bash
open Parkeet.xcodeproj
```

Build with Cmd+B. Fix any issues.

**Step 5: Commit**

```bash
git add ParkeetSwift/project.yml ParkeetSwift/Assets.xcassets
git commit -m "feat: update Xcode project for App Store build (static linking, sandbox)"
```

---

### Task 2.3: Remove dylib bundling from run.sh

**Context:** With static linking, the Frameworks/ directory and dylib copying are no longer needed. Update `run.sh` for development builds (Xcode handles the App Store archive).

**Files:**
- Modify: `ParkeetSwift/run.sh`

**Step 1: Remove dylib copy and rpath fixup**

Remove these sections from `run.sh`:
- `cp "$SHERPA_LIB/libsherpa-onnx-c-api.dylib" "$FRAMEWORKS/"`
- `cp "$SHERPA_LIB/libonnxruntime.1.23.2.dylib" "$FRAMEWORKS/"`
- `ln -sf` symlink creation
- `install_name_tool -add_rpath` call
- `mkdir -p "$FRAMEWORKS"` (no longer needed)

The executable is now self-contained with static libraries linked in.

**Step 2: Verify development build still works**

```bash
bash run.sh
```

App should launch and work without Frameworks/ directory.

**Step 3: Commit**

```bash
git add ParkeetSwift/run.sh
git commit -m "refactor: remove dylib bundling from run.sh (now statically linked)"
```

---

## Phase 3: App Store Metadata & Packaging

### Task 3.1: Update Info.plist for App Store requirements

**Files:**
- Modify: `ParkeetSwift/Support/Info.plist`

**Step 1: Add required keys**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$(EXECUTABLE_NAME)</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$(PRODUCT_NAME)</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$(MARKETING_VERSION)</string>
    <key>CFBundleVersion</key>
    <string>$(CURRENT_PROJECT_VERSION)</string>
    <key>LSMinimumSystemVersion</key>
    <string>$(MACOSX_DEPLOYMENT_TARGET)</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Parkeet needs microphone access to record audio for speech-to-text transcription.</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright 2026 Parkeet. All rights reserved.</string>
</dict>
</plist>
```

Key additions:
- `LSApplicationCategoryType` — Required for App Store (Productivity category)
- `NSHumanReadableCopyright` — Shown in Finder "Get Info"
- Xcode variables (`$(EXECUTABLE_NAME)`, `$(MARKETING_VERSION)`, etc.) replace hardcoded values so Xcode manages versioning

**Step 2: Commit**

```bash
git add ParkeetSwift/Support/Info.plist
git commit -m "feat: update Info.plist with App Store required keys and Xcode variables"
```

---

### Task 3.2: Add privacy manifest (required since Spring 2024)

**Context:** Apple requires a `PrivacyInfo.xcprivacy` file for all App Store apps. It declares what data the app collects and what APIs it uses.

**Files:**
- Create: `ParkeetSwift/Support/PrivacyInfo.xcprivacy`

**Step 1: Create privacy manifest**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>NSPrivacyTracking</key>
    <false/>
    <key>NSPrivacyTrackingDomains</key>
    <array/>
    <key>NSPrivacyCollectedDataTypes</key>
    <array/>
    <key>NSPrivacyAccessedAPITypes</key>
    <array>
        <dict>
            <key>NSPrivacyAccessedAPIType</key>
            <string>NSPrivacyAccessedAPICategoryUserDefaults</string>
            <key>NSPrivacyAccessedAPITypeReasons</key>
            <array>
                <string>CA92.1</string>
            </array>
        </dict>
        <dict>
            <key>NSPrivacyAccessedAPIType</key>
            <string>NSPrivacyAccessedAPICategoryFileTimestamp</string>
            <key>NSPrivacyAccessedAPITypeReasons</key>
            <array>
                <string>C617.1</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
```

This declares:
- No tracking
- No data collection (everything stays on-device)
- Uses UserDefaults (for settings) and file timestamps (for history purge)

**Step 2: Add to Xcode project resources**

Add `PrivacyInfo.xcprivacy` to the resources section in `project.yml`.

**Step 3: Commit**

```bash
git add ParkeetSwift/Support/PrivacyInfo.xcprivacy ParkeetSwift/project.yml
git commit -m "feat: add privacy manifest for App Store requirement"
```

---

## Phase 4: Apple Developer Account Setup (Manual Steps)

These are manual steps that cannot be automated. Document them here for reference.

### Task 4.1: Apple Developer Program enrollment

1. Go to https://developer.apple.com/programs/enroll/
2. Enroll as Individual ($99/year)
3. Wait for approval (usually 24-48 hours)
4. Note your **Team ID** (shown in Membership section of developer portal)

### Task 4.2: App Store Connect setup

1. Go to https://appstoreconnect.apple.com
2. Create new app:
   - Platform: macOS
   - Name: Parkeet
   - Bundle ID: `com.parkeet.app` (register this in Certificates, Identifiers & Profiles first)
   - SKU: `parkeet-macos`
   - Primary language: English
3. Fill in required metadata:
   - Description, keywords, screenshots
   - Privacy policy URL (required)
   - Category: Productivity
   - Price: set pricing tier

### Task 4.3: Code signing setup in Xcode

1. Open `Parkeet.xcodeproj` in Xcode
2. Select the Parkeet target → Signing & Capabilities
3. Check "Automatically manage signing"
4. Select your Team from the dropdown
5. Xcode will create provisioning profiles and certificates automatically

---

## Phase 5: Archive & Submit

### Task 5.1: Create release archive

**Step 1: Set version numbers**

In Xcode, set:
- `MARKETING_VERSION` = `2.0.0` (shown to users)
- `CURRENT_PROJECT_VERSION` = `1` (build number, increment with each submission)

**Step 2: Archive**

In Xcode:
1. Select "Any Mac" as destination
2. Product → Archive
3. Wait for build to complete

**Step 3: Validate**

In Xcode Organizer:
1. Select the archive
2. Click "Validate App"
3. Fix any issues reported

Common validation issues to watch for:
- Missing icon sizes in asset catalog
- Unsigned frameworks (shouldn't happen with static linking)
- Missing privacy manifest
- Bundle ID mismatch with App Store Connect

**Step 4: Distribute**

1. Click "Distribute App"
2. Select "App Store Connect"
3. Upload
4. Go to App Store Connect → TestFlight to test the build
5. Submit for review when ready

---

## Phase 6: Universal Binary Support

### Task 6.1: Ensure Intel Mac compatibility

**Context:** App Store requires universal binaries (arm64 + x86_64) unless you explicitly opt out. The sherpa-onnx libraries must be built for both architectures.

**Files:**
- Modify: `ParkeetSwift/Scripts/build-sherpa-onnx.sh`

**Step 1: Build for both architectures**

Already addressed in Task 2.1 with `-DCMAKE_OSX_ARCHITECTURES="arm64;x86_64"`. Verify with:

```bash
lipo -info ../sherpa-onnx/build-swift-macos/install/lib/libsherpa-onnx-c-api.a
```

Expected output: `Architectures in the fat file: arm64 x86_64`

**Step 2: Verify Xcode builds universal binary**

In Xcode build settings, ensure `ARCHS = $(ARCHS_STANDARD)` which includes both arm64 and x86_64 on macOS.

**Step 3: Commit any changes**

---

## Summary of Changes

| Area | Current | After |
|------|---------|-------|
| Sandbox | None (empty entitlements) | Full sandbox with mic, files, network |
| Accessibility prompt | Auto-prompt via AXIsProcessTrustedWithOptions | Manual guidance → open System Settings |
| History storage | `~/.config/parkeet/` | `~/Library/Application Support/Parkeet/` |
| Model fallback paths | Bundle + dev path + ~/.config | Bundle only (+ dev path for debug) |
| Library linking | Dynamic (.dylib) + unsafeFlags | Static (.a) via Xcode project |
| Code signing | Self-signed "Parkeet Dev" | Apple Developer certificate (automatic) |
| Info.plist | Hardcoded values | Xcode build variables |
| Privacy manifest | None | PrivacyInfo.xcprivacy |
| Architecture | arm64 only | Universal (arm64 + x86_64) |

## Risks & Mitigations

1. **App Review may question Accessibility usage** — Prepare a demo video showing the hotkey+paste workflow. Include a note in the review notes explaining why Accessibility is needed (same as Magnet, Rectangle).

2. **670MB app size** — Large for a utility app but within App Store limits. Consider offering on-demand model download in a future version to reduce initial download.

3. **sherpa-onnx static build may have issues on x86_64** — Test thoroughly on Intel Mac or Rosetta. If onnxruntime doesn't support static x86_64, consider arm64-only (Apple Silicon) as initial release.

4. **Model in app bundle doubles archive size** — Xcode archives compress with App Thinning. The ONNX model may not compress well. Test final `.ipa` size.
