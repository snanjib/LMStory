import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 演示环境数据库：应用文档目录下 `lmstory_demo/demo.db`（与正式库
/// 同 schema、同 PRAGMA，独立文件）。
///
/// 隔离边界：本目录（`lmstory_demo/`）内的文件全部由演示功能管辖；
/// 交接清理与「放弃演示数据」只触本目录，永不触碰正式 `lmstory.db`。
Future<AppDatabase> openDemoDatabase({QueryExecutor? forTesting}) async {
  if (forTesting != null) {
    return AppDatabase.forTesting(forTesting);
  }
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory(p.join(docs.path, 'lmstory_demo'))
    ..createSync(recursive: true);
  final file = File(p.join(dir.path, 'demo.db'));
  return AppDatabase.forTesting(
    NativeDatabase.createInBackground(
      file,
      setup: (db) {
        db
          ..execute('PRAGMA journal_mode = WAL')
          ..execute('PRAGMA synchronous = NORMAL')
          ..execute('PRAGMA journal_size_limit = 8388608');
      },
    ),
  );
}

/// 演示数据目录（状态文件与库文件所在）
Future<Directory> demoDataDirectory() async {
  final docs = await getApplicationDocumentsDirectory();
  return Directory(p.join(docs.path, 'lmstory_demo')).create(recursive: true);
}

/// 删除演示库文件（WAL/SHM 一并）。只删本目录已知文件名，目录与
/// 状态文件由 DemoStateStore（demo_state_store.dart）管理。
Future<void> deleteDemoDatabaseFiles() async {
  final dir = await demoDataDirectory();
  for (final name in ['demo.db', 'demo.db-wal', 'demo.db-shm']) {
    final f = File(p.join(dir.path, name));
    if (f.existsSync()) await f.delete();
  }
}
