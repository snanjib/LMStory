/// 模型注册表缓存操作 - Web 平台 no-op 实现
///
/// Web 平台无文件系统，缓存操作均为 no-op。
/// 模型注册表仅使用内存缓存（每次启动需重新拉取）。
library;

/// 读取缓存文件内容 - Web 平台返回 null
Future<String?> readModelCache() async => null;

/// 读取缓存文件的修改时间 - Web 平台返回 null
Future<DateTime?> getCacheLastModified() async => null;

/// 写入缓存文件内容 - Web 平台 no-op
Future<void> writeModelCache(String body) async {}
