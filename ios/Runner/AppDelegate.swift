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
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "IncomingFilePlugin") {
      IncomingFilePlugin.register(with: registrar)
    }
  }
}

/// 外部"打开方式/分享"导入桥接插件（与 Android 端 MainActivity 对称）。
///
/// MethodChannel `lmstory/incoming_file`：
/// - Dart → 原生：`getInitialFile`（返回并清除冷启动暂存的 pending 文件）
/// - 原生 → Dart：`onIncomingFile({path, fileName, mime})`
///
/// 接收路径：iOS 把外部打开的文件拷贝到 tmp/Inbox，经 scene 生命周期的
/// openURL 回调（FlutterPluginSceneLifeCycleDelegate 转发给
/// `addApplicationDelegate` 注册的插件；冷启动由 willConnectTo 的
/// connectionOptions 补投）。协议方法均为普通 conformance，无需 override。
class IncomingFilePlugin: NSObject, FlutterPlugin {
  /// Dart 侧就绪前的暂存（冷启动）
  private static var pending: [String: Any?]?
  private static var channel: FlutterMethodChannel?

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "lmstory/incoming_file",
      binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      if call.method == "getInitialFile" {
        let file = pending
        pending = nil
        result(file)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
    self.channel = channel
    registrar.addApplicationDelegate(IncomingFilePlugin())
  }

  /// Scene 生命周期 openURL（外部"打开方式/分享"的热启动常规路径）
  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) -> Bool {
    for context in URLContexts {
      Self.handle(url: context.url)
    }
    return false // 不拦截，继续交给其他插件处理
  }

  /// 非 scene 生命周期兜底（Flutter 兼容路径仍可能走旧的 application:open:）
  func application(
    _ application: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    Self.handle(url: url)
    return false
  }

  /// 收到外部文件 URL：iOS 已将文件拷贝到 tmp/Inbox，直接传路径给 Dart。
  /// 始终暂存 pending（供 Dart getInitialFile 兜底），channel 就绪时额外推送。
  private static func handle(url: URL) {
    guard url.isFileURL else { return }
    let fileName = url.lastPathComponent
    let lower = fileName.lowercased()
    let mime: String
    if lower.hasSuffix(".json") {
      mime = "application/json"
    } else if lower.hasSuffix(".png") {
      mime = "image/png"
    } else {
      mime = "application/octet-stream"
    }
    let file: [String: Any?] = [
      "path": url.path,
      "fileName": fileName,
      "mime": mime,
    ]
    pending = file
    channel?.invokeMethod("onIncomingFile", arguments: file)
  }
}
