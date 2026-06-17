# iOS Background Downloading + Live Activities

This document explains every file added/changed and the exact steps to integrate them.

---

## Files in this patch

```
scripts/
  patch_pbxproj.py              ← Run once to wire Xcode project (no Xcode needed)

.github/workflows/
  ios-background.yml            ← GitHub Actions: builds unsigned IPA on Mac runner

ios/
  Shared/
    DownloadActivityAttributes.swift   ← ActivityKit data model (shared by Runner + widget)
  Runner/
    AppDelegate.swift           ← REPLACES existing file — adds background download channel
    BackgroundDownloadManager.swift    ← NSURLSession background session manager
    LiveActivityBridge.swift    ← Starts/updates/ends Live Activities
  GopeedWidgets/                ← NEW widget extension target
    GopeedDownloadWidget.swift  ← Lock Screen + Dynamic Island UI
    GopeedWidgetsBundle.swift   ← Extension entry point
    Info.plist                  ← Extension bundle info

lib/core/
  ios_background_download_service.dart    ← Dart ↔ native channel wrapper
  ios_background_download_lifecycle.dart  ← Re-attaches callbacks on app foreground
```

---

## Step 1 — Copy files into your repo

### Swift files (copy from `ios/` into `ui/flutter/ios/`)

```
ui/flutter/ios/Shared/DownloadActivityAttributes.swift   ← create this folder
ui/flutter/ios/Runner/BackgroundDownloadManager.swift
ui/flutter/ios/Runner/LiveActivityBridge.swift
ui/flutter/ios/Runner/AppDelegate.swift                  ← replaces existing
ui/flutter/ios/Runner/Info.plist                         ← replaces existing
ui/flutter/ios/GopeedWidgets/GopeedDownloadWidget.swift  ← create this folder
ui/flutter/ios/GopeedWidgets/GopeedWidgetsBundle.swift
ui/flutter/ios/GopeedWidgets/Info.plist
```

### Dart files (copy from `lib/core/` into `ui/flutter/lib/core/`)

```
ui/flutter/lib/core/ios_background_download_service.dart
ui/flutter/lib/core/ios_background_download_lifecycle.dart
```

### Script and workflow

```
scripts/patch_pbxproj.py   ← create scripts/ folder at repo root
.github/workflows/ios-background.yml
```

---

## Step 2 — Run the pbxproj patcher

From your **repo root** (requires Python 3, no extra packages):

```bash
python3 scripts/patch_pbxproj.py
```

This edits `ui/flutter/ios/Runner.xcodeproj/project.pbxproj` to:
- Register all new Swift files in the Runner target
- Add the `GopeedWidgets` widget extension target
- Wire the embed phase so the extension is bundled inside the app

It is **idempotent** — safe to run multiple times.

---

## Step 3 — Hook into Gopeed's download flow (Dart)

### 3a. Register `IosDownloadProgressBus` in your app binding

In `ui/flutter/lib/app/modules/app/bindings/app_binding.dart`, add:

```dart
import '../../../../core/ios_background_download_lifecycle.dart';

// inside AppBinding.dependencies():
Get.put(IosDownloadProgressBus());
```

### 3b. Start the lifecycle listener

In `app_controller.dart`, inside `onReady()`, add after existing init calls:

```dart
import '../../../../core/ios_background_download_lifecycle.dart';

// at the end of onReady():
if (Platform.isIOS) {
  IosBackgroundDownloadLifecycle.instance.init();
}
```

And in `onClose()`:

```dart
IosBackgroundDownloadLifecycle.instance.dispose();
```

### 3c. Route HTTP downloads through NSURLSession on iOS

Find where Gopeed creates/starts HTTP download tasks. This is typically in the
`create` module controller. On iOS, after the Go engine returns a task ID and
the resolved direct URL, add:

```dart
import 'dart:io';
import '../../../../core/ios_background_download_service.dart';

// After getting taskId + directUrl + destPath from the Go engine:
if (Platform.isIOS) {
  await IosBackgroundDownloadService.instance.startDownload(
    id: taskId,          // Gopeed's task id string
    url: directUrl,      // resolved HTTP/HTTPS direct download URL
    filename: filename,  // shown in Live Activity
    destPath: destPath,  // absolute path inside app Documents
    headers: headers,    // any required headers (Range, Auth, etc.)
    onProgress: (progress, downloaded, total) {
      // update your existing task state here
      // e.g. Get.find<IosDownloadProgressBus>().emit(taskId, progress, downloaded, total);
    },
    onComplete: (error) {
      if (error == null) {
        // mark task done in Go engine via API
      } else {
        // mark task failed
      }
    },
  );
}
```

> **BitTorrent / Magnet:** These use the Go engine's custom protocol stack and
> cannot be routed through NSURLSession. They will still stop when the app is
> backgrounded. Background BT would require a separate `BGProcessingTask`
> approach — out of scope here.

---

## Step 4 — Push and let GitHub Actions build

```bash
git add .
git commit -m "feat(ios): background downloading + Live Activities"
git push
```

The `ios-background.yml` workflow triggers on push to main/master.
It runs on a **free GitHub-hosted macOS runner** (no cost, no local Mac needed).

When it completes (~15–20 min), download the IPA from the **Artifacts** tab
in your Actions run and sideload with LiveContainer, AltStore, or Sideloadly.

---

## How it works

```
┌─────────────────────────────────────────────────────────────────┐
│  User taps Download                                             │
│      ↓                                                          │
│  Flutter/Dart (IosBackgroundDownloadService)                    │
│      ↓  MethodChannel "gopeed.com/background_download"          │
│  AppDelegate.swift  →  BackgroundDownloadManager                │
│                             ↓                                   │
│                    NSURLSession (background config)             │
│                    ─── app goes to background ───               │
│                    iOS OS continues download in system process  │
│                             ↓                                   │
│             LiveActivityBridge → ActivityKit → Dynamic Island   │
│                         Lock Screen UI updates every ~1s        │
│                             ↓                                   │
│             Download completes → OS wakes app                   │
│             AppDelegate.handleEventsForBackgroundURLSession      │
│             fires completionHandler → Go engine marks done      │
└─────────────────────────────────────────────────────────────────┘
```

---

## Platform requirements

| Feature | Minimum iOS |
|---------|------------|
| NSURLSession background download | iOS 7+ |
| Live Activities (Lock Screen) | iOS 16.1+ |
| Dynamic Island | iPhone 14 Pro+ (iOS 16.1+) |
| Frequent Live Activity updates | iOS 16.2+ |

Your iPhone 16 Pro Max gets all features. Older devices still get background
downloading; they just won't see Dynamic Island (Lock Screen still works on 16.1+).

---

## Troubleshooting

**Build error: `DownloadActivityAttributes` not found in widget extension**
→ Make sure `DownloadActivityAttributes.swift` is added to BOTH the Runner
  and GopeedWidgets targets. The pbxproj patcher does this via separate fileRefs
  pointing to `Shared/DownloadActivityAttributes.swift`.

**Live Activity doesn't appear**
→ Check Settings → Gopeed → Live Activities is ON.
→ Ensure `NSSupportsLiveActivities = YES` in Info.plist (included in this patch).

**Download stops after ~30 seconds in background**
→ The app is likely missing the `fetch` Background Mode entitlement.
  The patched `Info.plist` adds `UIBackgroundModes` with `fetch` and `processing`.
  Make sure Xcode's Signing & Capabilities also has Background Modes enabled
  (this is a capability toggle, not just a plist key — the CI workflow handles
  it automatically via the entitlement file).

**"No resume data" error on resume**
→ The task was cancelled rather than paused. Call `pauseDownload` (not cancel)
  to store resume data in UserDefaults.
