import Flutter
import UIKit
import workmanager_apple

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    WorkmanagerPlugin.registerLaunchHandlers()

    // Plugins (such as path_provider) must also be available in the
    // background engine running the downloads
    WorkmanagerPlugin.setPluginRegistrantCallback { registry in
      GeneratedPluginRegistrant.register(with: registry)
    }

    // Must match MapTilerWorkmanagerIosOptions, and Info.plist's
    // BGTaskSchedulerPermittedIdentifiers
    WorkmanagerPlugin.registerBGContinuedProcessingTask(
      withIdentifier: "be.taptheory.flutterMapMaptilerWorkmanagerExample.maptilerOffline.*"
    )
    WorkmanagerPlugin.registerBGProcessingTask(
      withIdentifier: "be.taptheory.flutterMapMaptilerWorkmanagerExample.maptilerOfflineDownload"
    )

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
