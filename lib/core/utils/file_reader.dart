/// 文件读取 - 原生平台默认实现
///
/// 使用 `dart:io` File 读取文件内容。
/// Web 平台实现见 `file_reader_web.dart`（返回空值，web 端用 bytes 读取）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 读取文件内容为字符串（原生平台）
Future<String> readFileContentNative(String path) async {
  return File(path).readAsString();
}

/// 宽容 UTF-8 文本读取（原生平台）——：
/// 统一三路径解码口径。原生 [readFileContentNative] 是严格 UTF-8，GBK 等
/// 非 UTF-8 文件抛裸 FormatException（英文技术文）；web/分享路径早已是
/// `utf8.decode(bytes, allowMalformed: true)` 宽容解码。结构守卫与解析器
/// 能对解码后的垃圾内容给出中文人话报错，统一走宽容口径。
Future<String> readFileTextLenientNative(String path) async {
  final bytes = await File(path).readAsBytes();
  return utf8.decode(bytes, allowMalformed: true);
}

/// 读取文件内容为字节数组（原生平台）
Future<Uint8List> readFileBytesNative(String path) async {
  return File(path).readAsBytes();
}

/// 同步读取文件内容为字节数组（原生平台）
///
/// 用于外部导入等一次性本地缓存文件（原生侧已复制到应用缓存目录）；
/// Web 平台 stub 见 file_reader_web.dart（不会被执行）。
Uint8List readFileBytesSyncNative(String path) {
  return File(path).readAsBytesSync();
}

/// 删除本地文件（不存在时静默跳过）
void deleteFileNative(String path) {
  final f = File(path);
  if (f.existsSync()) f.deleteSync();
}
