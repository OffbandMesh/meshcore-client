import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "OffbandPlatform") {
      FlutterMethodChannel(name: "offband/platform", binaryMessenger: registrar.messenger())
        .setMethodCallHandler { call, result in
          if call.method == "isiOSAppOnMac" {
            result(ProcessInfo.processInfo.isiOSAppOnMac)
          } else {
            result(FlutterMethodNotImplemented)
          }
        }
    }
  }
}
