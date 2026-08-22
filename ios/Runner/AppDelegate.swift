import Flutter
import UIKit
import workmanager_apple

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let appGroup = "group.com.parmscript.trickle"
  private let incomingShareKey = "incomingShareText"
  private var incomingShareChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    excludeApplicationSupportFromBackup()
    WorkmanagerPlugin.registerPeriodicTask(
      withIdentifier: "com.parmscript.trickle.feed-refresh",
      frequency: NSNumber(value: 60 * 60)
    )
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func excludeApplicationSupportFromBackup() {
    let manager = FileManager.default
    guard var directory = manager.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first else { return }
    try? manager.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? directory.setResourceValues(values)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    incomingShareChannel = FlutterMethodChannel(
      name: "com.parmscript.trickle/incoming-share",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    incomingShareChannel?.setMethodCallHandler { [appGroup, incomingShareKey] call, result in
      guard call.method == "takePendingText" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let defaults = UserDefaults(suiteName: appGroup)
      let text = defaults?.string(forKey: incomingShareKey)
      defaults?.removeObject(forKey: incomingShareKey)
      result(text)
    }
  }
}
