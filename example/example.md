```dart
import 'package:flutter/material.dart';
import 'package:flutter_map_maptiler_offline_pack/flutter_map_maptiler_offline_pack.dart';
import 'package:flutter_map_maptiler_workmanager/flutter_map_maptiler_workmanager.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await MapTilerWorkmanager.initialize();
  runApp(const MaterialApp(home: DownloadPage()));
}

class DownloadPage extends StatelessWidget {
  const DownloadPage({super.key});

  static final offline = MapTilerOfflineManager(
    apiKey: 'YOUR_MAPTILER_KEY',
    backgroundScheduler: MapTilerWorkmanagerScheduler(),
  );

  Future<void> _download() async {
    final pack = await offline.createPack(
      MapTilerOfflineRegionDefinition.bounds(
        bbox: const MapTilerBoundingBox(
          minLon: 100.33,
          minLat: 13.49,
          maxLon: 100.94,
          maxLat: 13.96,
        ),
        minZoom: 0,
        maxZoom: 14,
        content: MapTilerOfflineContent.vector,
      ),
    );
    await pack.download(inBackground: true);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: FilledButton(
            onPressed: _download,
            child: const Text('Download Bangkok in the background'),
          ),
        ),
      );
}
```

See [lib/main.dart](lib/main.dart) for a complete example, with progress,
pause and resume, and the platform setup in `ios/` and `android/`.
