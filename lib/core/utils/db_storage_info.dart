/// 数据库存储信息 - 原生平台默认实现
///
/// 读取 lmstory.db 文件大小用于存储信息展示。
/// Web 平台实现见 `db_storage_info_web.dart`（返回 0）。
library;

import 'dart:io';

import 'package:lmstory/core/storage/native_database_paths.dart';
import 'package:path_provider/path_provider.dart';

/// 获取数据库文件大小（字节）
///
/// 文件不存在时返回 0。WAL 模式启用后（修复），checkpoint 前的写入
/// 驻留在 -wal 文件中——只读主文件会系统性偏小，
/// 故一并计入 -wal/-shm 附属文件。
Future<int> getDatabaseFileSize() async {
  try {
    final dbFolder = await getApplicationDocumentsDirectory();
    final (dbFile, _) = await activeNativeDatabase(dbFolder);
    if (!dbFile.existsSync()) return 0;
    var total = dbFile.lengthSync();
    for (final suffix in const ['-wal', '-shm']) {
      final sidecar = File('${dbFile.path}$suffix');
      if (sidecar.existsSync()) {
        total += sidecar.lengthSync();
      }
    }
    return total;
  } catch (_) {
    // 读取失败返回 0，不阻塞 UI
  }
  return 0;
}
