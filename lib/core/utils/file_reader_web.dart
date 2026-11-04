/// 文件读取 - Web 平台 stub
///
/// Web 平台不通过路径读取文件（FilePicker 返回 bytes），
/// 此函数不会被调用，仅为满足条件导入签名一致性。
library;

import 'dart:typed_data';

/// 读取文件内容 - Web 平台返回空字符串（不会被执行）
Future<String> readFileContentNative(String path) async => '';

/// 宽容 UTF-8 文本读取 - Web 平台返回空字符串（不会被执行）
Future<String> readFileTextLenientNative(String path) async => '';

/// 读取文件内容为字节数组 - Web 平台返回空数组（不会被执行）
Future<Uint8List> readFileBytesNative(String path) async => Uint8List(0);

/// 同步读取文件内容为字节数组 - Web 平台返回空数组（不会被执行）
Uint8List readFileBytesSyncNative(String path) => Uint8List(0);

/// 删除本地文件 - Web 平台无文件系统（不会被执行）
void deleteFileNative(String path) {}
