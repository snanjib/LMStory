/// 数据库连接工厂 - 原生平台默认实现（Android/iOS/Windows/macOS/Linux）
///
/// 使用 [NativeDatabase] + `sqlite3_flutter_libs` 通过 FFI 调用系统 SQLite。
/// 数据库文件存储在应用文档目录（`getApplicationDocumentsDirectory`）。
///
/// Web 平台实现见 `database_connection_web.dart`，通过条件导入切换：
/// ```dart
/// import 'database_connection.dart'
///     if (dart.library.html) 'database_connection_web.dart';
/// ```
library;

import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:lmstory/core/storage/native_database_paths.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart'
    show AppDatabase;
import 'package:path_provider/path_provider.dart';

export 'package:lmstory/core/storage/native_database_paths.dart';

/// 创建数据库执行器（原生平台）
///
/// 返回 [QueryExecutor] 供 [AppDatabase] 通过 [LazyDatabase] 包装使用。
/// 实际打开操作延迟到首次查询时执行。
Future<QueryExecutor> createDatabaseExecutor() async {
  final dbFolder = await getApplicationDocumentsDirectory();
  final (file, _) = await activeNativeDatabase(dbFolder);
  return openNativeDatabase(file);
}

Future<QueryExecutor> openNativeDatabase(File file) async {
  await validateNativeDatabaseHeader(file);
  return NativeDatabase.createInBackground(
    file,
    setup: (rawDb) {
      //  修复：启用 WAL。默认 journal 模式下读写互斥，
      // 长对话高频写（流式摘要逐段落库）与渲染并发读会相互阻塞卡顿；
      // WAL 允许读写并行。NORMAL 同步级别是 WAL 的标准搭配，
      // 仅牺牲极小的崩溃恢复窗口换取明显写入吞吐。
      rawDb
        ..execute('PRAGMA journal_mode = WAL')
        ..execute('PRAGMA synchronous = NORMAL')
        // WAL 文件只增不减：应用数据目录会随备份进 iCloud（iOS），
        // 流式写高峰留下的 wal 若不设上限将永久占用备份体积；
        // 8MB 足够容纳写入高峰，checkpoint 后自动收缩。
        ..execute('PRAGMA journal_size_limit = 8388608');
    },
  );
}

// SQLite can remove sidecars when closing a file with an invalid header.
// Inspect the signature before opening the file for writing.
Future<void> validateNativeDatabaseHeader(File file) async {
  bool hasSidecars() =>
      File('${file.path}-wal').existsSync() ||
      File('${file.path}-shm').existsSync() ||
      File('${file.path}-journal').existsSync();

  if (!file.existsSync()) {
    if (hasSidecars()) {
      throw FileSystemException(
        'Database sidecars have no main file',
        file.path,
      );
    }
    return;
  }
  const signature = 'SQLite format 3\u0000';
  final handle = await file.open();
  final List<int> header;
  try {
    header = await handle.read(signature.length);
  } finally {
    await handle.close();
  }
  if (String.fromCharCodes(header) == signature) return;

  // SQLite can initialize a zero-byte database left by an interrupted create.
  if (header.isEmpty && !hasSidecars()) return;
  throw FileSystemException('Invalid SQLite database header', file.path);
}
