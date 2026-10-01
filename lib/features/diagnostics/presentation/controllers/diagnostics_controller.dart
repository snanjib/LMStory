import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/storage/preferences.dart';
import 'package:lmstory/core/utils/debug_log_options.dart';
import 'package:lmstory/core/utils/log_file_ops.dart'
    if (dart.library.html) 'package:lmstory/core/utils/log_file_ops_web.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/features/diagnostics/domain/entities/failure_log_entry.dart';
import 'package:lmstory/features/diagnostics/domain/repositories/failure_log_repository.dart';
import 'package:meta/meta.dart';

/// 诊断页状态
@immutable
class DiagnosticsState {
  const DiagnosticsState({
    this.failures = const [],
    this.logLines = const [],
    this.logLevel = LogLevel.debug,
    this.debugLogOptions = const DebugLogOptions(),
    this.isLoading = false,
  });

  /// 最近 50 条失败记录（按时间倒序）
  final List<FailureLogEntry> failures;

  /// 日志文件 tail 500 行
  final List<String> logLines;

  /// 当前日志级别（运行时可调）
  final LogLevel logLevel;

  /// 调试日志多选开关（Stage 5，运行时可调）
  final DebugLogOptions debugLogOptions;

  /// 是否正在加载
  final bool isLoading;

  DiagnosticsState copyWith({
    List<FailureLogEntry>? failures,
    List<String>? logLines,
    LogLevel? logLevel,
    DebugLogOptions? debugLogOptions,
    bool? isLoading,
  }) {
    return DiagnosticsState(
      failures: failures ?? this.failures,
      logLines: logLines ?? this.logLines,
      logLevel: logLevel ?? this.logLevel,
      debugLogOptions: debugLogOptions ?? this.debugLogOptions,
      isLoading: isLoading ?? this.isLoading,
    );
  }
}

/// 诊断页控制器
///
/// 加载失败历史（failure_logs 表）+ 运行日志（FileLogSink 文件 tail），
/// 提供日志级别切换、调试日志多选开关、清空诊断数据操作。
///
/// 数据源：
/// - [FailureLogRepository]：失败记录（持久化）
/// - [Logger.currentLogFilePath]：日志文件路径（FileLogSink）
/// - [Preferences]：日志级别（key `log_level`）+ 调试日志开关（key `debug_log_*`）持久化
class DiagnosticsController extends StateNotifier<DiagnosticsState> {
  DiagnosticsController({
    required FailureLogRepository failureLogRepository,
    required Preferences preferences,
  })  : _failureLogRepository = failureLogRepository,
        _preferences = preferences,
        super(const DiagnosticsState());

  final FailureLogRepository _failureLogRepository;
  final Preferences _preferences;

  /// 加载失败历史 + 日志 tail + 当前日志级别 + 调试日志开关
  Future<void> load() async {
    state = state.copyWith(isLoading: true);
    try {
      final failures = await _failureLogRepository.getRecentLogs();
      final logLines = await _readLogTail(maxLines: 500);
      final logLevel = await _loadLogLevel();
      final debugLogOptions = await _loadDebugLogOptions();
      // 同步到 Logger 静态字段（控制器在写日志时直接读 Logger.debugOptions）
      Logger.debugOptions = debugLogOptions;
      state = DiagnosticsState(
        failures: failures,
        logLines: logLines,
        logLevel: logLevel,
        debugLogOptions: debugLogOptions,
      );
    } catch (_) {
      // 诊断页是辅助工具，加载失败不应阻塞 UI
      state = state.copyWith(isLoading: false);
    }
  }

  /// 开发者暗门门禁——诊断页尾版本行连点 7 次解锁，
  /// 持久 bool（解锁一次后续访问免再点）。
  static const String devGateKey = 'diagnostics.dev_gate_unlocked';

  Future<bool> isDevGateUnlocked() async {
    try {
      return await _preferences.getBool(devGateKey) ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> unlockDevGate() async {
    try {
      await _preferences.setBool(devGateKey, true);
    } catch (_) {}
  }

  /// 切换日志级别：持久化 + 立即生效（更新 Logger.globalMinLevel）
  Future<void> setLogLevel(LogLevel level) async {
    await _preferences.setString('log_level', level.name);
    Logger.globalMinLevel = level;
    state = state.copyWith(logLevel: level);
  }

  /// 切换单个调试日志开关：持久化 + 立即生效（更新 Logger.debugOptions）
  ///
  /// [field] 标识要切换的字段（'prompts'/'responses'/'memories'/'keywords'/'payloads'）。
  /// 切换语义为"覆盖为新值"，UI 传入当前勾选状态取反后的值。
  // ignore: avoid_positional_boolean_parameters — 与 CheckboxListTile 回调签名一致
  Future<void> setDebugLogOption(DebugLogField field, bool value) async {
    final key = _debugLogKey(field);
    await _preferences.setBool(key, value);
    final newOptions = state.debugLogOptions.copyWith(
      logPrompts: field == DebugLogField.prompts ? value : null,
      logResponses: field == DebugLogField.responses ? value : null,
      logMemories: field == DebugLogField.memories ? value : null,
      logKeywords: field == DebugLogField.keywords ? value : null,
      logPayloads: field == DebugLogField.payloads ? value : null,
    );
    Logger.debugOptions = newOptions;
    state = state.copyWith(debugLogOptions: newOptions);
  }

  /// 清空所有诊断数据：失败记录表 + 日志文件（含备份）+ 重新加载
  Future<void> clearAll() async {
    await _failureLogRepository.clearAll();
    await _clearLogFiles();
    await load();
  }

  /// 刷新日志 tail（失败历史由 load 刷新）
  Future<void> refreshLogs() async {
    final logLines = await _readLogTail(maxLines: 500);
    state = state.copyWith(logLines: logLines);
  }

  // ── 内部方法 ──────────────────────────────────────────────────────────

  Future<LogLevel> _loadLogLevel() async {
    final saved = await _preferences.getString('log_level');
    if (saved == null) return LogLevel.debug;
    return LogLevel.values.firstWhere(
      (l) => l.name == saved,
      orElse: () => LogLevel.debug,
    );
  }

  /// 从 Preferences 加载调试日志开关（未设置时默认全 false）
  Future<DebugLogOptions> _loadDebugLogOptions() {
    return loadDebugLogOptions(_preferences);
  }

  /// 从 [preferences] 装配调试日志开关。
  ///
  /// 共享加载函数：诊断页 [load] 与 main.dart 启动装配（`_initFileLogging`）
  /// 共用，保证 `debug_log_*` 五键的键名映射只有这一处事实源。
  /// 修复前启动只恢复 log_level——用户开「记录完整提示词」后重启，
  /// 运行时全关但诊断页 UI 仍显示勾选（界面与实际行为相反）。
  static Future<DebugLogOptions> loadDebugLogOptions(
    Preferences preferences,
  ) async {
    final logPrompts =
        await preferences.getBool(_debugLogKey(DebugLogField.prompts));
    final logResponses =
        await preferences.getBool(_debugLogKey(DebugLogField.responses));
    final logMemories =
        await preferences.getBool(_debugLogKey(DebugLogField.memories));
    final logKeywords =
        await preferences.getBool(_debugLogKey(DebugLogField.keywords));
    final logPayloads =
        await preferences.getBool(_debugLogKey(DebugLogField.payloads));
    return DebugLogOptions(
      logPrompts: logPrompts ?? false,
      logResponses: logResponses ?? false,
      logMemories: logMemories ?? false,
      logKeywords: logKeywords ?? false,
      logPayloads: logPayloads ?? false,
    );
  }

  /// Preferences key 映射（与 [DebugLogField] 一一对应）
  static String _debugLogKey(DebugLogField field) => switch (field) {
        DebugLogField.prompts => 'debug_log_prompts',
        DebugLogField.responses => 'debug_log_responses',
        DebugLogField.memories => 'debug_log_memories',
        DebugLogField.keywords => 'debug_log_keywords',
        DebugLogField.payloads => 'debug_log_payloads',
      };

  /// 读取日志文件最后 [maxLines] 行
  ///
  /// 原生平台通过 `compute` 在 Isolate 中执行反向随机读取，
  /// 避免一次性读取 10MB 全量日志导致 UI 线程阻塞。
  /// Web 平台返回空列表（无文件日志）。
  Future<List<String>> _readLogTail({required int maxLines}) async {
    return readLogFileTail(maxLines: maxLines);
  }

  /// 清空日志文件
  ///
  /// 原生平台：flush buffer → 清空当前文件 → 删除备份。
  /// Web 平台：no-op（无文件日志）。
  Future<void> _clearLogFiles() async {
    await clearLogFiles();
  }
}

/// 诊断页控制器 Provider
final diagnosticsControllerProvider =
    StateNotifierProvider<DiagnosticsController, DiagnosticsState>(
  (ref) => DiagnosticsController(
    failureLogRepository: ref.read(failureLogRepositoryProvider),
    preferences: ref.read(preferencesProvider),
  ),
);
