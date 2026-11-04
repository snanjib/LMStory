import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/utils/file_log_sink.dart';
import 'package:lmstory/core/utils/logger.dart';

/// FileLogSink 单元测试（诊断包基础设施）
///
/// 验证：
/// - 基本写入 + flush 后文件内容正确
/// - 多条写入顺序保留
/// - LogRecord.toLine() 格式（时间戳/级别/logger名/消息/详情/异常/堆栈）
/// - 日志级别过滤（globalMinLevel）
/// - Logger 多 sink 分发（Logger.error → FileLogSink → 文件）
/// - 轮转：超 maxFileSize 后生成 .1 备份，新文件继续写入
/// - init 前 write 为 no-op

void main() {
  late Directory tempDir;
  late String logDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('file_log_sink_test_');
    logDir = '${tempDir.path}/logs';
    // 每个测试前重置 Logger 静态状态
    Logger.clearSinks();
    Logger.globalMinLevel = LogLevel.debug;
  });

  tearDown(() async {
    Logger.clearSinks();
    Logger.globalMinLevel = LogLevel.debug;
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('LogRecord.toLine() 格式化', () {
    test('基本消息', () {
      final record = LogRecord(
        timestamp: DateTime.parse('2026-07-03T10:00:00.000'),
        level: LogLevel.info,
        loggerName: 'Test',
        message: 'hello',
      );
      final line = record.toLine();
      expect(line, contains('2026-07-03T10:00:00.000'));
      expect(line, contains('[INFO]'));
      expect(line, contains('[Test]'));
      expect(line, contains('hello'));
      expect(line, isNot(contains('|')));
    });

    test('含 detail + error + stackTrace', () {
      final record = LogRecord(
        timestamp: DateTime.parse('2026-07-03T10:00:00.000'),
        level: LogLevel.error,
        loggerName: 'App',
        message: 'crashed',
        detail: 'while loading',
        error: 'FormatException',
        stackTrace: StackTrace.current,
      );
      final line = record.toLine();
      expect(line, contains('| while loading'));
      expect(line, contains('| Error: FormatException'));
      expect(line, contains('\n'));
    });
  });

  group('FileLogSink 基本写入', () {
    test('init + write + flush → 文件包含日志行', () async {
      final sink = FileLogSink(directoryPath: logDir);
      await sink.init();

      sink.write(
        LogRecord(
          timestamp: DateTime.parse('2026-07-03T10:00:00.000'),
          level: LogLevel.info,
          loggerName: 'Test',
          message: 'hello world',
        ),
      );
      await sink.flush();

      final file = File('$logDir/app.log');
      expect(file.existsSync(), isTrue);
      final content = file.readAsStringSync();
      expect(content, contains('hello world'));
      expect(content, contains('[INFO]'));
      expect(content, contains('[Test]'));

      await sink.dispose();
    });

    test('多条写入 → 顺序保留，每行一条', () async {
      final sink = FileLogSink(directoryPath: logDir);
      await sink.init();

      for (var i = 0; i < 5; i++) {
        sink.write(
          LogRecord(
            timestamp: DateTime.now(),
            level: LogLevel.debug,
            loggerName: 'Test',
            message: 'line $i',
          ),
        );
      }
      await sink.flush();

      final content = File('$logDir/app.log').readAsStringSync();
      final lines = content.trim().split('\n');
      expect(lines.length, 5);
      expect(lines[0], contains('line 0'));
      expect(lines[4], contains('line 4'));

      await sink.dispose();
    });

    test('init 前 write 为 no-op（不抛异常）', () async {
      // 未 init 直接 write
      final sink = FileLogSink(directoryPath: logDir)
        ..write(
          LogRecord(
            timestamp: DateTime.now(),
            level: LogLevel.info,
            loggerName: 'Test',
            message: 'should be dropped',
          ),
        );
      await sink.flush();
      // 文件不应存在
      expect(File('$logDir/app.log').existsSync(), isFalse);
    });

    test('currentFilePath 在 init 后可用', () async {
      final sink = FileLogSink(directoryPath: logDir);
      expect(sink.currentFilePath, isNull);
      await sink.init();
      expect(sink.currentFilePath, '$logDir/app.log');
      await sink.dispose();
    });
  });

  group('FileLogSink 轮转', () {
    test('超 maxFileSize → 生成 .1 备份 + 新文件继续写', () async {
      // 用极小 maxFileSize 触发轮转
      final sink = FileLogSink(
        directoryPath: logDir,
        maxFileSize: 50, // 50 字节即轮转
        flushInterval: const Duration(seconds: 30), // 长间隔，手动 flush
      );
      await sink.init();

      // 写入足够多的日志触发轮转
      for (var i = 0; i < 10; i++) {
        sink.write(
          LogRecord(
            timestamp: DateTime.now(),
            level: LogLevel.info,
            loggerName: 'Test',
            message: 'rotation test line $i with some padding text',
          ),
        );
        await sink.flush();
      }

      // 应存在 app.log（新）和 app.log.1（备份）
      expect(File('$logDir/app.log').existsSync(), isTrue);
      expect(File('$logDir/app.log.1').existsSync(), isTrue);

      // 备份文件应包含旧日志
      final backupContent = File('$logDir/app.log.1').readAsStringSync();
      expect(backupContent, contains('rotation test'));

      await sink.dispose();
    });

    test('多次轮转 → 保留 maxBackupCount 份，更旧的删除', () async {
      final sink = FileLogSink(
        directoryPath: logDir,
        maxFileSize: 30,
        maxBackupCount: 2, // 只保留 2 份备份
        flushInterval: const Duration(seconds: 30),
      );
      await sink.init();

      // 写入大量日志触发多次轮转
      for (var i = 0; i < 30; i++) {
        sink.write(
          LogRecord(
            timestamp: DateTime.now(),
            level: LogLevel.info,
            loggerName: 'Test',
            message: 'overflow line $i padding',
          ),
        );
        await sink.flush();
      }

      // 应只有 .1 和 .2，不应有 .3
      expect(File('$logDir/app.log').existsSync(), isTrue);
      expect(File('$logDir/app.log.1').existsSync(), isTrue);
      expect(File('$logDir/app.log.2').existsSync(), isTrue);
      expect(File('$logDir/app.log.3').existsSync(), isFalse);

      await sink.dispose();
    });
  });

  group('Logger 多 sink 分发', () {
    test('Logger.error → FileLogSink → 文件包含完整信息', () async {
      final sink = FileLogSink(directoryPath: logDir);
      await sink.init();
      Logger.addSink(sink);

      const Logger('TestLogger').error(
        'something failed',
        detail: 'context info',
        error: 'TestException',
        stackTrace: StackTrace.current,
      );
      await sink.flush();

      final content = File('$logDir/app.log').readAsStringSync();
      expect(content, contains('something failed'));
      expect(content, contains('[ERROR]'));
      expect(content, contains('[TestLogger]'));
      expect(content, contains('context info'));
      expect(content, contains('TestException'));

      await sink.dispose();
    });

    test('globalMinLevel 过滤 → 低于级别的日志不写入文件', () async {
      final sink = FileLogSink(directoryPath: logDir);
      await sink.init();
      Logger.addSink(sink);

      // 设为 warn：debug 和 info 被过滤
      Logger.globalMinLevel = LogLevel.warn;

      const Logger('Filtered')
        ..debug('debug message')
        ..info('info message')
        ..warn('warn message')
        ..error('error message');
      await sink.flush();

      final content = File('$logDir/app.log').readAsStringSync();
      expect(content, isNot(contains('debug message')));
      expect(content, isNot(contains('info message')));
      expect(content, contains('warn message'));
      expect(content, contains('error message'));

      await sink.dispose();
    });
  });

  group('FileLogSink 控制字符过滤', () {
    test('LLM 输出含 NULL/BEL/零宽字符 → 落盘时被移除', () async {
      final sink = FileLogSink(directoryPath: logDir);
      await sink.init();

      // 模拟 LLM 输出含控制字符的内容
      // \x00=NULL \x07=BEL \x0B=VT \x1B=ESC \x7F=DEL
      sink.write(
        LogRecord(
          timestamp: DateTime.parse('2026-07-07T10:00:00.000'),
          level: LogLevel.info,
          loggerName: 'LLM',
          message: '响应含\x00null\x07bell\x0Bvt\x1Besc\x7Fdel字符',
        ),
      );
      await sink.flush();

      final content = File('$logDir/app.log').readAsStringSync();
      // 控制字符应被移除
      expect(content, isNot(contains('\x00')));
      expect(content, isNot(contains('\x07')));
      expect(content, isNot(contains('\x0B')));
      expect(content, isNot(contains('\x1B')));
      expect(content, isNot(contains('\x7F')));
      // 正常文本保留
      expect(content, contains('null'));
      expect(content, contains('bell'));
      expect(content, contains('vt'));
      expect(content, contains('esc'));
      expect(content, contains('del'));
      expect(content, contains('响应含'));
      expect(content, contains('字符'));

      await sink.dispose();
    });

    test(r'换行符 \n 与制表符 \t 应保留', () async {
      final sink = FileLogSink(directoryPath: logDir);
      await sink.init();

      sink.write(
        LogRecord(
          timestamp: DateTime.parse('2026-07-07T10:00:00.000'),
          level: LogLevel.info,
          loggerName: 'Test',
          message: 'line1\nline2\ttabbed',
        ),
      );
      await sink.flush();

      final content = File('$logDir/app.log').readAsStringSync();
      expect(content, contains('line1'));
      expect(content, contains('line2'));
      expect(content, contains('\t'));
      expect(content, contains('tabbed'));

      await sink.dispose();
    });

    test('堆栈中的控制字符也应被过滤', () async {
      final sink = FileLogSink(directoryPath: logDir);
      await sink.init();

      sink.write(
        LogRecord(
          timestamp: DateTime.parse('2026-07-07T10:00:00.000'),
          level: LogLevel.error,
          loggerName: 'App',
          message: 'crashed\x00',
          error: 'TestException\x07',
        ),
      );
      await sink.flush();

      final content = File('$logDir/app.log').readAsStringSync();
      expect(content, isNot(contains('\x00')));
      expect(content, isNot(contains('\x07')));
      expect(content, contains('crashed'));
      expect(content, contains('TestException'));

      await sink.dispose();
    });
  });
}
