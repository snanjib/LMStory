import 'dart:developer' as developer;

import 'package:lmstory/core/utils/debug_log_options.dart';

/// 日志级别
enum LogLevel {
  debug,
  info,
  warn,
  error,
}

/// 结构化日志记录（传递给 [LogSink] 的数据载体）。
///
/// 供文件 sink、远程 sink 等输出目标统一消费。包含完整上下文：
/// 时间戳、级别、logger 名、消息、详情、异常对象、堆栈。
class LogRecord {
  const LogRecord({
    required this.timestamp,
    required this.level,
    required this.loggerName,
    required this.message,
    this.detail,
    this.error,
    this.stackTrace,
  });

  final DateTime timestamp;
  final LogLevel level;
  final String loggerName;
  final String message;
  final String? detail;
  final Object? error;
  final StackTrace? stackTrace;

  /// 格式化为单行文本（供文件 sink 写入）。
  ///
  /// 格式：`ISO时间 [LEVEL] [logger名] 消息 | 详情 | Error: 异常`
  /// 堆栈（如有）换行追加在末尾，便于 grep 但不破坏单条可读性。
  ///
  /// 注意：本方法输出未过滤 ASCII 控制字符。文件落盘时由
  /// `FileLogSink._sanitizeForFile` 过滤（避免 LLM 输出中的零宽字符/BOM
  /// 导致文件乱码）。控制台输出（`developer.log`）保留原始字符方便调试。
  String toLine() {
    final buffer = StringBuffer()
      ..write(timestamp.toIso8601String())
      ..write(' [${level.name.toUpperCase()}] ')
      ..write('[$loggerName] ')
      ..write(message);
    if (detail != null) buffer.write(' | $detail');
    if (error != null) buffer.write(' | Error: $error');
    if (stackTrace != null) buffer.write('\n$stackTrace');
    return buffer.toString();
  }
}

/// 日志输出目标抽象（可插拔 sink）。
///
/// 内置的 `developer.log` 始终生效；额外的 sink（如 FileLogSink）
/// 通过 [Logger.addSink] 注册，在 [Logger._log] 中同步分发。
/// 实现 class 需保证 [write] 不抛异常（logger 不得因 sink 故障中断调用方）。
abstract class LogSink {
  void write(LogRecord record);

  /// 将缓冲数据刷写到持久层（如文件）。
  Future<void> flush();

  /// 释放资源（关闭文件句柄等）。App 退出前调用。
  Future<void> dispose();

  /// 当前持久化目标的路径（如日志文件路径），供诊断页读取/分享。
  /// 非文件型 sink 返回 null（默认）。
  String? get currentFilePath => null;
}

/// 统一日志工具
///
/// 支持多 sink 分发：每条日志同时输出到 `developer.log`（控制台）
/// 和所有已注册的 [LogSink]（如文件落盘）。sink 注册是全局静态的，
/// 所有 Logger 实例共享。
class Logger {
  const Logger(this.name, {this.minLevel = LogLevel.debug});

  final String name;

  /// 实例级最低日志级别（低于此级别不输出）。
  /// 与 [globalMinLevel] 叠加过滤：两者都需通过才输出。
  final LogLevel minLevel;

  // ── 静态 sink 注册 ──────────────────────────────────────────────────
  // 全局共享，所有 Logger 实例分发到同一组 sink。

  static final List<LogSink> _sinks = [];

  /// 全局最低日志级别（运行时可调，诊断页控制）。
  /// 默认 debug（全量输出）；诊断页可调高以减少文件膨胀。
  static LogLevel globalMinLevel = LogLevel.debug;

  /// 调试日志多选开关（Stage 5，诊断页控制）。
  ///
  /// 与 [globalMinLevel] 互补：级别过滤控制粗粒度开关，
  /// [DebugLogOptions] 控制中级模式关键点的详细字段开关
  /// （提示词/响应/记忆/关键词）。控制器在写详细日志前先检查对应开关。
  ///
  /// 默认全关（[DebugLogOptions.allDisabled] = true），避免日志膨胀。
  /// 诊断页勾选后立即生效（同会话内后续轮次生效）。
  static DebugLogOptions debugOptions = const DebugLogOptions();

  /// 注册 sink（幂等：重复注册同一实例不叠加）。
  static void addSink(LogSink sink) {
    if (!_sinks.contains(sink)) _sinks.add(sink);
  }

  /// 移除 sink。
  static void removeSink(LogSink sink) => _sinks.remove(sink);

  /// 清空所有 sink（测试用）。
  static void clearSinks() => _sinks.clear();

  /// 刷新所有已注册 sink（App 退出前调用确保日志落盘）。
  static Future<void> flushAll() async {
    await Future.wait(_sinks.map((s) => s.flush()));
  }

  /// 释放所有 sink（App 退出前调用）。
  static Future<void> disposeAll() async {
    await Future.wait(_sinks.map((s) => s.dispose()));
    _sinks.clear();
  }

  /// 当前日志文件的完整路径（诊断页读取/分享用）。
  ///
  /// 遍历已注册 sink 找第一个提供 [LogSink.currentFilePath] 的（即 FileLogSink）。
  /// 未注册文件 sink 或 init 前返回 null。
  static String? get currentLogFilePath {
    for (final sink in _sinks) {
      final path = sink.currentFilePath;
      if (path != null) return path;
    }
    return null;
  }

  // ── 日志方法 ────────────────────────────────────────────────────────

  void debug(String message, {String? detail}) =>
      _log(LogLevel.debug, message, detail: detail);

  void info(String message, {String? detail}) =>
      _log(LogLevel.info, message, detail: detail);

  void warn(String message, {String? detail}) =>
      _log(LogLevel.warn, message, detail: detail);

  void error(
    String message, {
    String? detail,
    Object? error,
    StackTrace? stackTrace,
  }) =>
      _log(
        LogLevel.error,
        message,
        detail: detail,
        error: error,
        stackTrace: stackTrace,
      );

  void _log(
    LogLevel level,
    String message, {
    String? detail,
    Object? error,
    StackTrace? stackTrace,
  }) {
    // 实例级过滤
    if (level.index < minLevel.index) return;
    // 全局级过滤
    if (level.index < globalMinLevel.index) return;

    // 始终输出到 developer.log（控制台）
    final prefix = '[$name]';
    final levelStr = level.name.toUpperCase();
    final buffer = StringBuffer('$prefix $levelStr: $message');
    if (detail != null) buffer.write(' | $detail');
    if (error != null) buffer.write(' | Error: $error');

    developer.log(
      buffer.toString(),
      level: _levelToInt(level),
      name: name,
      error: error,
      stackTrace: stackTrace,
    );

    // 分发到已注册 sink（文件落盘等）
    if (_sinks.isNotEmpty) {
      final record = LogRecord(
        timestamp: DateTime.now(),
        level: level,
        loggerName: name,
        message: message,
        detail: detail,
        error: error,
        stackTrace: stackTrace,
      );
      for (final sink in _sinks) {
        try {
          sink.write(record);
        } catch (_) {
          // sink 故障不得影响调用方；developer.log 仍已输出
        }
      }
    }
  }

  int _levelToInt(LogLevel level) => switch (level) {
        LogLevel.debug => 500,
        LogLevel.info => 800,
        LogLevel.warn => 900,
        LogLevel.error => 1000,
      };
}
