/// 文件导出/分享 - 原生平台默认实现
///
/// 桌面平台（Windows/macOS/Linux）弹系统保存对话框选位置后直接写文件；
/// 移动平台写入临时文件并调起系统分享面板（`share_plus`）。
/// Web 平台实现见 `file_share_web.dart`（浏览器下载）。
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// 当前平台是否为桌面平台
///
/// 桌面端导出走系统保存对话框；移动端走分享面板。
/// Web 实现（file_share_web.dart）有同名常量 `false`。
final bool isDesktopPlatform =
    Platform.isWindows || Platform.isMacOS || Platform.isLinux;

/// 将文本内容保存或分享
///
/// [content] 文件内容
/// [fileName] 文件名（含扩展名，如 `session_2026-07-13.json`）
/// [subject] 分享主题（邮件标题等，仅移动端分享面板使用，桌面端忽略）
///
/// 桌面平台返回用户选择的保存路径（取消返回 null）；移动平台调起分享
/// 面板后返回 null（成败由分享面板自管）。
///
/// 桌面端此前复用移动端分享面板——share_plus
/// Windows 实现弹系统分享浮层且在平台线程忙等文件异步打开，真机上
/// 文件静默写 %TEMP% 且浮层不可见时抢占输入导致整页卡死，故桌面端
/// 改走系统保存对话框直接落盘。
Future<String?> shareTextAsFile({
  required String content,
  required String fileName,
  String? subject,
  Rect? sharePositionOrigin,
}) async {
  if (isDesktopPlatform) {
    final extension = _extensionOf(fileName);
    final path = await FilePicker.platform.saveFile(
      fileName: fileName,
      type: extension == null ? FileType.any : FileType.custom,
      allowedExtensions: extension == null ? null : [extension],
    );
    if (path == null || path.isEmpty) return null;
    await File(path).writeAsString(content);
    return path;
  }

  final dir = await getTemporaryDirectory();
  final file = File('${dir.path}/$fileName');
  await file.writeAsString(content);
  await Share.shareXFiles(
    [XFile(file.path, mimeType: 'text/plain')],
    subject: subject,
    sharePositionOrigin: sharePositionOrigin,
  );
  return null;
}

/// iPad 上分享浮层（popover）必须有锚点矩形，缺失时会定位异常；
/// 优先取调用点控件的屏幕矩形（浮层从触发处弹出），取不到时兜底
/// 界面中心。
Rect shareOriginFrom(BuildContext context) {
  final renderObject = context.findRenderObject();
  if (renderObject is RenderBox && renderObject.hasSize) {
    final rect = renderObject.localToGlobal(Offset.zero) & renderObject.size;
    if (rect.width > 0 && rect.height > 0) return rect;
  }
  final size = MediaQuery.sizeOf(context);
  return Rect.fromCenter(
    center: size.center(Offset.zero),
    width: 1,
    height: 1,
  );
}

String? _extensionOf(String fileName) {
  final dot = fileName.lastIndexOf('.');
  if (dot <= 0 || dot == fileName.length - 1) return null;
  return fileName.substring(dot + 1);
}
