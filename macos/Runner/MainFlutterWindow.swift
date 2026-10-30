import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// 关窗拦截通道：Dart 侧在生成进行中时弹确认框。
  private var closeChannel: FlutterMethodChannel?
  /// 用户已确认（或 Dart 判定空闲）后的放行标志——performClose 会
  /// 再次进入 windowShouldClose，靠它短路防止无限拦截循环。
  private var forceClose = false

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    closeChannel = FlutterMethodChannel(
      name: "lmstory/window_close",
      binaryMessenger: flutterViewController.engine.binaryMessenger)

    // 全窗口文件拖放（Finder 等拖入）：透明覆盖层收 dragging 事件。
    let dropChannel = FlutterMethodChannel(
      name: "lmstory/file_drop",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    let dropView = FileDropView(frame: flutterViewController.view.bounds)
    dropView.autoresizingMask = [.width, .height]
    flutterViewController.view.addSubview(dropView)
    dropView.onDragActive = { active in
      dropChannel.invokeMethod(
        "onDragActive", arguments: ["active": active])
    }
    dropView.onFiles = { urls in
      dropChannel.invokeMethod(
        "onDrop",
        arguments: [
          "paths": urls.map(\.path),
          "fileNames": urls.map(\.lastPathComponent),
        ])
    }

    self.delegate = self

    super.awakeFromNib()
  }
}

/// 文件拖放覆盖层。
///
/// hitTest 返回 nil 使其不参与普通鼠标/键盘命中（事件全部穿透给
/// Flutter 视图）；dragging 派发按注册+几何位置进行，不受 hitTest
/// 影响，因此可作为全窗口拖放目标。沙盒下拖入的文件由系统自动
/// 授予读写权限，与开/存面板同级，无需额外 entitlement。
final class FileDropView: NSView {
  var onDragActive: ((Bool) -> Void)?
  var onFiles: (([URL]) -> Void)?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    registerForDraggedTypes([.fileURL])
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    registerForDraggedTypes([.fileURL])
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    onDragActive?(true)
    return .copy
  }

  override func draggingExited(_ sender: NSDraggingInfo?) {
    onDragActive?(false)
  }

  override func draggingEnded(_ sender: NSDraggingInfo) {
    onDragActive?(false)
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    guard
      let urls = sender.draggingPasteboard.readObjects(
        forClasses: [NSURL.self],
        options: [.urlReadingFileURLsOnly: true] as [NSPasteboard.ReadingOptionKey: Any]
      ) as? [URL], !urls.isEmpty
    else {
      return false
    }
    onFiles?(urls)
    return true
  }
}

extension MainFlutterWindow: NSWindowDelegate {
  /// 拦截窗口关闭（点 × / Cmd+W）：先问 Dart 侧能否关闭。
  ///
  /// windowShouldClose 必须同步返回，而 Dart 的确认框是异步的——
  /// 因此先返回 false 拦下，异步拿到 Dart 结论后，允许时置
  /// forceClose 再 performClose 放行。
  ///
  /// 已知边界：Cmd+Q 走 applicationShouldTerminate，不经过此处，
  /// 生成中直接退出仍会丢当轮内容（与 Android 后台杀进程同级，
  /// 由轮中断恢复机制兜底）；如需覆盖可在 AppDelegate 同模式扩展。
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if forceClose { return true }
    guard let channel = closeChannel else { return true }
    channel.invokeMethod("requestClose", arguments: nil) { result in
      // Dart 未注册/异常时 fail-open：宁可丢内容也不让用户关不掉窗口
      let allow = (result as? [String: Any])?["allow"] as? Bool ?? true
      if allow {
        self.forceClose = true
        self.performClose(sender)
      }
    }
    return false
  }
}
