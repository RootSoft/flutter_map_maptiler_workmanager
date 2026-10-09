import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_map_maptiler_offline_pack/flutter_map_maptiler_offline_pack.dart';
import 'package:flutter_map_maptiler_workmanager/flutter_map_maptiler_workmanager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:workmanager/workmanager.dart';

/// Records calls instead of talking to the platform
class FakeWorkmanager implements Workmanager {
  final calls = <Invocation>[];
  final scheduled = <String>{};
  Error? continuedProcessingError;

  Invocation call(String name) =>
      calls.lastWhere((c) => c.memberName == Symbol(name));

  @override
  Future<void> registerOneOffTask(
    String uniqueName,
    String taskName, {
    Map<String, dynamic>? inputData,
    Duration? initialDelay,
    Constraints? constraints,
    ExistingWorkPolicy? existingWorkPolicy,
    BackoffPolicy? backoffPolicy,
    Duration? backoffPolicyDelay,
    String? tag,
    OutOfQuotaPolicy? outOfQuotaPolicy,
    ForegroundServiceConfig? foregroundServiceConfig,
    bool expedited = false,
  }) async {
    calls.add(
      Invocation.method(#registerOneOffTask, [
        uniqueName,
        taskName,
      ], {
        #inputData: inputData,
        #constraints: constraints,
        #existingWorkPolicy: existingWorkPolicy,
        #backoffPolicy: backoffPolicy,
        #foregroundServiceConfig: foregroundServiceConfig,
      }),
    );
    scheduled.add(uniqueName);
  }

  @override
  Future<void> registerContinuedProcessingTask(
    String uniqueName,
    String taskName, {
    String? title,
    String? subtitle,
    Map<String, dynamic>? inputData,
  }) async {
    if (continuedProcessingError case final Error e) throw e;
    calls.add(
      Invocation.method(
        #registerContinuedProcessingTask,
        [uniqueName, taskName],
        {#title: title, #inputData: inputData},
      ),
    );
    scheduled.add(uniqueName);
  }

  @override
  Future<void> registerProcessingTask(
    String uniqueName,
    String taskName, {
    Duration? initialDelay,
    Map<String, dynamic>? inputData,
    Constraints? constraints,
  }) async {
    calls.add(
      Invocation.method(
        #registerProcessingTask,
        [uniqueName, taskName],
        {#inputData: inputData},
      ),
    );
    scheduled.add(uniqueName);
  }

  @override
  Future<void> cancelByUniqueName(String uniqueName) async {
    calls.add(Invocation.method(#cancelByUniqueName, [uniqueName]));
    scheduled.remove(uniqueName);
  }

  @override
  Future<bool> isScheduledByUniqueName(String uniqueName) async =>
      scheduled.contains(uniqueName);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory root;
  late FakeWorkmanager workmanager;
  late http.Client client;

  final region = MapTilerOfflineRegionDefinition.bounds(
    bbox: const MapTilerBoundingBox(
      minLon: 4.34,
      minLat: 50.84,
      maxLon: 4.36,
      maxLat: 50.85,
    ),
    minZoom: 12,
    maxZoom: 13,
  );

  MapTilerOfflineManager createManager(
    MapTilerWorkmanagerScheduler scheduler,
  ) =>
      MapTilerOfflineManager(
        apiKey: 'KEY',
        rootDirectory: root,
        httpClient: client,
        backgroundScheduler: scheduler,
      );

  /// Input data as a platform channel delivers it back
  Map<String, dynamic> roundTrip(Object? inputData) =>
      jsonDecode(jsonEncode(inputData)) as Map<String, dynamic>;

  Future<void> waitFor(bool Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) fail('Timed out');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('maptiler_workmanager_test');
    workmanager = FakeWorkmanager();
    client = MockClient(
      (request) async => http.Response.bytes(
        utf8.encode('png'),
        200,
        headers: {'content-type': 'image/png'},
      ),
    );
  });

  tearDown(() => root.delete(recursive: true));

  group('Android', () {
    MapTilerWorkmanagerScheduler scheduler({bool persistApiKey = true}) =>
        MapTilerWorkmanagerScheduler(
          workmanager: workmanager,
          platform: TargetPlatform.android,
          persistApiKey: persistApiKey,
          constraints: Constraints(networkType: NetworkType.unmetered),
          androidForegroundService: ForegroundServiceConfig(
            notificationTitle: 'Downloading Bangkok',
          ),
        );

    test('schedules a one-off task per pack, and runs it', () async {
      final manager = createManager(scheduler());
      final pack = await manager.createPack(region);
      await pack.download(inBackground: true);

      final call = workmanager.call('registerOneOffTask');
      expect(call.positionalArguments, [
        MapTilerWorkmanagerScheduler.uniqueName(pack.id),
        MapTilerWorkmanager.taskName,
      ]);
      expect(
        call.namedArguments[#existingWorkPolicy],
        ExistingWorkPolicy.replace,
      );
      expect(call.namedArguments[#backoffPolicy], BackoffPolicy.exponential);
      expect(
        (call.namedArguments[#constraints]! as Constraints).networkType,
        NetworkType.unmetered,
      );
      expect(
        (call.namedArguments[#foregroundServiceConfig]!
                as ForegroundServiceConfig)
            .notificationTitle,
        'Downloading Bangkok',
      );
      expect(await manager.backgroundScheduler!.isScheduled(pack.id), isTrue);

      // The platform runs the task in the background isolate
      final input = roundTrip(call.namedArguments[#inputData]);
      expect(input['apiKey'], 'KEY');
      expect(
        await MapTilerWorkmanager.executeTask(
          MapTilerWorkmanager.taskName,
          input,
          httpClient: client,
        ),
        isTrue,
      );
      await waitFor(() => pack.state == MapTilerOfflinePackState.completed);
    });

    test('pausing cancels the work', () async {
      final manager = createManager(scheduler());
      final pack = await manager.createPack(region);
      await pack.download(inBackground: true);
      pack.pause();
      await waitFor(
        () => workmanager.calls.any((c) => c.memberName == #cancelByUniqueName),
      );
      expect(
        workmanager.call('cancelByUniqueName').positionalArguments,
        [MapTilerWorkmanagerScheduler.uniqueName(pack.id)],
      );
      expect(await manager.backgroundScheduler!.isScheduled(pack.id), isFalse);
    });

    test('the API key can be kept out of persisted work', () async {
      final manager = createManager(scheduler(persistApiKey: false));
      final pack = await manager.createPack(region);
      await pack.download(inBackground: true);
      final input = roundTrip(
        workmanager.call('registerOneOffTask').namedArguments[#inputData],
      );
      expect(input.containsKey('apiKey'), isFalse);

      // Without a key, nothing is downloaded
      expect(
        await MapTilerWorkmanager.executeTask(
          MapTilerWorkmanager.taskName,
          input,
          httpClient: client,
        ),
        isTrue,
      );
      expect(pack.state, MapTilerOfflinePackState.downloading);

      // The app's dispatcher supplies it
      await MapTilerWorkmanager.executeTask(
        MapTilerWorkmanager.taskName,
        input,
        apiKey: 'KEY',
        httpClient: client,
      );
      await waitFor(() => pack.state == MapTilerOfflinePackState.completed);
    });
  });

  group('iOS', () {
    const ios = MapTilerWorkmanagerIosOptions(
      continuedProcessingIdentifier: 'com.example.app.maptilerOffline.*',
      processingIdentifier: 'com.example.app.maptilerOfflineDownload',
    );

    test('prefers continued processing, run under its identifier', () async {
      final manager = createManager(
        MapTilerWorkmanagerScheduler(
          workmanager: workmanager,
          platform: TargetPlatform.iOS,
          ios: ios,
        ),
      );
      final pack = await manager.createPack(region);
      await pack.download(inBackground: true);

      final call = workmanager.call('registerContinuedProcessingTask');
      expect(call.positionalArguments.first, ios.continuedProcessingIdentifier);
      expect(call.namedArguments[#title], 'Downloading offline map');
      // iOS can't tell whether work is scheduled
      expect(await manager.backgroundScheduler!.isScheduled(pack.id), isNull);

      // iOS passes the identifier, not the task name, to the dispatcher
      final input = roundTrip(call.namedArguments[#inputData]);
      expect(
        MapTilerWorkmanager.handles(ios.continuedProcessingIdentifier!, input),
        isTrue,
      );
      await MapTilerWorkmanager.executeTask(
        ios.continuedProcessingIdentifier!,
        input,
        httpClient: client,
      );
      await waitFor(() => pack.state == MapTilerOfflinePackState.completed);
    });

    test('falls back to a processing task before iOS 26', () async {
      workmanager.continuedProcessingError = UnsupportedError('iOS 18');
      final manager = createManager(
        MapTilerWorkmanagerScheduler(
          workmanager: workmanager,
          platform: TargetPlatform.iOS,
          ios: ios,
        ),
      );
      final pack = await manager.createPack(region);
      await pack.download(inBackground: true);
      expect(
        workmanager.call('registerProcessingTask').positionalArguments.first,
        ios.processingIdentifier,
      );
    });

    test('without identifiers, uses a short-lived one-off task', () async {
      final manager = createManager(
        MapTilerWorkmanagerScheduler(
          workmanager: workmanager,
          platform: TargetPlatform.iOS,
        ),
      );
      final pack = await manager.createPack(region);
      await pack.download(inBackground: true);
      expect(
        workmanager.calls.map((c) => c.memberName),
        [#registerOneOffTask],
      );
    });
  });

  test('ignores tasks that are not pack downloads', () async {
    expect(MapTilerWorkmanager.handles('other', {'x': 1}), isFalse);
    expect(await MapTilerWorkmanager.executeTask('other', {'x': 1}), isTrue);
    expect(
      await MapTilerWorkmanager.executeTask(
        MapTilerWorkmanager.taskName,
        {'invalid': true},
      ),
      isTrue,
    );
  });
}
