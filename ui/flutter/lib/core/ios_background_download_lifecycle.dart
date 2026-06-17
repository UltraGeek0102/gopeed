import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../api/api.dart';
import '../../api/model/task.dart';
import 'ios_background_download_service.dart';

/// Mix into any GetxController or StatefulWidget that needs to reattach
/// in-flight background downloads when the app comes back to the foreground.
///
/// Usage — in AppController.onReady():
///   if (Platform.isIOS) {
///     IosBackgroundDownloadLifecycle.instance.init();
///   }
class IosBackgroundDownloadLifecycle {
  IosBackgroundDownloadLifecycle._();

  static final instance = IosBackgroundDownloadLifecycle._();

  AppLifecycleListener? _listener;

  void init() {
    if (!Platform.isIOS) return;
    _listener = AppLifecycleListener(
      onResume: _onResume,
    );
  }

  void dispose() {
    _listener?.dispose();
    _listener = null;
  }

  /// When the app foregrounds, find all tasks that are still running
  /// in NSURLSession and reattach Dart callbacks so progress shows again.
  Future<void> _onResume() async {
    if (!Platform.isIOS) return;
    try {
      final tasks = await getTasks([Status.running]);
      for (final task in tasks) {
        await IosBackgroundDownloadService.instance.reattach(
          task.id,
          onProgress: (progress, downloaded, total) {
            // You can broadcast this via a GetX reactive variable or EventBus.
            // For now, we fire a named event that task list controllers listen to.
            Get.find<_ProgressEventBus>()
                .emit(task.id, progress, downloaded, total);
          },
          onComplete: (error) {
            Get.find<_ProgressEventBus>().emitDone(task.id, error);
          },
        );
      }
    } catch (_) {
      // If the Go engine hasn't started yet, skip silently
    }
  }
}

/// Minimal reactive event bus for download progress.
/// Put() this in your app binding so controllers can find it.
class IosDownloadProgressBus extends GetxService {
  // id → (progress, downloaded, total)
  final progress = <String, (double, int, int)>{}.obs;
  // id → error? (null = success)
  final completed = <String, String?>{}.obs;

  void emit(String id, double prog, int dl, int total) {
    progress[id] = (prog, dl, total);
  }

  void emitDone(String id, String? error) {
    completed[id] = error;
    progress.remove(id);
  }
}

// Private alias used by lifecycle above — resolved at runtime via Get.find
// Replace with your actual event broadcasting mechanism if you prefer.
typedef _ProgressEventBus = IosDownloadProgressBus;
