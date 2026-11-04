/// 日志文件操作 - 原生平台默认实现
///
/// 提供 [readLogFileTail] 和 [clearLogFiles] 两个操作，使用 `dart:io` File
/// 和 `compute` Isolate。Web 平台实现见 `log_file_ops_web.dart`（no-op）。
///
/// 通过条件导入切换：
/// ```dart
/// import 'log_file_ops.dart'
///     if (dart.library.html) 'log_file_ops_web.dart';
/// ```
library;

import 'dart:io';

import 'package:flutter/foundation.dart' show compute;
import 'package:lmstory/core/utils/log_tail_reader.dart';
import 'package:lmstory/core/utils/logger.dart';

/// 读取日志文件最后 [maxLines] 行
///
/// 通过 [compute] 在 Isolate 中执行反向随机读取（[readLogTail]），
/// 避免一次性读取 10MB 全量日志导致 UI 线程阻塞。
/// 文件不存在或读取失败返回空列表（不抛异常）。
Future<List<String>> readLogFileTail({required int maxLines}) async {
  final path = Logger.currentLogFilePath;
  if (path == null) return const [];
  try {
    return await compute(
      readLogTail,
      LogTailParams(path: path, maxLines: maxLines),
    );
  } catch (_) {
    return const [];
  }
}

/// 清空日志文件：先 flush 落盘 buffer → 清空当前文件 → 删除备份
///
/// 不删除当前文件本身（FileLogSink sink 仍持有句柄继续写入），
/// 只清空内容。备份文件 .1 直接删除（maxBackupCount=1）。
/// 扫到 .2/.3 防御旧版本遗留文件。
Future<void> clearLogFiles() async {
  // 先把内存 buffer 落盘，确保清空的是完整内容
  await Logger.flushAll();

  final path = Logger.currentLogFilePath;
  if (path == null) return;

  final base = File(path);
  if (base.existsSync()) {
    await base.writeAsString('');
  }

  // 删除轮转备份
  for (var i = 1; i <= 3; i++) {
    final backup = File('$path.$i');
    if (backup.existsSync()) {
      await backup.delete();
    }
  }
}

/// 将当前日志与轮转备份合并写入 [targetPath]（桌面导出）
///
/// 轮转文件（app.log.1，上次运行——崩溃证据所在）在前、当前文件在后，
/// 各以「===== 文件名 =====」分隔，排障时一次拿到两个阶段的日志。
/// 通过 [compute] 在 Isolate 中读写，避免 10MB 级日志阻塞 UI 线程。
/// 调用前须先 [Logger.flushAll] 保证内存 buffer 已落盘。
Future<void> saveLogFilesTo({required String targetPath}) async {
  final path = Logger.currentLogFilePath;
  if (path == null) {
    throw StateError('log file path unavailable');
  }
  await compute(_mergeLogFiles, (currentPath: path, targetPath: targetPath));
}

void _mergeLogFiles(({String currentPath, String targetPath}) params) {
  final buffer = StringBuffer();
  final rotated = File('${params.currentPath}.1');
  if (rotated.existsSync()) {
    buffer
      ..writeln('===== app.log.1 =====')
      ..write(rotated.readAsStringSync())
      ..writeln();
  }
  buffer
    ..writeln('===== app.log =====')
    ..write(File(params.currentPath).readAsStringSync());
  File(params.targetPath).writeAsStringSync(buffer.toString());
}
