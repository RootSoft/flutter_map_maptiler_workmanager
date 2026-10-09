# flutter_map_maptiler_workmanager

`flutter_map_maptiler_workmanager` is a [flutter_map](https://pub.dev/packages/flutter_map) plugin
that downloads MapTiler offline packs in the background, using
[workmanager](https://pub.dev/packages/workmanager). Downloads keep going when the user leaves the
app or locks the device.

It plugs into the MapTiler offline API of flutter_map
(`package:flutter_map_maptiler_offline_pack/flutter_map_maptiler_offline_pack.dart`), which works without it: this plugin is only needed
for background downloads.

## Features

- **Pluggable**: implements `MapTilerBackgroundScheduler`. Pass it to `MapTilerOfflineManager`,
  and use `pack.download(inBackground: true)`.
- **Transparent progress**: the pack's `stateListenable` and `progressListenable` follow the
  background download, across app restarts. Pause, cancel and remove work as usual.
- **Resilient**: on Android, downloads wait for a network connection (configurable, e.g. Wi-Fi
  only), survive app restarts, and are retried with exponential backoff on network errors.
  Resources already downloaded are never downloaded again.
- **Platform aware**: Android foreground service for long downloads; iOS 26 continued processing
  (with a Live Activity), falling back to processing tasks on older iOS versions.

## Usage

1. Add the dependency:
   ```yaml
   dependencies:
     flutter_map_maptiler_workmanager: any # or latest version
   ```

2. Complete the platform setup below.

3. Initialize workmanager at startup:
   ```dart
   Future<void> main() async {
     WidgetsFlutterBinding.ensureInitialized();
     await MapTilerWorkmanager.initialize();
     runApp(const MyApp());
   }
   ```
   If your app already uses workmanager, call `MapTilerWorkmanager.executeTask` from your own
   callback dispatcher instead:
   ```dart
   @pragma('vm:entry-point')
   void callbackDispatcher() {
     Workmanager().executeTask((task, inputData) async {
       if (MapTilerWorkmanager.handles(task, inputData)) {
         return MapTilerWorkmanager.executeTask(task, inputData);
       }
       // ... your other tasks
       return true;
     });
   }
   ```

4. Configure the manager, and download in the background:
   ```dart
   final offline = MapTilerOfflineManager(
     apiKey: 'YOUR_MAPTILER_KEY',
     backgroundScheduler: MapTilerWorkmanagerScheduler(
       constraints: Constraints(networkType: NetworkType.unmetered), // Wi-Fi only
       androidForegroundService: ForegroundServiceConfig(
         notificationTitle: 'Downloading offline map',
       ),
       ios: const MapTilerWorkmanagerIosOptions(
         continuedProcessingIdentifier: 'com.example.app.maptilerOffline.*',
         processingIdentifier: 'com.example.app.maptilerOfflineDownload',
       ),
     ),
   );

   final pack = await offline.createPack(definition);
   await pack.download(inBackground: true); // Returns once scheduled
   ```

## Platform setup

### Android

Nothing is required for downloads of a few minutes. For longer downloads, use
`androidForegroundService`: Android then shows a notification while downloading, and doesn't stop
the download after ~10 minutes. Its default `dataSync` type requires this line in
`android/gradle.properties`:

```properties
workmanager.enableDataSyncForegroundService=true
```

> [!NOTE]
> Google Play requires a declaration (and a demonstration video) for apps using `dataSync`
> foreground services.

### iOS

Requires iOS 14 or later. iOS only runs background work under identifiers declared by the app.

1. In `ios/Runner/Info.plist`:
   ```xml
   <key>BGTaskSchedulerPermittedIdentifiers</key>
   <array>
     <string>com.example.app.maptilerOffline.*</string>
     <string>com.example.app.maptilerOfflineDownload</string>
   </array>
   <key>UIBackgroundModes</key>
   <array>
     <string>processing</string>
   </array>
   ```

2. In `ios/Runner/AppDelegate.swift`:
   ```swift
   import workmanager_apple

   // In application(_:didFinishLaunchingWithOptions:)
   WorkmanagerPlugin.registerLaunchHandlers()
   WorkmanagerPlugin.setPluginRegistrantCallback { registry in
     GeneratedPluginRegistrant.register(with: registry)
   }
   WorkmanagerPlugin.registerBGContinuedProcessingTask(
     withIdentifier: "com.example.app.maptilerOffline.*"
   )
   WorkmanagerPlugin.registerBGProcessingTask(
     withIdentifier: "com.example.app.maptilerOfflineDownload"
   )
   ```

What to expect on iOS:

| iOS version | Behaviour |
|-------------|-----------|
| 26+ | The download starts immediately and continues in the background, with a Live Activity showing it. |
| 14 - 25 | iOS runs the download when it decides, typically when the device is idle and charging: possibly hours later. |
| No identifiers configured | The download only continues for the short time iOS grants apps after being backgrounded. |

> [!IMPORTANT]
> iOS never runs background tasks in the **Simulator**, and may decline them on devices without
> reporting it. So when no background worker has started within
> `MapTilerOfflineManager.backgroundStartTimeout` (10 seconds by default), the pack downloads in the
> app instead, while it is open. Test background execution on a real device.

iOS runs one task per identifier, so only one pack downloads in the background at a time.
iOS also cannot report whether work is still scheduled: a background download without progress for
`MapTilerOfflineManager.backgroundStaleAfter` (2 minutes by default) is shown as paused, and can be
resumed.

## How it works

Downloads run in workmanager's background isolate, separate from the app. The worker writes
progress to the pack's files, which the app reads every second. To pause or cancel, the app writes
a request next to the pack, which the worker checks before each resource.

Scheduled work is persisted by the platform, including the MapTiler API key by default. Set
`persistApiKey: false` to keep it out, and pass it to `MapTilerWorkmanager.executeTask` from your
own callback dispatcher instead.
