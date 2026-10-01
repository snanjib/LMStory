import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/utils/log_tail_reader.dart';

/// log_tail_reader 单元测试（诊断卡死修复）
///
/// 验证：
/// - 文件不存在/为空时返回空列表
/// - 小文件：返回全部内容
/// - 大文件：只返回最后 maxLines 行
/// - 性能：读取 10MB 假日志文件 < 200ms
/// - 反向读取：从文件末尾向前读取，不一次性加载全文件
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('log_tail_reader_test_');
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('readLogTail 基本场景', () {
    test('文件不存在 → 返回空列表', () {
      final lines = readLogTail(
        LogTailParams(
          path: '${tempDir.path}/not_exists.log',
          maxLines: 100,
        ),
      );
      expect(lines, isEmpty);
    });

    test('空文件 → 返回空列表', () {
      final file = File('${tempDir.path}/empty.log')..createSync();
      final lines = readLogTail(
        LogTailParams(path: file.path, maxLines: 100),
      );
      expect(lines, isEmpty);
    });

    test('小文件（行数 ≤ maxLines）→ 返回全部内容，顺序从旧到新', () {
      final file = File('${tempDir.path}/small.log')
        ..writeAsStringSync('line1\nline2\nline3\n');

      final lines = readLogTail(
        LogTailParams(path: file.path, maxLines: 100),
      );

      expect(lines.length, 3);
      expect(lines[0], 'line1');
      expect(lines[1], 'line2');
      expect(lines[2], 'line3');
    });

    test('文件无末尾换行 → 仍正确返回所有行', () {
      final file = File('${tempDir.path}/no_newline.log')
        ..writeAsStringSync('only line');

      final lines = readLogTail(
        LogTailParams(path: file.path, maxLines: 100),
      );

      expect(lines.length, 1);
      expect(lines[0], 'only line');
    });
  });

  group('readLogTail 大文件场景', () {
    test('行数 > maxLines → 只返回最后 maxLines 行', () {
      final file = File('${tempDir.path}/many_lines.log');
      final buf = StringBuffer();
      for (var i = 0; i < 1000; i++) {
        buf.writeln('line $i');
      }
      file.writeAsStringSync(buf.toString());

      final lines = readLogTail(
        LogTailParams(path: file.path, maxLines: 100),
      );

      expect(lines.length, 100);
      // 最后 100 行：line 900 ~ line 999
      expect(lines.first, 'line 900');
      expect(lines.last, 'line 999');
    });

    test('大文件 10MB + 500 行需求 → 不一次性加载全文件，耗时 < 200ms', () {
      final file = File('${tempDir.path}/big.log');
      // 构造约 10MB 日志：每行约 100 字节，100000 行 ≈ 10MB
      final buf = StringBuffer();
      for (var i = 0; i < 100000; i++) {
        buf.writeln(
          'line ${i.toString().padLeft(5, '0')} '
          'padding-padding-padding-padding-padding-padding-padding',
        );
      }
      file.writeAsStringSync(buf.toString());

      final fileSize = file.lengthSync();
      expect(fileSize > 5 * 1024 * 1024, isTrue, reason: '文件应大于 5MB');

      final stopwatch = Stopwatch()..start();
      final lines = readLogTail(
        LogTailParams(path: file.path, maxLines: 500),
      );
      stopwatch.stop();

      expect(lines.length, 500);
      // 最后 500 行：line 99500 ~ line 99999
      expect(lines.first, startsWith('line 99500'));
      expect(lines.last, startsWith('line 99999'));
      // 性能断言：反向读取应在 200ms 内完成
      expect(
        stopwatch.elapsedMilliseconds,
        lessThan(200),
        reason: '读取耗时 ${stopwatch.elapsedMilliseconds}ms，应小于 200ms',
      );
    });

    test('每行极长（500 行超过 1MB）→ 总读取上限 1MB，返回部分行', () {
      final file = File('${tempDir.path}/long_lines.log');
      // 构造每行 5KB，500 行 = 2.5MB（超过 1MB 上限）
      final longLine = 'x' * 5000;
      final buf = StringBuffer();
      for (var i = 0; i < 500; i++) {
        buf.writeln(longLine);
      }
      file.writeAsStringSync(buf.toString());

      final lines = readLogTail(
        LogTailParams(path: file.path, maxLines: 500),
      );

      // 由于 1MB 上限，无法装下所有 500 行（每行 5KB）
      // 但应返回部分行（不为空，且不超过 500 行）
      expect(lines, isNotEmpty);
      expect(lines.length, lessThanOrEqualTo(500));
    });
  });

  group('readLogTail 反向读取行为', () {
    test('读取中间位置 → 第一行被截断时丢弃', () {
      // 构造文件：每行长度差异较大，确保从 chunk 中间切开
      final file = File('${tempDir.path}/truncated.log');
      // 构造 70KB 内容（每行 70 字节，1000 行）
      // chunkSize=64KB，所以会从 6KB 处开始读第二个 chunk
      final buf = StringBuffer();
      for (var i = 0; i < 1000; i++) {
        // 每行固定 70 字节（含 \n）：'line XXXX padding padding padding padding\n'
        buf.writeln(
          'line ${i.toString().padLeft(4, '0')} padding padding padding padding',
        );
      }
      file.writeAsStringSync(buf.toString());

      final lines = readLogTail(
        LogTailParams(path: file.path, maxLines: 100),
      );

      expect(lines.length, 100);
      // 所有行都应是完整的 'line XXXX ...' 格式
      // 不应出现被截断的行
      for (final line in lines) {
        expect(line, startsWith('line '));
      }
      // 最后 100 行：line 0900 ~ line 0999
      expect(lines.first, contains('0900'));
      expect(lines.last, contains('0999'));
    });

    test('单行文件（无换行）→ 返回单行', () {
      final file = File('${tempDir.path}/single.log')
        ..writeAsStringSync('only line without newline');

      final lines = readLogTail(
        LogTailParams(path: file.path, maxLines: 100),
      );

      expect(lines.length, 1);
      expect(lines[0], 'only line without newline');
    });
  });
}
