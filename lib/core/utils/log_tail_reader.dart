import 'dart:convert';
import 'dart:io';

/// 供 `compute` 调用的参数容器。
///
/// `compute` 只支持单参数，所以把 path + maxLines 打包成值类。
class LogTailParams {
  const LogTailParams({required this.path, required this.maxLines});

  /// 日志文件绝对路径
  final String path;

  /// 期望读取的行数（从文件末尾计）
  final int maxLines;
}

/// 读取日志文件最后 `params.maxLines` 行。
///
/// 设计要点：
/// - **反向随机读取**：用 `RandomAccessFile` 从文件末尾向前按 chunk 读取，
///   避免一次性读取 10MB 全量日志导致 UI 线程阻塞
/// - **chunk 大小 64KB**：单次读取 64KB，循环直至读够 maxLines
///   行或读到文件开头
/// - **总读取上限 1MB**：防止极端情况（每行极短导致循环次数过多）
/// - **返回顺序**：从旧到新（与 `File.readAsLines` 一致），UI 直接消费
///
/// 必须是顶层函数（`compute` 要求）。在 Isolate 中执行，不持有 Dart 对象引用。
///
/// 用法：
/// ```dart
/// final lines = await compute(readLogTail, LogTailParams(path: path, maxLines: 500));
/// ```
List<String> readLogTail(LogTailParams params) {
  final file = File(params.path);
  if (!file.existsSync()) return const [];

  final fileSize = file.lengthSync();
  if (fileSize == 0) return const [];

  final raf = file.openSync();
  try {
    const chunkSize = 64 * 1024; // 64KB
    const maxTotalRead = 1024 * 1024; // 1MB 上限
    var pos = fileSize;
    var totalRead = 0;
    final bytesBuilder = <int>[];

    // 反向读取，累积字节
    while (pos > 0 && totalRead < maxTotalRead) {
      final readSize = pos < chunkSize ? pos : chunkSize;
      pos -= readSize;
      raf.setPositionSync(pos);
      final bytes = raf.readSync(readSize);
      bytesBuilder.insertAll(0, bytes);
      totalRead += readSize;

      // 检查已读内容行数，够用即停
      // 用 utf8.decode 替代 String.fromCharCodes，修复中文日志乱码
      // （String.fromCharCodes 把字节直接当 Unicode 码点，UTF-8 多字节中文会乱码）
      final content = utf8.decode(bytesBuilder, allowMalformed: true);
      final lineCount = '\n'.allMatches(content).length;
      if (lineCount >= params.maxLines) break;
    }

    final content = utf8.decode(bytesBuilder, allowMalformed: true);
    var lines = content.split('\n');

    // 如果不是从文件开头读取，第一行是被截断的，丢弃
    if (pos > 0 && lines.isNotEmpty) {
      lines = lines.sublist(1);
    }

    // 移除末尾空行（文件末尾通常以 \n 结尾）
    if (lines.isNotEmpty && lines.last.isEmpty) {
      lines = lines.sublist(0, lines.length - 1);
    }

    // 取最后 maxLines 行
    if (lines.length > params.maxLines) {
      lines = lines.sublist(lines.length - params.maxLines);
    }

    return lines;
  } finally {
    raf.closeSync();
  }
}
