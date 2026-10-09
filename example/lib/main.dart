import 'package:flutter/material.dart';
import 'package:flutter_map_maptiler_offline_pack/flutter_map_maptiler_offline_pack.dart';
import 'package:flutter_map_maptiler_workmanager/flutter_map_maptiler_workmanager.dart';
import 'package:workmanager/workmanager.dart';

/// Run with `--dart-define=MAPTILER_API_KEY=<your key>`
const _apiKey = String.fromEnvironment('MAPTILER_API_KEY');

/// Bangkok Metropolitan Administration, roughly
const _bangkok = MapTilerBoundingBox(
  minLon: 100.33,
  minLat: 13.49,
  maxLon: 100.94,
  maxLat: 13.96,
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Registers the background isolate's entry point
  await MapTilerWorkmanager.initialize();
  runApp(const MaterialApp(home: BackgroundDownloadPage()));
}

class BackgroundDownloadPage extends StatefulWidget {
  const BackgroundDownloadPage({super.key});

  @override
  State<BackgroundDownloadPage> createState() => _BackgroundDownloadPageState();
}

class _BackgroundDownloadPageState extends State<BackgroundDownloadPage> {
  final _manager = MapTilerOfflineManager(
    apiKey: _apiKey,
    backgroundScheduler: MapTilerWorkmanagerScheduler(
      // Android: keep downloading beyond the background limits, showing a
      // notification (requires the dataSync gradle property, see README)
      androidForegroundService: ForegroundServiceConfig(
        notificationTitle: 'Downloading Bangkok',
        notificationText: 'Offline map',
      ),
      // iOS: must match AppDelegate.swift and Info.plist
      ios: const MapTilerWorkmanagerIosOptions(
        continuedProcessingIdentifier:
            'be.taptheory.flutterMapMaptilerWorkmanagerExample.maptilerOffline.*',
        continuedProcessingTitle: 'Downloading Bangkok',
        processingIdentifier:
            'be.taptheory.flutterMapMaptilerWorkmanagerExample.maptilerOfflineDownload',
      ),
    ),
  );

  MapTilerOfflinePack? _pack;
  Object? _error;

  @override
  void initState() {
    super.initState();
    // Picks up a download started in an earlier session, still running (or
    // finished) in the background
    _manager.packs().then((packs) {
      if (mounted && packs.isNotEmpty) setState(() => _pack = packs.last);
    });
  }

  @override
  void dispose() {
    _manager.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _error = null);
    try {
      await action();
    } on Object catch (e) {
      setState(() => _error = e);
    }
  }

  Future<void> _downloadBangkok() => _run(() async {
        final pack = await _manager.createPack(
          MapTilerOfflineRegionDefinition.bounds(
            bbox: _bangkok,
            minZoom: 0,
            maxZoom: 14,
            style: MapTilerStyle.map('pastel'),
            content: MapTilerOfflineContent.vector,
            glyphRanges: MapTilerGlyphRanges.none,
            sourceFilter: MapTilerSourceFilter.withoutRelief,
          ),
        );
        setState(() => _pack = pack);
        await pack.download(inBackground: true);
      });

  Future<void> _delete(MapTilerOfflinePack pack) => _run(() async {
        await _manager.removePack(pack);
        setState(() => _pack = null);
      });

  @override
  Widget build(BuildContext context) {
    final pack = _pack;
    return Scaffold(
      appBar: AppBar(title: const Text('Background download')),
      body: _apiKey.isEmpty
          ? const Center(
              child: Text('Run with --dart-define=MAPTILER_API_KEY=<key>'),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  'Start the download, then send the app to the background '
                  'or lock the device: it keeps downloading.',
                ),
                const SizedBox(height: 16),
                if (pack == null)
                  FilledButton.icon(
                    onPressed: _downloadBangkok,
                    icon: const Icon(Icons.download),
                    label: const Text('Download Bangkok in the background'),
                  )
                else
                  _PackStatus(
                    pack: pack,
                    onPause: pack.pause,
                    onResume: () => _run(() => pack.resume(inBackground: true)),
                    onDelete: () => _delete(pack),
                  ),
                if (_error case final error?)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(
                      '$error',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

class _PackStatus extends StatelessWidget {
  const _PackStatus({
    required this.pack,
    required this.onPause,
    required this.onResume,
    required this.onDelete,
  });

  final MapTilerOfflinePack pack;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
        valueListenable: pack.stateListenable,
        builder: (context, state, _) => ValueListenableBuilder(
          valueListenable: pack.progressListenable,
          builder: (context, progress, _) => Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Bangkok · ${state.name}'
                    '${pack.isDownloadingInBackground ? ' (background)' : ''}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  LinearProgressIndicator(value: progress.percentage),
                  const SizedBox(height: 8),
                  Text(
                    '${progress.downloadedResources} / '
                    '${progress.totalResources} resources'
                    '${pack.size > 0 ? ' · ${(pack.size / 1e6).toStringAsFixed(1)} MB' : ''}',
                  ),
                  Row(
                    children: [
                      if (state == MapTilerOfflinePackState.downloading)
                        TextButton(
                          onPressed: onPause,
                          child: const Text('Pause'),
                        )
                      else if (state != MapTilerOfflinePackState.completed)
                        TextButton(
                          onPressed: onResume,
                          child: const Text('Resume in background'),
                        ),
                      const Spacer(),
                      TextButton(
                        onPressed: onDelete,
                        child: const Text('Delete'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
}
