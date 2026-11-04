/// macOS 关窗拦截（Dart 侧）。
///
/// 原生 `MainFlutterWindow.windowShouldClose` 收到关闭请求后经
/// MethodChannel `lmstory/window_close` 发来 `requestClose`；本类判定
/// 「是否有会话正在生成」，空闲直接放行，生成中弹确认框由用户决定。
/// 用户确认后回 `{allow: true}`，原生置 forceClose 再 performClose。
///
/// 仅 macOS 有原生端；其他平台不注册（channel 调用无来源，零开销）。
/// 已知边界：Cmd+Q 走 applicationShouldTerminate 不经此链路。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class MacWindowCloseGuard {
  static const MethodChannel _channel = MethodChannel('lmstory/window_close');

  /// 确认框重入守卫：原生 performClose 前的窗口闪烁期若再点关闭，
  /// 直接回不允许，避免叠出第二个确认框。
  static bool _confirming = false;

  /// 注册关窗询问处理器。
  ///
  /// [isBusy] 返回是否存在正在生成/压缩的会话（含后台会话）；
  /// [showConfirm] 弹确认框返回用户是否确认关闭。
  static void register({
    required Future<bool> Function() isBusy,
    required Future<bool> Function() showConfirm,
  }) {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'requestClose') return null;
      if (_confirming) return <String, dynamic>{'allow': false};
      try {
        if (!await isBusy()) return <String, dynamic>{'allow': true};
        _confirming = true;
        final confirmed = await showConfirm();
        return <String, dynamic>{'allow': confirmed == true};
      } catch (_) {
        // 判定或弹框异常 fail-open：不让用户关不掉窗口
        return <String, dynamic>{'allow': true};
      } finally {
        _confirming = false;
      }
    });
  }

  @visibleForTesting
  static void resetForTesting() => _confirming = false;
}
