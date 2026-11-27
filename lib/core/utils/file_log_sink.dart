import 'dart:async';
import 'dart:io';

import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/core/utils/secret_redactor.dart';

/// 文件日志 sink：将日志写入文件，按大小轮转。
///
/// 设计要点：
/// - **同步写入**：[write] 直接用 [File.writeAsStringSync] 追加写入，
///   完全放弃 IOSink 异步缓冲。Android 平台 IOSink 初始化会写入若干
///   null 字节作为缓冲副产物，导致日志文件前部出现方块乱码（2026-07-26
///   修复历史问题）。同步写入略慢但保证 0 null 字节。
/// - **按大小轮转**：当前文件超过 [maxFileSize] 时，重命名为 `.1` 备份，
///   原 `.1` → `.2`，依此类推，保留 [maxBackupCount] 份。
/// - **init 前丢弃**：[write] 在 [init] 完成前为 no-op，避免初始化竞态。
/// - **每次启动清空旧日志**：[init] 用 `FileMode.write`（截断）打开文件，
///   避免历史日志累积导致文件膨胀。用户需要持久日志可使用"数据管理 → 导出"。
/// - **显式 UTF-8 编码**：避免 Windows GBK 编码问题。
///
/// 生命周期：`init()` → 多次 `write()` → 定时 `flush()` → `dispose()`
class FileLogSink implements LogSink {
  FileLogSink({
    required this.directoryPath,
    this.maxFileSize = 10 * 1024 * 1024, // 10MB
    this.maxBackupCount = 1,
    this.flushInterval = const Duration(seconds: 3),
    this.fileName = 'app.log',
  });

  /// 日志目录路径（由 path_provider 提供应用文档目录）。
  final String directoryPath;

  /// 单文件最大字节数，超过则轮转。默认 10MB。
  final int maxFileSize;

  /// 保留的备份文件数（.1, .2, ... .N）。默认 1（当前 + 1 备份 = 2 文件，共 20MB）。
  final int maxBackupCount;

  /// 定时刷盘间隔。默认 3 秒（同步写入模式下仅用于轮转检查）。
  final Duration flushInterval;

  /// 日志文件名（不含目录路径）。默认 `app.log`。
  final String fileName;

  File? _file;
  final List<String> _buffer = [];
  Timer? _timer;
  bool _initialized = false;

  /// 初始化：创建目录、清空旧文件、启动定时轮转检查。
  ///
  /// 必须在 [write] 之前调用。重复调用无副作用（幂等）。
  ///
  /// **重要**：使用 `FileMode.write`（截断模式）同步清空文件，每次 app 启动
  /// 会清空旧日志。这避免了以下问题：
  /// - 历史日志累积导致文件膨胀
  /// - 旧日志中可能存在的 null 字节（IOSink 副产物）干扰排查
  /// - 跨版本日志格式不一致
  /// 用户需要持久日志可使用"数据管理 → 导出"功能。
  Future<void> init() async {
    if (_initialized) return;
    final dir = Directory(directoryPath);
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    _file = File('${dir.path}/$fileName');
    //  修复：启动时轮转而非截断清零——崩溃后重启即销毁
    // 上次运行日志，恰恰是最需要日志的场景无法溯源。改为：现有日志
    // 轮转为 .1 备份（复用 _rotate 链，超龄自动淘汰），新会话以追加模式
    // 写入新文件。null 字节问题（IOSink 副产物）不受影响：新文件仍由
    // 同步 writeAsStringSync 创建，从未经过 IOSink。
    if (_file!.existsSync() && await _file!.length() > 0) {
      await _rotate();
    } else {
      _file!.writeAsStringSync('', flush: true);
    }
    _timer = Timer.periodic(flushInterval, (_) => _checkRotation());
    _initialized = true;
  }

  @override
  void write(LogRecord record) {
    if (!_initialized) return;
    // Routine errors and retries can carry request data inside exception text.
    final line = redactDiagnosticText(_sanitizeForFile(record.toLine()));
    // 同步追加写入，无缓冲，无 null 字节残留
    _file!.writeAsStringSync(
      '$line\n',
      mode: FileMode.append,
      flush: true,
    );
    _buffer.add(line);
    // 缓冲仅用于轮转检查计数，不再用于延迟写入
    if (_buffer.length > 1000) _buffer.removeRange(0, _buffer.length - 100);
  }

  /// 过滤文件落盘时的 ASCII 控制字符，避免日志文件出现乱码。
  ///
  /// 移除范围：0x00-0x08 / 0x0B-0x1F / 0x7F（NULL、BEL、BOM、零宽字符等）。
  /// 保留：0x0A (`\n`，行分隔) 与 0x09 (`\t`，表格对齐)。
  ///
  /// 这些控制字符通常来自 LLM 输出（零宽字符、BOM、特殊符号等），
  /// 落盘后用 txt 编辑器打开会显示为方块码或不可见字符。
  ///
  /// 注意：`developer.log` 控制台输出仍保留原始字符，方便调试。
  static String _sanitizeForFile(String s) {
    return s.replaceAll(RegExp(r'[\x00-\x08\x0B-\x1F\x7F]'), '');
  }

  /// 当前日志文件的完整路径（诊断页读取/分享用）。
  ///
  /// init 前返回 null。
  @override
  String? get currentFilePath => _file?.path;

  @override
  Future<void> flush() => _checkRotation();

  /// 检查是否需要轮转（同步写入模式下，写入已经实时落盘）。
  Future<void> _checkRotation() async {
    if (_file == null) return;
    final size = await _file!.length();
    if (size >= maxFileSize) {
      await _rotate();
    }
  }

  /// 轮转：重命名链 → 创建新文件。
  ///
  /// app.log → app.log.1 → app.log.2 → ... → 超出 [maxBackupCount] 的删除。
  Future<void> _rotate() async {
    // 从最旧开始逐级重命名，避免覆盖
    for (var i = maxBackupCount; i >= 1; i--) {
      final current = File('${_file!.path}.$i');
      if (i == maxBackupCount) {
        // 最旧的备份直接删除
        if (current.existsSync()) await current.delete();
      } else {
        // app.log.N → app.log.(N+1)
        if (current.existsSync()) {
          final next = File('${_file!.path}.${i + 1}');
          await current.rename(next.path);
        }
      }
    }

    // 当前文件 → app.log.1
    final backup = File('${_file!.path}.1');
    if (backup.existsSync()) await backup.delete();
    await _file!.rename(backup.path);

    // 创建新的 app.log（同步清空）
    _file = File(_file!.path);
    _file!.writeAsStringSync('', flush: true);
  }

  @override
  Future<void> dispose() async {
    _timer?.cancel();
    _timer = null;
    _initialized = false;
  }
}
