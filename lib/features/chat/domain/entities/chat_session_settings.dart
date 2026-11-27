import 'package:lmstory/features/chat/domain/entities/chat_session.dart'
    show ChatSession;
import 'package:lmstory/features/chat/domain/entities/reasoning_effort.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart'
    show ConfigurationResolver;
import 'package:lmstory/features/chat/domain/services/llm_service.dart'
    show LlmService;

/// 会话设置解析结果
///
/// 用于统一解析会话级设置，当会话设置为 NULL 时使用全局默认值。
class ChatSessionSettings {
  const ChatSessionSettings({
    required this.modelId,
    required this.presetId,
    required this.systemPrompt,
    required this.temperature,
    required this.topP,
    required this.maxTokens,
    required this.autoCompaction,
    required this.compactionThreshold,
    required this.streamEnabled,
    this.maxContextMessages,
    this.effectiveContextLimit,
    this.reasoningEffort,
    this.presencePenalty,
    this.frequencyPenalty,
    // 审查会话级覆盖（透传，null = 用全局 reviewEnabled）
    this.reviewEnabledOverride,
    // 审查  修复：contextBudget 会话级覆盖（透传）
    this.recentMinRatioOverride,
    this.retrievalRatioOverride,
    // DOC-14 §3.3：压缩触发线会话级覆盖（透传）
    this.compactionTriggerRatioOverride,
    // 工程上下文模式开关（导演实验，透传 null = 关闭态）
    this.engineeringContextEnabled,
  });

  /// 模型 ID
  final String modelId;

  /// 预设 ID
  final String presetId;

  /// 系统提示词
  final String systemPrompt;

  /// 温度参数
  final double temperature;

  /// top_p 参数
  final double topP;

  /// 最大 token 数
  final int maxTokens;

  /// 是否自动压缩
  final bool autoCompaction;

  /// 压缩阈值百分比（0.4-0.9，默认 0.6）
  ///
  /// 对标 ChatBox compactionThreshold。阈值公式：
  /// ```text
  /// availableWindow = max(contextWindow - 32000, floor(contextWindow × 0.5))
  /// thresholdTokens = floor(availableWindow × compactionThreshold)
  /// isOverflow = (currentTokens > thresholdTokens)
  /// ```
  final double compactionThreshold;

  /// 是否启用流式
  final bool streamEnabled;

  /// 最大上下文消息数（null = 无限制）
  final int? maxContextMessages;

  /// 单次请求 token 上限（v0.2，2026-07-29 新增）
  ///
  /// 限制每次 LLM 请求实际塞入的 token 数，取 min(配置值, 模型窗口)。
  /// null = 使用模型窗口（保持原行为）。用于应对 TPM 限制。
  /// 仅故事模式 generating/reviewing 阶段生效。
  final int? effectiveContextLimit;

  /// 思考预算档位（null = 不发送 reasoning_effort 参数）
  ///
  /// 由会话级 reasoningEffort 与全局默认合并得出。null 表示既未在会话级
  /// 配置也未在全局配置（此时不发送 reasoning_effort 参数，由模型自行决定）。
  /// disabled 表示显式禁用思考（不发送参数或发送 none，取决于模型）。
  final ReasoningEffort? reasoningEffort;

  /// 存在惩罚（presence_penalty，2026-07-18 新增）
  ///
  /// OpenAI 兼容 API 参数。null 表示不向 API 发送此参数（由模型自行决定）。
  /// 取值范围 -2.0 ~ 2.0，正值鼓励 LLM 谈论新话题。
  ///
  /// 解析优先级（故事模式）：
  /// 会话级 > intermediate.generation.presencePenalty > null
  ///
  /// 解析后非 null 时由 [LlmService] 注入到请求体 `presence_penalty` 字段。
  final double? presencePenalty;

  /// 频率惩罚（frequency_penalty，2026-07-18 新增）
  ///
  /// OpenAI 兼容 API 参数。null 表示不向 API 发送此参数。
  /// 取值范围 -2.0 ~ 2.0，正值减少 LLM 重复用词。
  ///
  /// 解析优先级（故事模式）：
  /// 会话级 > intermediate.generation.frequencyPenalty > null
  ///
  /// 解析后非 null 时由 [LlmService] 注入到请求体 `frequency_penalty` 字段。
  final double? frequencyPenalty;

  /// 审查会话级覆盖（新增）
  ///
  /// 透传 [ChatSession.reviewEnabledOverride] 的值，不做解析合并。
  /// 控制器在使用时自行做 `?? config.reviewEnabled` 回退：
  /// - `null`（默认）：使用全局 `intermediate.reviewEnabled`
  /// - `true`：强制启用 reviewing（4 次 LLM 调用）
  /// - `false`：强制跳过 reviewing（3 次 LLM 调用，生成即最终）
  ///
  /// 与 [maxContextMessages] 一样属于"未解析透传"字段（保留 nullable 语义
  /// 供控制器判断是否需要回退到全局配置），而非像 [temperature] 那样在
  /// [ConfigurationResolver] 中已合并为非 null 值。
  final bool? reviewEnabledOverride;

  /// 原文区下限比例会话级覆盖（审查  修复，2026-07-31）
  ///
  /// 透传 [ChatSession.recentMinRatioOverride] 的值，不做解析合并。
  /// - `null`（默认）：使用全局 `intermediate.contextBudget.recentMinRatio`
  /// - 非 null：使用此值作为原文区下限比例
  final double? recentMinRatioOverride;

  /// 检索区比例会话级覆盖（审查  修复，2026-07-31）
  ///
  /// 透传 [ChatSession.retrievalRatioOverride] 的值，不做解析合并。
  /// - `null`（默认）：使用全局 `intermediate.contextBudget.retrievalRatio`
  /// - 非 null：使用此值作为检索区比例
  final double? retrievalRatioOverride;

  /// 压缩触发线会话级覆盖（DOC-14 §3.3）
  ///
  /// 透传 [ChatSession.compactionTriggerRatioOverride] 的值，不做解析合并。
  /// - `null`（默认）：使用全局 `intermediate.contextBudget.compactionTriggerRatio`
  /// - 非 null：使用此值作为压缩触发线比例
  final double? compactionTriggerRatioOverride;

  /// 工程上下文模式开关（导演实验）
  ///
  /// 透传 [ChatSession.engineeringContextEnabled]（null = 关闭态）。
  /// 仅导演模式消费；三态对账以控制器解析结果为准，本字段只作轮内
  /// 上下文携带（关闭态恒 null/false，请求体不受影响）。
  final bool? engineeringContextEnabled;
}
