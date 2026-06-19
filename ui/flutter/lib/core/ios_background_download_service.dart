import 'dart:io';
import 'package:flutter/services.dart';

/// iOS background download coordinator.
///
/// The Go engine does all HTTP work. This service:
///  1. Passes the Go engine's TCP port to Swift so the native polling timer
///     can call /api/v1/tasks directly from Swift while the app is backgrounded.
///  2. Starts AVAudioSession keep-alive + Live Activity when a download registers.
///  3. Forwards progress to Live Activity while the app is foregrounded.
///
/// No-op on non-iOS platforms.
class IosBackgroundDownloadService {
  IosBackgroundDownloadService._();
  static final instance = IosBackgroundDownloadService._();

  static const _ch = MethodChannel('gopeed.com/background_download');

  bool _initialized = false;

  void _ensureInit() {
    if (_initialized || !Platform.isIOS) return;
    _initialized = true;
    _ch.setMethodCallHandler(_handleNative);
  }

  Future<dynamic> _handleNative(MethodCall call) async {
    // Native→Flutter callbacks are not needed in the current architecture
    // (Swift polls Go directly). Kept for future use.
  }

  /// Call once after the Go engine starts so Swift knows the TCP port.
  Future<void> configureGoEngine({
    required int port,
    required String apiToken,
  }) async {
    if (!Platform.isIOS) return;
    _ensureInit();
    await _ch.invokeMethod<void>('configureGoEngine', {
      'port': port,
      'apiToken': apiToken,
    });
  }

  /// Call when a download task starts.
  /// Starts AVAudioSession keep-alive + Live Activity.
  Future<void> registerDownload({
    required String id,
    required String filename,
  }) async {
    if (!Platform.isIOS) return;
    _ensureInit();
    await _ch.invokeMethod<void>('registerDownload', {
      'id': id,
      'filename': filename,
    });
  }

  /// Forward a progress update while the app is foregrounded.
  /// (Swift's native timer handles this when backgrounded.)
  Future<void> updateProgress(
    String id, {
    required double progress,
    required int downloaded,
    required int total,
  }) async {
    if (!Platform.isIOS) return;
    await _ch.invokeMethod<void>('updateProgress', {
      'id': id,
      'progress': progress,
      'downloaded': downloaded,
      'total': total,
    });
  }

  /// Call when the Go engine finishes a task (success or error).
  Future<void> completeDownload(String id, {String? error}) async {
    if (!Platform.isIOS) return;
    await _ch.invokeMethod<void>('completeDownload', {
      'id': id,
      if (error != null) 'error': error,
    });
  }

  Future<void> cancelDownload(String id) async {
    if (!Platform.isIOS) return;
    await _ch.invokeMethod<void>('cancelDownload', {'id': id});
  }

  Future<void> reattach(String id) async {
    if (!Platform.isIOS) return;
    _ensureInit();
    await _ch.invokeMethod<void>('reattach', {'id': id});
  }
}
