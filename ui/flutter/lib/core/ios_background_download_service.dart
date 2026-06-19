import 'dart:io';
import 'package:flutter/services.dart';

/// iOS background download coordinator.
///
/// The Go engine does all HTTP work. This service:
/// 1. Tells native to start keep-alive (AVAudioSession + BGTask) when a download starts
/// 2. Forwards progress events to native for Live Activity updates
/// 3. Tells native when a download finishes so resources are released
///
/// On non-iOS platforms every method is a no-op.
class IosBackgroundDownloadService {
  IosBackgroundDownloadService._();
  static final instance = IosBackgroundDownloadService._();

  static const _channel = MethodChannel('gopeed.com/background_download');

  final _progressHandlers = <String, void Function(double, int, int)>{};
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
        _progressHandlers[id]?.call(
          (args['progress'] as num).toDouble(),
          (args['downloaded'] as num).toInt(),
          (args['total'] as num).toInt(),
        );
        break;
      case 'onComplete':
        final error = args['error'] as String?;
        _completeHandlers[id]?.call(error);
        _progressHandlers.remove(id);
        _completeHandlers.remove(id);
        break;
    }
  }

  /// Called when a download task starts.
  /// Starts keep-alive + Live Activity. Go engine handles the actual download.
  Future<void> registerDownload({
    required String id,
    required String filename,
    void Function(double, int, int)? onProgress,
    void Function(String?)? onComplete,
  }) async {
    if (!Platform.isIOS) return;
    _ensureInit();
    if (onProgress != null) _progressHandlers[id] = onProgress;
    if (onComplete != null) _completeHandlers[id] = onComplete;
    await _channel.invokeMethod<void>('registerDownload', {
      'id': id,
      'filename': filename,
    });
  }

  /// Forward a progress update to native (for Live Activity).
  /// Call this from your existing download progress polling.
  Future<void> updateProgress(
    String id, {
    required double progress,
    required int downloaded,
    required int total,
  }) async {
    if (!Platform.isIOS) return;
    await _channel.invokeMethod<void>('updateProgress', {
      'id': id,
      'progress': progress,
      'downloaded': downloaded,
      'total': total,
    });
  }

  /// Called when the Go engine finishes a download (success or error).
  Future<void> completeDownload(String id, {String? error}) async {
    if (!Platform.isIOS) return;
    _progressHandlers.remove(id);
    _completeHandlers.remove(id);
    await _channel.invokeMethod<void>('completeDownload', {
      'id': id,
      if (error != null) 'error': error,
    });
  }

  /// Cancel — stops keep-alive for this download.
  Future<void> cancelDownload(String id) async {
    if (!Platform.isIOS) return;
    _progressHandlers.remove(id);
    _completeHandlers.remove(id);
    await _channel.invokeMethod<void>('cancelDownload', {'id': id});
  }

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
