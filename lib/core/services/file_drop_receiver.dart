import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:lmstory/core/services/incoming_file_receiver.dart';

/// 文件拖放接收器（macOS 专属，MethodChannel `lmstory/file_drop`）。
///
/// 原生侧 `FileDropView` 覆盖层把 Finder 拖入窗口的文件推给 Dart：
/// - `onDragActive({active})`：拖动悬停进入/离开窗口（用于遮罩提示）
/// - `onDrop({paths, fileNames})`：松手投递（支持多文件）
///
/// 仅 macOS 有原生端；其他平台 [init] 静默跳过（不产生任何事件）。
class FileDropReceiver {
  static const MethodChannel _channel = MethodChannel('lmstory/file_drop');

  final dragActive = ValueNotifier<bool>(false);

  /// 松手投递的文件列表（一次性全量）
  void Function(List<IncomingFile> files)? onFiles;

  Future<void> init() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.macOS) return;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onDragActive':
          final map = Map<String, dynamic>.from(call.arguments as Map);
          dragActive.value = map['active'] == true;
        case 'onDrop':
          final map = Map<String, dynamic>.from(call.arguments as Map);
          final paths = (map['paths'] as List).cast<String>();
          final names = (map['fileNames'] as List?)?.cast<String>() ?? const [];
          if (paths.isEmpty) return null;
          onFiles?.call([
            for (var i = 0; i < paths.length; i++)
              IncomingFile(
                path: paths[i],
                fileName: i < names.length ? names[i] : paths[i],
                mime: 'application/octet-stream',
              ),
          ]);
        default:
          return null;
      }
      return null;
    });
  }

  void dispose() {
    dragActive.dispose();
  }
}

/// 拖入文件的逐个去向（分发纯函数 [FileDropRouting.route] 的结果）。
enum FileDropAction { attachment, import, unsupported }

/// 拖放分发策略（纯函数便于行为锁测试）。
///
/// - 对话（chat）会话中：任意文件都可作为附件（图片走图像附件，
///   其余走文件附件——配合识图模型把 PDF/文档拖给模型）。
/// - 其他场景（首页/设置/故事/导演会话）：仅 PNG/JSON 走既有
///   外部导入确认弹层（角色卡/世界书/备份分流），其余类型提示不支持。
class FileDropRouting {
  static const imageExtensions = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'};
  static const importExtensions = {'png', 'json'};

  static bool isImageFile(String fileName) =>
      imageExtensions.contains(_ext(fileName));

  @visibleForTesting
  static bool isImportableFile(String fileName) =>
      importExtensions.contains(_ext(fileName));

  static String _ext(String fileName) {
    final dot = fileName.lastIndexOf('.');
    if (dot <= 0 || dot == fileName.length - 1) return '';
    return fileName.substring(dot + 1).toLowerCase();
  }

  /// 按当前是否处于对话会话，逐文件决定去向。
  static List<FileDropAction> route({
    required bool inChatSession,
    required List<String> fileNames,
  }) {
    return [
      for (final name in fileNames)
        if (inChatSession)
          FileDropAction.attachment
        else if (isImportableFile(name))
          FileDropAction.import
        else
          FileDropAction.unsupported,
    ];
  }
}
