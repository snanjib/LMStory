import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

/// 外部传入的文件（其他应用"打开方式/分享"给 LMStory）
class IncomingFile {
  const IncomingFile({
    required this.path,
    required this.fileName,
    required this.mime,
  });

  /// 原生侧已复制到缓存目录的文件绝对路径
  final String path;
  final String fileName;
  final String mime;
}

/// 外部文件接收器（MethodChannel `lmstory/incoming_file`）
///
/// 协议（Android/iOS 原生侧实现见 MainActivity.kt / AppDelegate.swift）：
/// - Dart → 原生：`getInitialFile`（返回并清除冷启动暂存的 pending 文件）
/// - 原生 → Dart：`onIncomingFile({path, fileName, mime})`
///
/// 冷启动竞态：原生侧在 Dart handler 注册前的推送会被丢弃，因此原生
/// 始终暂存 pending —— [init] 里先注册 handler 再拉取 initial，保证
/// 两个来源都收到（同一路径去重）。
///
/// Web/桌面平台无原生侧实现，[init] 静默跳过（stream 永不发出事件）。
class IncomingFileReceiver {
  static const MethodChannel _channel = MethodChannel('lmstory/incoming_file');

  final _controller = StreamController<IncomingFile>();

  /// 最近一次事件的路径（推送 + initial 双来源去重）
  String? _lastPath;

  Stream<IncomingFile> get stream => _controller.stream;

  Future<void> init() async {
    if (kIsWeb) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onIncomingFile') {
        final map = Map<String, dynamic>.from(call.arguments as Map);
        _emit(_toFile(map));
      }
      return null;
    });

    try {
      final dynamic initial = await _channel.invokeMethod('getInitialFile');
      if (initial is Map) {
        final map = Map<String, dynamic>.from(initial);
        final path = map['path'];
        if (path is String) {
          _emit(_toFile(map));
        }
      }
    } on MissingPluginException {
      // 非 Android/iOS 平台：无原生实现，忽略
    } on PlatformException {
      // 原生侧异常：忽略，等待后续推送
    }
  }

  static IncomingFile _toFile(Map<String, dynamic> map) {
    return IncomingFile(
      path: map['path'] as String,
      fileName: map['fileName'] as String? ?? '',
      mime: map['mime'] as String? ?? 'application/octet-stream',
    );
  }

  void _emit(IncomingFile file) {
    // 同一文件可能经 onIncomingFile（运行中推送）+ getInitialFile（冷启动
    // 拉取）两个来源各到一次，按路径去重
    if (_lastPath == file.path) return;
    _lastPath = file.path;
    _controller.add(file);
  }

  /// 站内事件源（如 macOS 文件拖放）注入：绕过双来源路径去重——
  /// 用户把同一个文件拖入两次是合法且预期的操作。
  void emitExternal(IncomingFile file) {
    _controller.add(file);
  }

  Future<void> dispose() => _controller.close();
}
