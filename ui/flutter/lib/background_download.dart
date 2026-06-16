import 'dart:async';
import 'package:flutter/services.dart';

/// Service for managing background downloads on iOS
class BackgroundDownloadService {
  static const platform =
      MethodChannel('com.gopeed.app/background_download');

  /// Initialize background download support
  static Future<void> initializeBackgroundDownloads() async {
    try {
      await platform.invokeMethod('initializeBackgroundDownloads');
      print('Background downloads initialized');
    } on PlatformException catch (e) {
      print('Failed to initialize background downloads: ${e.message}');
    }
  }

  /// Start a background download task
  static Future<bool> startBackgroundDownload(String taskId) async {
    try {
      final result = await platform.invokeMethod<bool>(
        'startBackgroundDownload',
        {'taskId': taskId},
      );
      return result ?? false;
    } on PlatformException catch (e) {
      print('Failed to start background download: ${e.message}');
      return false;
    }
  }

  /// Resume all paused downloads in background
  static Future<bool> resumeAllBackgroundDownloads() async {
    try {
      final result = await platform.invokeMethod<bool>(
        'resumeAllBackgroundDownloads',
      );
      return result ?? false;
    } on PlatformException catch (e) {
      print('Failed to resume background downloads: ${e.message}');
      return false;
    }
  }

  /// Check if downloads are active in background
  static Future<bool> isDownloadActive() async {
    try {
      final result = await platform.invokeMethod<bool>(
        'isDownloadActive',
      );
      return result ?? false;
    } on PlatformException catch (e) {
      print('Failed to check download activity: ${e.message}');
      return false;
    }
  }

  /// Schedule background download task
  static Future<void> scheduleBackgroundDownloadTask() async {
    try {
      await platform.invokeMethod('scheduleBackgroundDownloadTask');
      print('Background download task scheduled');
    } on PlatformException catch (e) {
      print('Failed to schedule background task: ${e.message}');
    }
  }

  /// Handle app lifecycle - app entered background
  static Future<void> onAppBackground() async {
    try {
      await platform.invokeMethod('onAppBackground');
    } on PlatformException catch (e) {
      print('Error handling app background: ${e.message}');
    }
  }

  /// Handle app lifecycle - app entered foreground
  static Future<void> onAppForeground() async {
    try {
      await platform.invokeMethod('onAppForeground');
    } on PlatformException catch (e) {
      print('Error handling app foreground: ${e.message}');
    }
  }
}
