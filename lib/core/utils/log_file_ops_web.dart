/// 日志文件操作 - Web 平台 no-op 实现
///
/// Web 平台无文件系统访问权限，文件日志在 `main.dart` 中已跳过初始化，
/// 因此读取和清空操作均为 no-op。
///
/// 原生平台实现见 `log_file_ops.dart`，通过条件导入切换。
library;

/// 读取日志文件最后 [maxLines] 行 - Web 平台返回空列表
Future<List<String>> readLogFileTail({required int maxLines}) async {
  return const [];
}

/// 清空日志文件 - Web 平台 no-op
Future<void> clearLogFiles() async {}

/// 合并日志写入目标路径 - Web 平台 no-op（无文件日志）
Future<void> saveLogFilesTo({required String targetPath}) async {}
