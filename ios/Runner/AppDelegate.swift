import Flutter
import UIKit
import WebKit
import webview_flutter_wkwebview
import workmanager_apple

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var videoChannel: FlutterMethodChannel?

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
    guard let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "TrickleVideoBridge"
    ) else { return }
    let channel = FlutterMethodChannel(
      name: "com.parmscript.trickle/video",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == "installWebKitPresentationObserver" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard
        let arguments = call.arguments as? [String: Any],
        let identifier = (arguments["webViewIdentifier"] as? NSNumber)?.int64Value,
        let source = arguments["source"] as? String,
        let webView = FWFWebViewFlutterWKWebViewExternalAPI.webView(
          forIdentifier: identifier,
          withPluginRegistrar: registrar
        )
      else {
        result(
          FlutterError(
            code: "web_view_unavailable",
            message: "Could not configure video presentation.",
            details: nil
          )
        )
        return
      }
      webView.configuration.userContentController.addUserScript(
        WKUserScript(
          source: source,
          injectionTime: .atDocumentStart,
          forMainFrameOnly: false
        )
      )
      result(nil)
    }
    videoChannel = channel
  }
}
