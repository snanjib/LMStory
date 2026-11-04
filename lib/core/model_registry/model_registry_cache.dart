/// 模型注册表缓存操作 - 原生平台默认实现
///
/// 使用 `dart:io` File + `path_provider` 在应用支持目录读写 JSON 缓存文件。
/// Web 平台实现见 `model_registry_cache_web.dart`（no-op）。
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 缓存文件名
const _cacheFileName = 'model_registry.json';

/// 读取缓存文件内容
///
/// 文件不存在时返回 null。不检查文件新鲜度（由调用方判断）。
Future<String?> readModelCache() async {
  final file = await _cacheFile();
  if (!file.existsSync()) return null;
  return file.readAsStringSync();
}

/// 读取缓存文件的修改时间（用于判断新鲜度）
///
/// 文件不存在时返回 null。
Future<DateTime?> getCacheLastModified() async {
  final file = await _cacheFile();
  if (!file.existsSync()) return null;
  return file.statSync().modified;
}

/// 写入缓存文件内容
Future<void> writeModelCache(String body) async {
  final file = await _cacheFile();
  await file.writeAsString(body);
}

Future<File> _cacheFile() async {
  final dir = await getApplicationSupportDirectory();
  return File('${dir.path}/$_cacheFileName');
}
