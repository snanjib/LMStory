/// 调试日志多选开关（Stage 5）
///
/// 中级模式排障专用：用户在诊断页勾选需要详细记录的调试信息类别，
/// 勾选后 Logger 的 `debugOptions` 静态字段同步更新，控制器在关键点按需写入日志文件。
///
/// 默认全关（避免日志膨胀）；按需开启后重启会话生效。
/// 与 Logger 的 `globalMinLevel` 互补：
/// - `globalMinLevel` 控制级别过滤（debug/info/warn/error）
/// - `debugOptions` 控制详细字段开关（提示词/响应/记忆/关键词/负载）
///
/// 5 个开关对应中级模式四步生成的关键点：
/// - [DebugLogOptions.logPrompts]：generating/reviewing 阶段拼接好的完整 messages（含 system/history/user）
/// - [DebugLogOptions.logResponses]：reviewing 阶段解析出的最终 reply + EventSummary
/// - [DebugLogOptions.logMemories]：retrieving 阶段检索到的 ScoredMemory 列表（含分数）
/// - [DebugLogOptions.logKeywords]：generating 阶段解析出的关键词列表
/// - [DebugLogOptions.logPayloads]：每次 LLM 调用的完整 request/response body（含阶段标注）
class DebugLogOptions {
  const DebugLogOptions({
    this.logPrompts = false,
    this.logResponses = false,
    this.logMemories = false,
    this.logKeywords = false,
    this.logPayloads = false,
  });

  /// 记录拼接好的完整 LLM 请求 messages
  final bool logPrompts;

  /// 记录解析后的最终回复 + 事件摘要
  final bool logResponses;

  /// 记忆检索结果（含分数）
  final bool logMemories;

  /// 生成阶段解析出的关键词
  final bool logKeywords;

  /// 记录每次 LLM 调用的完整 request/response body（2026-08-04 新增）
  ///
  /// 开启后，在流式调用开始时记录完整请求 messages（含阶段标注），
  /// 在流结束时记录响应摘要（正文长度、思考长度、耗时）。
  /// 超长内容截断到 2000 字符避免日志膨胀。
  final bool logPayloads;

  /// 是否全部关闭（用于跳过无意义的日志拼接开销）
  bool get allDisabled =>
      !logPrompts &&
      !logResponses &&
      !logMemories &&
      !logKeywords &&
      !logPayloads;

  /// 复制并覆盖单个字段
  ///
  /// 利用 nullable bool 区分"未提供"（保持原值）与"显式 false"：
  /// `copyWith(logPrompts: true)` -> 只改 logPrompts，其他保持
  /// `copyWith(logPrompts: false)` -> 显式关闭 logPrompts
  /// `copyWith()` -> 全部保持原值
  DebugLogOptions copyWith({
    bool? logPrompts,
    bool? logResponses,
    bool? logMemories,
    bool? logKeywords,
    bool? logPayloads,
  }) {
    return DebugLogOptions(
      logPrompts: logPrompts ?? this.logPrompts,
      logResponses: logResponses ?? this.logResponses,
      logMemories: logMemories ?? this.logMemories,
      logKeywords: logKeywords ?? this.logKeywords,
      logPayloads: logPayloads ?? this.logPayloads,
    );
  }

  @override
  String toString() =>
      'DebugLogOptions(prompts=$logPrompts, responses=$logResponses, '
      'memories=$logMemories, keywords=$logKeywords, payloads=$logPayloads)';
}

/// 调试日志开关字段标识（Stage 5）
///
/// 用于诊断控制器的 `setDebugLogOption` 标识要切换的字段，
/// 避免在控制器方法签名中暴露 5 个独立的 setter 或字符串参数。
///
/// 与 [DebugLogOptions] 的 5 个 bool 字段一一对应。
enum DebugLogField {
  prompts,
  responses,
  memories,
  keywords,
  payloads,
}
