/// 文件分享 - Web 平台实现
///
/// 使用浏览器下载机制：创建 Blob URL + 触发 `<a download>` 点击。
/// 不依赖文件系统，直接在内存中生成文件并下载。
library;

// Web 平台实现文件，仅 Web 目标编译；迁移 package:web 前保持显式豁免。
// ignore: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;

/// 当前平台桌面标记 - Web 恒为 false（原生实现见 file_share.dart）
const bool isDesktopPlatform = false;

/// 将文本内容作为文件下载（Web 平台）
///
/// [content] 文件内容
/// [fileName] 文件名（含扩展名，如 `session_2026-07-13.json`）
/// [subject] 分享主题（Web 平台忽略，浏览器下载无此概念）
///
/// 与原生实现对齐返回 null（浏览器下载无保存路径回调）。
Future<String?> shareTextAsFile({
  required String content,
  required String fileName,
  String? subject,
}) async {
  // 创建 Blob（MIME 类型设为通用二进制，浏览器根据扩展名处理）
  final blob = html.Blob([content], 'application/octet-stream');
  final url = html.Url.createObjectUrlFromBlob(blob);

  // 创建 <a> 元素并触发下载
  final anchor = html.AnchorElement(href: url)
    ..setAttribute('download', fileName)
    ..style.display = 'none';
  html.document.body?.append(anchor);
  anchor
    ..click()
    ..remove();

  // 释放 Blob URL
  html.Url.revokeObjectUrl(url);
  return null;
}
