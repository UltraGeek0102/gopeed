import 'dart:async';
import 'dart:io';

import 'package:get/get.dart';

import '../../../../api/api.dart';
import '../../../../api/model/task.dart';
import '../../../../core/ios_background_download_service.dart';
import '../../../../core/ios_background_download_lifecycle.dart';

abstract class TaskListController extends GetxController {
  List<Status> statuses;
  int Function(Task a, Task b) compare;

  TaskListController(this.statuses, this.compare);

  final tasks = <Task>[].obs;
  final selectedTaskIds = <String>[].obs;
  final isRunning = false.obs;

  late final Timer _timer;

  // Track which task IDs we've already registered for background keep-alive
  final _registeredBgIds = <String>{};

  @override
  void onInit() async {
    super.onInit();
    start();
    _timer = Timer.periodic(const Duration(milliseconds: 1000), (timer) async {
      if (isRunning.value) {
        await getTasksState();
      }
    });
  }

  @override
  void onClose() {
    super.onClose();
    _timer.cancel();
  }

  void start() async {
    await getTasksState();
    isRunning.value = true;
  }

  void stop() {
    isRunning.value = false;
  }

  Future<void> getTasksState() async {
    final fetched = await getTasks(statuses);
    fetched.sort(compare);
    this.tasks.value = fetched;

    if (Platform.isIOS) {
      _syncIosBackground(fetched);
    }
  }

  /// On every poll:
  /// - Register any newly-running task for background keep-alive + Live Activity
  /// - Forward progress of running tasks to Live Activity via native
  /// - Notify native when a task finishes/errors so keep-alive can stop
  void _syncIosBackground(List<Task> fetched) {
    final runningIds = fetched
        .where((t) => t.status == Status.running)
        .map((t) => t.id)
        .toSet();

    // Register new running tasks
    for (final task in fetched) {
      if (task.status == Status.running &&
          !_registeredBgIds.contains(task.id)) {
        _registeredBgIds.add(task.id);
        IosBackgroundDownloadService.instance.registerDownload(
          id: task.id,
          filename: task.name,
        );
      }
    }

    // Forward progress for all running tasks
    for (final task in fetched) {
      if (task.status == Status.running) {
        final p = task.progress;
        final total = p.downloaded + (p.used > 0 ? (p.downloaded * 100 ~/ _pct(task) - p.downloaded) : 0);
        IosBackgroundDownloadService.instance.updateProgress(
          task.id,
          progress: _progressFraction(task),
          downloaded: p.downloaded,
          total: _totalBytes(task),
        );
      }
    }

    // Detect tasks that were running but are now done/error
    final previouslyRunning = _registeredBgIds.toSet();
    for (final id in previouslyRunning) {
      if (!runningIds.contains(id)) {
        final task = fetched.firstWhereOrNull((t) => t.id == id);
        final isError = task?.status == Status.error;
        if (task == null || task.status == Status.done || isError) {
          IosBackgroundDownloadService.instance.completeDownload(
            id,
            error: isError ? 'Download failed' : null,
          );
          _registeredBgIds.remove(id);
        }
        // If paused/wait, keep registered so we can resume keep-alive later
      }
    }
  }

  double _progressFraction(Task task) {
    final meta = task.meta;
    if (meta.res != null && meta.res!.size > 0) {
      return task.progress.downloaded / meta.res!.size;
    }
    return 0.0;
  }

  int _totalBytes(Task task) {
    return task.meta.res?.size ?? 0;
  }

  int _pct(Task task) {
    final total = _totalBytes(task);
    if (total == 0) return 1;
    return ((task.progress.downloaded / total) * 100).round().clamp(1, 100);
  }
}
