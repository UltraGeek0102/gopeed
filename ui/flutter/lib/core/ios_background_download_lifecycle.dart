import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../api/api.dart' as api;
import '../../api/model/task.dart';
import '../app/modules/app/controllers/app_controller.dart';
import 'ios_background_download_service.dart';
import 'libgopeed_boot.dart';

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
  bool _recovering = false;

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

  /// When the app foregrounds:
  /// 1. Verify the Go engine is actually reachable — after iOS suspends and
  ///    resumes the app, the loopback TCP socket the engine was listening on
  ///    can be silently invalidated by the OS network stack, even though the
  ///    engine process itself (running in-process via the Go bridge) is
  ///    still technically "up". No amount of server-side timeout tuning can
  ///    fix a genuinely dead socket — the connecting side has to detect this
  ///    and reconnect.
  /// 2. If unreachable, restart the Go engine to get a fresh listener/port,
  ///    then rebuild the Dart API client against the new address.
  /// 3. Reattach in-flight NSURLSession downloads so progress shows again.
  Future<void> _onResume() async {
    if (!Platform.isIOS) return;
    if (_recovering) return; // avoid overlapping recovery attempts
    _recovering = true;
    try {
      final reachable = await api.isReachable();
      if (!reachable) {
        await _recoverEngine();
      }

      final tasks = await api.getTasks([Status.running]);
      for (final task in tasks) {
        await IosBackgroundDownloadService.instance.reattach(task.id);
      }
    } catch (_) {
      // If the Go engine hasn't started yet, skip silently
    } finally {
      _recovering = false;
    }
  }

  /// Restarts the Go engine and re-points the Dart API client at its new
  /// port. Safe to call even if the engine is only "mostly" dead — start()
  /// on an already-running engine is a no-op-ish path in libgopeed, and if
  /// it genuinely needs a fresh process-level start, this gets it.
  Future<void> _recoverEngine() async {
    try {
      final controller = Get.find<AppController>();
      final cfg = controller.startConfig.value;

      // Best-effort stop first so we don't leak the old listener if it's
      // merely slow rather than fully dead.
      try {
        await LibgopeedBoot.instance.stop();
      } catch (_) {}

      final newPort = await LibgopeedBoot.instance.start(cfg);
      controller.runningPort.value = newPort;

      api.reinit(
        network: cfg.network,
        address: controller.runningAddress(),
        apiToken: cfg.apiToken,
      );

      // Give BackgroundDownloadManager the fresh port too, so its own
      // polling (which talks to the Go engine directly, not through Dio)
      // doesn't keep hitting the old dead port.
      await IosBackgroundDownloadService.instance.configureGoEngine(
        port: newPort,
        apiToken: cfg.apiToken,
      );

      print('[Recovery] Go engine restarted on port $newPort');
    } catch (e) {
      print('[Recovery] engine restart failed: $e');
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
