# iOS Background Download Implementation Guide

This document provides a comprehensive guide to the iOS background download functionality added to Gopeed.

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Components](#components)
4. [How It Works](#how-it-works)
5. [Integration](#integration)
6. [Testing](#testing)
7. [Troubleshooting](#troubleshooting)
8. [Best Practices](#best-practices)
9. [iOS Requirements](#ios-requirements)
10. [Future Enhancements](#future-enhancements)

## Overview

The iOS background download feature allows the Gopeed app to continue downloading files even when the app is backgrounded or the user switches to another app. This is achieved using iOS's [BackgroundTasks](https://developer.apple.com/documentation/backgroundtasks) framework, which provides two types of background tasks:

- **BGAppRefreshTask**: For periodic, lightweight tasks (runs for ~30 seconds)
- **BGProcessingTask**: For longer-running work without power requirement (runs for ~30 minutes)

## Architecture

### High-Level Flow

```
┌─────────────────────────────────────────────────────────┐
│                    iOS System                            │
│  ├─ BGAppRefreshTask (periodic refresh)                │
│  └─ BGProcessingTask (longer processing)               │
└──────────────────────┬──────────────────────────────────┘
                       │ Triggers every N minutes
                       ▼
┌─────────────────────────────────────────────────────────┐
│            BackgroundDownloadHandler (Swift)            │
│  ├─ registerBackgroundTasks()                          │
│  ├─ scheduleBackgroundDownloadTask()                   │
│  ├─ handleBackgroundDownload()                         │
│  ├─ handleBackgroundProcessing()                       │
│  └─ resumeAllBackgroundDownloads()                     │
└──────────────────────┬──────────────────────────────────┘
                       │ MethodChannel
                       ▼
┌─────────────────────────────────────────────────────────┐
│           BackgroundDownloadService (Dart)             │
│  ├─ initializeBackgroundDownloads()                    │
│  ├─ resumeAllBackgroundDownloads()                     │
│  ├─ isDownloadActive()                                 │
│  ├─ scheduleBackgroundDownloadTask()                   │
│  ├─ onAppBackground()                                  │
│  └─ onAppForeground()                                  │
└──────────────────────┬──────────────────────────────────┘
                       │ Go FFI/JNI
                       ▼
┌─────────────────────────────────────────────────────────┐
│         BackgroundDownloadManager (Go)                  │
│  ├─ ResumeBackgroundDownloads()                        │
│  ├─ IsDownloadActive()                                 │
│  ├─ GetActiveTasksCount()                              │
│  ├─ GetPausedTasksCount()                              │
│  └─ PauseAllDownloads()                                │
└──────────────────────┬──────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────┐
│             Download Engine (pkg/download)             │
│  ├─ GetTasks()                                         │
│  ├─ Continue(taskID)                                   │
│  ├─ Pause(taskID)                                      │
│  └─ Download logic                                     │
└─────────────────────────────────────────────────────────┘
```

## Components

### 1. Dart Layer: `ui/flutter/lib/background_download.dart`

Provides a Dart interface to the native iOS background functionality.

**Key Classes:**
- `BackgroundDownloadService` - Static service class with platform channel methods

**Key Methods:**
- `initializeBackgroundDownloads()` - Initialize background support on app start
- `startBackgroundDownload(taskId)` - Start specific background download
- `resumeAllBackgroundDownloads()` - Resume all paused downloads
- `isDownloadActive()` - Check if any downloads are currently active
- `scheduleBackgroundDownloadTask()` - Schedule background task
- `onAppBackground()` - Called when app enters background
- `onAppForeground()` - Called when app enters foreground

**Platform Channel:** `com.gopeed.app/background_download`

### 2. Swift Layer: `ui/flutter/ios/Runner/BackgroundDownloadHandler.swift`

Handles iOS background task registration and execution.

**Key Components:**
- `backgroundTaskIdentifier` - Identifier for BGAppRefreshTask
- `backgroundProcessingIdentifier` - Identifier for BGProcessingTask
- `registerBackgroundTasks()` - Register both task types with iOS
- `handleBackgroundDownload()` - Handle refresh task execution
- `handleBackgroundProcessing()` - Handle processing task execution
- `resumeAllBackgroundDownloads()` - Call Go backend to resume downloads
- `isDownloadActive()` - Check if downloads are active

**Task Identifiers:**
- `com.gopeed.background.download` - App refresh task
- `com.gopeed.background.processing` - Processing task

### 3. Swift Extension: `ui/flutter/ios/Runner/GeneratedPluginRegistrant+Background.swift`

Sets up the method channel between Dart and Swift.

**Method Channel Methods:**
- `initializeBackgroundDownloads` - Register background tasks
- `scheduleBackgroundDownloadTask` - Schedule next background task
- `onAppBackground` - Handle app backgrounding
- `onAppForeground` - Handle app foregrounding
- `isDownloadActive` - Check active downloads

### 4. Go Backend: `bind/mobile/background.go`

Manages the download operations from the Go side.

**Key Types:**
- `BackgroundDownloadManager` - Manager for background operations

**Key Methods:**
- `NewBackgroundDownloadManager(engine)` - Create new manager
- `ResumeBackgroundDownloads()` - Resume all paused tasks
- `IsDownloadActive()` - Check for active downloads
- `GetActiveTasksCount()` - Get count of active tasks
- `GetPausedTasksCount()` - Get count of paused tasks
- `PauseAllDownloads()` - Pause all active downloads

### 5. Mobile Exports: `bind/mobile/background_mobile.go`

Mobile-specific exports and singleton management.

**Exported Functions:**
- `InitializeBackgroundDownloads()` - Initialize manager
- `ResumeAllBackgroundDownloads()` - Resume all downloads
- `IsDownloadActiveBackground()` - Check active status
- `GetActiveTaskCountBackground()` - Get active task count
- `PauseAllDownloadsBackground()` - Pause all downloads

### 6. Updated Files

**`ui/flutter/ios/Runner/AppDelegate.swift`**
- Initializes background download on app launch
- Handles app lifecycle events
- Sets up method channel communication

**`ui/flutter/ios/Runner/Info.plist`**
- Added `UIBackgroundModes` configuration
- Enables `fetch` and `processing` background modes

## How It Works

### Initialization Flow

```
App Launch
    ↓
AppDelegate.application(didFinishLaunchingWithOptions:)
    ↓
GeneratedPluginRegistrant.setupBackgroundDownloadChannel()
    ↓
BackgroundDownloadHandler.registerBackgroundTasks()
    ↓
BGTaskScheduler registers both task types
    ↓
Background support ready
```

### Runtime Flow

```
┌─ App Running ──────────────────────────────┐
│                                             │
│  User starts download                       │
│  Download begins immediately                │
│                                             │
└─────────────────┬───────────────────────────┘
                  │
                  ▼
┌─ User Backgrounds App ─────────────────────┐
│                                             │
│  applicationDidEnterBackground()            │
│  BackgroundDownloadHandler.onAppBackground()│
│  isDownloadActive()? YES                    │
│  → Schedule BGAppRefreshTask                │
│  → Schedule BGProcessingTask                │
│                                             │
└─────────────────┬───────────────────────────┘
                  │
                  ▼
┌─ iOS Wakes App for Background Task ────────┐
│                                             │
│  iOS launches app in background             │
│  Calls handleBackgroundDownload()           │
│  Calls handleBackgroundProcessing()         │
│                                             │
│  Swift Handler:                             │
│  → resumeAllBackgroundDownloads()           │
│  → Invokes platform channel method          │
│                                             │
│  Dart Layer:                                │
│  → Receives method call                     │
│  → Calls Go backend                         │
│                                             │
│  Go Backend:                                │
│  → ResumeAllBackgroundDownloads()           │
│  → Gets all paused tasks                    │
│  → Calls engine.Continue(taskID)            │
│  → Returns success/failure                  │
│                                             │
│  Task completes with status                 │
│  System schedules next background task      │
│                                             │
└─────────────────┬───────────────────────────┘
                  │
                  ▼
┌─ User Brings App to Foreground ────────────┐
│                                             │
│  applicationWillEnterForeground()           │
│  BackgroundDownloadHandler.onAppForeground()│
│  BGTaskScheduler.cancelAllTaskRequests()    │
│  App continues normal operation             │
│                                             │
└─────────────────────────────────────────────┘
```

### Timeout Management

- **BGAppRefreshTask**: ~30 seconds runtime
- **BGProcessingTask**: ~30 minutes runtime
- **Swift Safety Margin**: 25 seconds timeout to ensure proper cleanup
- **Semaphore Waits**: Coordinated using DispatchSemaphore for thread safety

## Integration

### 1. Enable Background Modes in Xcode

```
Project → Target → Signing & Capabilities
  → + Capability
  → Background Modes
    ✓ Background fetch
    ✓ Background processing
```

### 2. Initialize on App Startup

```dart
import 'package:gopeed/background_download.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize background downloads on iOS
  BackgroundDownloadService.initializeBackgroundDownloads();
  
  runApp(const MyApp());
}
```

### 3. Handle App Lifecycle

```dart
import 'package:flutter/material.dart';
import 'package:gopeed/background_download.dart';

class MyApp extends StatefulWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
        BackgroundDownloadService.onAppBackground();
        break;
      case AppLifecycleState.resumed:
        BackgroundDownloadService.onAppForeground();
        break;
      default:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Gopeed',
      home: const HomePage(),
    );
  }
}
```

## Testing

### Unit Tests

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:gopeed/background_download.dart';

void main() {
  group('BackgroundDownloadService', () {
    test('initializeBackgroundDownloads completes', () async {
      await BackgroundDownloadService.initializeBackgroundDownloads();
      // Should complete without throwing
    });

    test('isDownloadActive returns bool', () async {
      final result = await BackgroundDownloadService.isDownloadActive();
      expect(result, isA<bool>());
    });

    test('resumeAllBackgroundDownloads returns bool', () async {
      final result = await BackgroundDownloadService.resumeAllBackgroundDownloads();
      expect(result, isA<bool>());
    });
  });
}
```

### Integration Tests on Device

1. **Build and Run on iOS Device**
   ```bash
   cd ui/flutter
   flutter run -v
   ```

2. **Test Background Download**
   - Start a large download
   - Press home button to background app
   - Wait 30+ seconds (allow background task execution)
   - Reopen app
   - Verify download progress continued

3. **Test Multiple Downloads**
   - Start 3+ downloads
   - Background app
   - Return to foreground
   - Verify all resumed correctly

4. **Test Network Interruption**
   - Start download
   - Background app
   - Disable WiFi/cellular
   - Wait for timeout
   - Re-enable network
   - Verify recovery

5. **Check Console Logs**
   ```
   [Background] Download task scheduled
   [Background] Attempting to resume downloads
   [Background] Resumed task: <task-id>
   ```

## Troubleshooting

### Background Tasks Not Running

**Check:**
1. `UIBackgroundModes` in `Info.plist` includes `fetch` and `processing`
2. Background Modes capability enabled in Xcode
3. Running on iOS 13+ device (simulator may not support)
4. App not in low power mode (can prevent background tasks)

**Solution:**
```swift
// Add to Info.plist
<key>UIBackgroundModes</key>
<array>
    <string>fetch</string>
    <string>processing</string>
</array>
```

### Downloads Stop After App Background

**Check:**
1. Verify `onAppBackground()` is being called
2. Check `isDownloadActive()` returns true
3. Verify Go backend is initialized
4. Check download engine is not paused

**Debug:**
```swift
// Add to BackgroundDownloadHandler
print("[Background] App backgrounded, active downloads: \(isDownloadActive())")
```

### Method Channel Errors

**Error:** `MissingPluginException`

**Solution:**
1. Ensure `GeneratedPluginRegistrant+Background.swift` is included
2. Check `AppDelegate.swift` calls `setupBackgroundDownloadChannel()`
3. Verify channel name matches: `com.gopeed.app/background_download`
4. Run `flutter clean` and rebuild

### Go Backend Not Responding

**Check:**
1. `engine` variable is initialized
2. `backgroundDownloadMgr` is not nil
3. Download engine methods are available

**Solution:**
```go
if engine == nil {
    log.Println("[Background] Download engine not initialized")
    return false
}
```

## Best Practices

### 1. Initialize Early
```dart
// ✓ Good: Initialize in main()
future: BackgroundDownloadService.initializeBackgroundDownloads(),

// ✗ Bad: Initialize in widget build()
build(context) {
  BackgroundDownloadService.initializeBackgroundDownloads(); // Called repeatedly!
}
```

### 2. Handle Errors Gracefully
```dart
// ✓ Good: Catch exceptions
try {
  await BackgroundDownloadService.resumeAllBackgroundDownloads();
} catch (e) {
  print('Resume failed: $e');
}

// ✗ Bad: Ignore errors
await BackgroundDownloadService.resumeAllBackgroundDownloads();
```

### 3. Use Appropriate Task Type
- **BGAppRefreshTask** - Check status, quick operations
- **BGProcessingTask** - Sustained downloads (recommended)

### 4. Respect Timeouts
```swift
// ✓ Good: 25s timeout (5s safety margin from 30s limit)
semaphore.wait(timeout: .now() + 25)

// ✗ Bad: Excessive timeout
semaphore.wait(timeout: .now() + 60) // May get terminated
```

### 5. Log Appropriately
```swift
// ✓ Good: Use consistent tagging
print("[Background] Download task scheduled")
print("[Background] Resumed task: \(taskID)")

// ✗ Bad: Unclear logs
print("Task scheduled") // What task?
print("Task ID: \(taskID)") // Missing context
```

## iOS Requirements

| Requirement | Details |
|-------------|---------|
| **Minimum iOS** | 13.0 |
| **Target SDK** | iOS 13.0+ |
| **Background Modes** | `fetch`, `processing` |
| **Capabilities** | Background Fetch, Background Processing |
| **Permissions** | None additional (uses standard download) |
| **Network** | WiFi or Cellular |

## Future Enhancements

1. **Per-Download Scheduling**
   - Schedule individual background tasks for each download
   - Better resource management

2. **User Notifications**
   - Background download completion notifications
   - Status updates via local notifications

3. **Download Prioritization**
   - Priority-based resume order
   - Smart scheduling based on task priority

4. **Low Power Mode Integration**
   - Detect iOS Low Power Mode
   - Adjust behavior accordingly

5. **Offline Support**
   - Queue downloads for later execution
   - Resume when network available

6. **Analytics**
   - Track background execution statistics
   - Monitor success/failure rates

7. **User Configuration**
   - Settings to enable/disable background downloads
   - Bandwidth throttling options

8. **Cross-Platform Consistency**
   - Apply similar features to Android
   - Unified background download API

---

**For Questions or Issues:**
- Check [Troubleshooting](#troubleshooting) section
- Review iOS [BackgroundTasks](https://developer.apple.com/documentation/backgroundtasks) documentation
- Consult Gopeed [development guide](https://gopeed.com/docs/develop)
- Search existing GitHub issues
