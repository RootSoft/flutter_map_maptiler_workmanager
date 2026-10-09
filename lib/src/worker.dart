import 'package:flutter/foundation.dart';
import 'package:flutter_map_maptiler_offline_pack/flutter_map_maptiler_offline_pack.dart';
import 'package:http/http.dart' as http;
import 'package:workmanager/workmanager.dart';

// A namespace reads best in the app's callback dispatcher
// ignore: avoid_classes_with_only_static_members
/// Entry points for running MapTiler offline downloads in workmanager's
/// background isolate
abstract final class MapTilerWorkmanager {
  /// The workmanager task name used for pack downloads
  static const taskName = 'flutter_map_maptiler.offlineDownload';

  /// Marker added to the input data of pack downloads
  ///
  /// Needed because on iOS, tasks receive their identifier instead of their
  /// task name.
  static const _marker = 'mapTilerOfflineDownload';

  /// Initialize workmanager with [callbackDispatcher]
  ///
  /// Call once at app startup, before scheduling downloads, if the app doesn't
  /// use workmanager for anything else. Otherwise, call [executeTask] from the
  /// app's own callback dispatcher.
  static Future<void> initialize() =>
      Workmanager().initialize(callbackDispatcher);

  /// A workmanager callback dispatcher that only runs pack downloads
  @pragma('vm:entry-point')
  static void callbackDispatcher() {
    Workmanager().executeTask(
      (task, inputData) async =>
          handles(task, inputData) ? executeTask(task, inputData) : true,
    );
  }

  /// The workmanager input data for [request]
  static Map<String, Object> inputData(
    MapTilerBackgroundDownloadRequest request, {
    bool includeApiKey = true,
  }) =>
      {...request.toJson(includeApiKey: includeApiKey), _marker: true};

  /// Whether a workmanager task is a pack download handled by [executeTask]
  static bool handles(String task, Map<String, dynamic>? inputData) =>
      task == taskName || inputData?[_marker] == true;

  /// Run the pack download described by a workmanager task
  ///
  /// For apps using workmanager for other tasks too, call this from the app's
  /// callback dispatcher:
  ///
  /// ```dart
  /// @pragma('vm:entry-point')
  /// void callbackDispatcher() {
  ///   Workmanager().executeTask((task, inputData) async {
  ///     if (MapTilerWorkmanager.handles(task, inputData)) {
  ///       return MapTilerWorkmanager.executeTask(task, inputData);
  ///     }
  ///     // ... other tasks
  ///     return true;
  ///   });
  /// }
  /// ```
  ///
  /// [apiKey] must be provided if the scheduler doesn't persist it (see
  /// `MapTilerWorkmanagerScheduler.persistApiKey`).
  ///
  /// Returns `false` for failures worth retrying (such as network errors),
  /// which makes workmanager retry the task later on Android.
  static Future<bool> executeTask(
    String task,
    Map<String, dynamic>? inputData, {
    String? apiKey,
    @visibleForTesting http.Client? httpClient,
  }) async {
    if (inputData == null || !handles(task, inputData)) return true;

    final MapTilerBackgroundDownloadRequest request;
    try {
      request = MapTilerBackgroundDownloadRequest.fromJson(inputData);
    } on Object catch (e) {
      debugPrint('[MapTilerWorkmanager] Invalid task input: $e');
      return true; // Retrying won't help
    }
    if ((apiKey ?? request.apiKey).isEmpty) {
      debugPrint(
        '[MapTilerWorkmanager] No API key: pass it to executeTask, or set '
        'MapTilerWorkmanagerScheduler.persistApiKey',
      );
      return true;
    }

    final manager = MapTilerOfflineManager.fromBackgroundRequest(
      request,
      apiKey: apiKey,
      httpClient: httpClient,
    );
    try {
      return await manager.runBackgroundDownload(request.packId);
    } on Object catch (e) {
      debugPrint('[MapTilerWorkmanager] Download of ${request.packId} failed: '
          '$e');
      return false;
    } finally {
      manager.dispose();
    }
  }
}
