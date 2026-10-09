import 'package:flutter/foundation.dart';
import 'package:flutter_map_maptiler_offline_pack/flutter_map_maptiler_offline_pack.dart';
import 'package:workmanager/workmanager.dart';

import 'worker.dart';

/// iOS scheduling options
///
/// iOS only runs background work under identifiers declared in the app's
/// `Info.plist` (`BGTaskSchedulerPermittedIdentifiers`), so identifiers must be
/// configured to download packs in the background. Without them, downloads
/// only continue for the short time iOS grants apps after being backgrounded.
///
/// iOS runs a single task per identifier: scheduling a pack replaces any other
/// pack's pending background download.
@immutable
class MapTilerWorkmanagerIosOptions {
  /// iOS scheduling options
  const MapTilerWorkmanagerIosOptions({
    this.continuedProcessingIdentifier,
    this.continuedProcessingTitle = 'Downloading offline map',
    this.continuedProcessingSubtitle,
    this.processingIdentifier,
  });

  /// Identifier of a `BGContinuedProcessingTask` (iOS 26+), such as
  /// `'<bundle id>.maptilerOffline.*'`
  ///
  /// Preferred on iOS 26+: the download starts right away and continues in the
  /// background, while iOS shows its progress in a Live Activity. Must end
  /// with `.*`, be listed in `BGTaskSchedulerPermittedIdentifiers`, and be
  /// registered in the `AppDelegate` with
  /// `WorkmanagerPlugin.registerBGContinuedProcessingTask(withIdentifier:)`.
  final String? continuedProcessingIdentifier;

  /// Title of the Live Activity shown during continued processing
  final String continuedProcessingTitle;

  /// Subtitle of the Live Activity shown during continued processing
  final String? continuedProcessingSubtitle;

  /// Identifier of a `BGProcessingTask`, such as
  /// `'<bundle id>.maptilerOfflineDownload'`
  ///
  /// Used before iOS 26, or if [continuedProcessingIdentifier] is not set.
  /// iOS decides when processing tasks run, typically when the device is idle
  /// and charging, so the download may complete hours later. Must be listed
  /// in `BGTaskSchedulerPermittedIdentifiers`, and registered in the
  /// `AppDelegate` with `WorkmanagerPlugin.registerBGProcessingTask(
  /// withIdentifier:)`.
  final String? processingIdentifier;
}

/// Runs MapTiler offline pack downloads in the background with the
/// 'workmanager' plugin
///
/// ```dart
/// final offline = MapTilerOfflineManager(
///   apiKey: key,
///   backgroundScheduler: MapTilerWorkmanagerScheduler(),
/// );
/// await pack.download(inBackground: true);
/// ```
///
/// Requires [MapTilerWorkmanager.initialize] (or a custom callback dispatcher
/// calling [MapTilerWorkmanager.executeTask]) at app startup.
///
/// * Android: a one-off WorkManager task per pack, with [constraints] (a
///   network connection by default), retried with exponential backoff on
///   network failures, and surviving app restarts. Set
///   [androidForegroundService] for long downloads.
/// * iOS: see [MapTilerWorkmanagerIosOptions].
class MapTilerWorkmanagerScheduler implements MapTilerBackgroundScheduler {
  /// Runs MapTiler offline pack downloads in the background with the
  /// 'workmanager' plugin
  MapTilerWorkmanagerScheduler({
    Constraints? constraints,
    this.androidForegroundService,
    this.ios = const MapTilerWorkmanagerIosOptions(),
    this.persistApiKey = true,
    @visibleForTesting Workmanager? workmanager,
    @visibleForTesting TargetPlatform? platform,
  })  : constraints =
            constraints ?? Constraints(networkType: NetworkType.connected),
        _workmanager = workmanager ?? Workmanager(),
        _platform = platform;

  /// Conditions for the download to run, such as
  /// `Constraints(networkType: NetworkType.unmetered)` for Wi-Fi only
  ///
  /// On iOS, only `networkType` and `requiresCharging` are honoured, and only
  /// for processing tasks.
  final Constraints constraints;

  /// Run Android downloads as a foreground service, with a notification
  ///
  /// Lets large downloads run beyond Android's ~10 minute background work
  /// limit. The default `dataSync` service type requires the
  /// `workmanager.enableDataSyncForegroundService=true` gradle property.
  final ForegroundServiceConfig? androidForegroundService;

  /// iOS scheduling options
  final MapTilerWorkmanagerIosOptions ios;

  /// Whether the MapTiler API key is stored with the scheduled work
  ///
  /// Scheduled work is persisted by the platform (in WorkManager's database or
  /// `UserDefaults`). If `false`, the key must instead be supplied to
  /// [MapTilerWorkmanager.executeTask] by a custom callback dispatcher.
  final bool persistApiKey;

  final Workmanager _workmanager;
  final TargetPlatform? _platform;

  TargetPlatform get _targetPlatform => _platform ?? defaultTargetPlatform;

  /// The unique work name of [packId] on Android
  static String uniqueName(String packId) =>
      '${MapTilerWorkmanager.taskName}.$packId';

  @override
  Future<void> schedule(MapTilerBackgroundDownloadRequest request) async {
    final inputData = MapTilerWorkmanager.inputData(
      request,
      includeApiKey: persistApiKey,
    );

    if (_targetPlatform == TargetPlatform.iOS) {
      if (ios.continuedProcessingIdentifier case final identifier?) {
        try {
          await _workmanager.registerContinuedProcessingTask(
            identifier,
            MapTilerWorkmanager.taskName,
            title: ios.continuedProcessingTitle,
            subtitle: ios.continuedProcessingSubtitle,
            inputData: inputData,
          );
          return;
        } on Object catch (e) {
          // Before iOS 26: fall back to a processing task
          debugPrint('[MapTilerWorkmanager] Continued processing failed: $e');
        }
      }
      if (ios.processingIdentifier case final identifier?) {
        await _workmanager.registerProcessingTask(
          identifier,
          MapTilerWorkmanager.taskName,
          inputData: inputData,
          constraints: constraints,
        );
        return;
      }
    }

    await _workmanager.registerOneOffTask(
      uniqueName(request.packId),
      MapTilerWorkmanager.taskName,
      inputData: inputData,
      constraints: constraints,
      existingWorkPolicy: ExistingWorkPolicy.replace,
      backoffPolicy: BackoffPolicy.exponential,
      backoffPolicyDelay: const Duration(seconds: 30),
      tag: MapTilerWorkmanager.taskName,
      foregroundServiceConfig: androidForegroundService,
    );
  }

  @override
  Future<void> cancel(String packId) async {
    final names = {
      uniqueName(packId),
      if (_targetPlatform == TargetPlatform.iOS) ...[
        if (ios.continuedProcessingIdentifier case final id?) id,
        if (ios.processingIdentifier case final id?) id,
      ],
    };
    for (final name in names) {
      try {
        await _workmanager.cancelByUniqueName(name);
      } on Object catch (e) {
        debugPrint('[MapTilerWorkmanager] Failed to cancel $name: $e');
      }
    }
  }

  @override
  Future<bool?> isScheduled(String packId) async {
    // Only Android can tell; iOS pending tasks aren't queryable by pack
    if (_targetPlatform != TargetPlatform.android) return null;
    try {
      return await _workmanager.isScheduledByUniqueName(uniqueName(packId));
    } on Object catch (_) {
      return null;
    }
  }
}
