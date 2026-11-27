/// 数据库连接工厂 - Web 平台实现
///
/// 使用 [WasmDatabase]（drift/wasm.dart）加载浏览器兼容的 SQLite WASM 版本。
/// 数据库文件存储在浏览器的 IndexedDB 中（由 drift worker 管理）。
///
/// 需要在 web/ 目录下提供两个资源文件：
/// - `sqlite3.wasm`：SQLite 编译为 WebAssembly（从 sqlite3.dart releases 下载）
/// - `drift_worker.js`：drift 的 web worker 脚本（从 drift releases 下载，需与 drift 包版本匹配）
///
/// 原生平台实现见 `database_connection.dart`，通过条件导入切换。
library;

import 'package:drift/drift.dart';
import 'package:drift/wasm.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart'
    show AppDatabase;

/// The browser database adapter cannot open an app documents file.
Future<QueryExecutor> openNativeDatabase(Object file) async {
  throw UnsupportedError('File databases require a native platform');
}

/// 创建数据库执行器（Web 平台）
///
/// 返回 [QueryExecutor] 供 [AppDatabase] 通过 [LazyDatabase] 包装使用。
/// 通过 WASM 加载 SQLite，数据持久化到浏览器 IndexedDB。
Future<QueryExecutor> createDatabaseExecutor() async {
  final result = await WasmDatabase.open(
    databaseName: 'lmstory',
    sqlite3Uri: Uri.parse('sqlite3.wasm'),
    driftWorkerUri: Uri.parse('drift_worker.js'),
  );

  // 缺少可选特性时仅记录警告，不阻塞启动（FTS5 在新版 sqlite3.wasm 中默认支持）
  if (result.missingFeatures.isNotEmpty) {
    // ignore: avoid_print
    print('[drift] Missing optional features: ${result.missingFeatures}');
  }

  return result.resolvedExecutor;
}
