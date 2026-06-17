import 'dart:io';
import 'package:flutter/services.dart';

/// Wraps the native `gopeed.com/background_download` MethodChannel.
///
/// Only active on iOS. On all other platforms every method is a no-op so
/// callers don't need Platform.isIOS guards everywhere.
class IosBackgroundDownloadService {
  IosBackgroundDownloadService._();

  static final IosBackgroundDownloadService instance =
      IosBackgroundDownloadService._();

  static const _channel =
      MethodChannel('gopeed.com/background_download');

  /// id → progress callback
  final _progressHandlers = <String, void Function(double, int, int)>{};

  /// id → completion callback
  final _completeHandlers = <String, void Function(String?)>{};

  bool _initialized = false;

  void _ensureInit() {
    if (_initialized || !Platform.isIOS) return;
    _initialized = true;
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    final args = (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
    final id = args['id'] as String? ?? '';

    switch (call.method) {
      case 'onProgress':
        final progress = (args['progress'] as num).toDouble();
        final downloaded = (args['downloaded'] as num).toInt();
        final total = (args['total'] as num).toInt();
        _progressHandlers[id]?.call(progress, downloaded, total);
        break;

      case 'onComplete':
        final error = args['error'] as String?;
        _completeHandlers[id]?.call(error);
        _progressHandlers.remove(id);
        _completeHandlers.remove(id);
        break;
    }
  }

  // ── Public API ──────────────────────────────────────────────────────────────

  /// Start a background download via NSURLSession.
  ///
  /// [id]       — must match Gopeed's internal task id
  /// [url]      — direct HTTP/HTTPS download URL
  /// [filename] — display name shown in Live Activity
  /// [destPath] — final file path (absolute, inside app sandbox)
  /// [headers]  — optional request headers (e.g. Range, Authorization)
  Future<void> startDownload({
    required String id,
    required String url,
    required String filename,
    required String destPath,
    Map<String, String> headers = const {},
    required void Function(double progress, int downloaded, int total) onProgress,
    required void Function(String? error) onComplete,
  }) async {
    if (!Platform.isIOS) return;
    _ensureInit();
    _progressHandlers[id] = onProgress;
    _completeHandlers[id] = onComplete;

    await _channel.invokeMethod<void>('startDownload', {
      'id': id,
      'url': url,
      'filename': filename,
      'destPath': destPath,
      'headers': headers,
    });
  }

  Future<void> pauseDownload(String id) async {
    if (!Platform.isIOS) return;
    await _channel.invokeMethod<void>('pauseDownload', {'id': id});
  }

  Future<void> resumeDownload(
    String id, {
    required void Function(double, int, int) onProgress,
    required void Function(String?) onComplete,
  }) async {
    if (!Platform.isIOS) return;
    _ensureInit();
    _progressHandlers[id] = onProgress;
    _completeHandlers[id] = onComplete;
    await _channel.invokeMethod<void>('resumeDownload', {'id': id});
  }

  Future<void> cancelDownload(String id) async {
    if (!Platform.isIOS) return;
    _progressHandlers.remove(id);
    _completeHandlers.remove(id);
    await _channel.invokeMethod<void>('cancelDownload', {'id': id});
  }

  /// Re-attach progress/completion callbacks after the app foregrounds.
  /// Call this from AppLifecycleListener when the app resumes.
  Future<void> reattach(
    String id, {
    required void Function(double, int, int) onProgress,
    required void Function(String?) onComplete,
  }) async {
    if (!Platform.isIOS) return;
    _ensureInit();
    _progressHandlers[id] = onProgress;
    _completeHandlers[id] = onComplete;
    await _channel.invokeMethod<void>('reattach', {'id': id});
  }
}
