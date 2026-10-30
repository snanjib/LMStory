import 'package:lmstory/features/chat/domain/entities/reasoning_effort.dart';
import 'package:lmstory/features/chat/domain/entities/session_phase_models.dart';
import 'package:lmstory/features/chat/domain/entities/story_anchor.dart';
import 'package:meta/meta.dart';

/// 聊天会话实体
///
/// 表示一个聊天会话，包含会话级别的配置设置。
/// 可空字段为 NULL 时使用全局默认配置。
@immutable
class ChatSession {
  const ChatSession({
    required this.sessionId,
    required this.title,
    required this.mode,
    required this.createdAt,
    required this.lastActiveAt,
    required this.messageCount,
    this.modelId,
    this.presetId,
    this.systemPromptOverride,
    this.temperature,
    this.topP,
    this.maxTokens,
    this.presencePenalty,
    this.frequencyPenalty,
    this.autoCompaction,
    this.compactionThreshold,
    this.streamEnabled,
    this.maxContextMessages,
    this.effectiveContextLimit,
    this.reasoningEffort,
    this.jsonModeOverride,
    this.phaseModels = const SessionPhaseModels.empty(),
    this.lastMessagePreview,
    this.isStarred = false,
    this.sortOrder = 0.0,
    this.currentNarrativeTime,
    this.suggestReplyPresetId,
    this.suggestReplyModelId,
    this.suggestReplyPromptOverride,
    // schemaVersion ≥ 31：故事模式架构调整会话级配置
    this.reviewEnabledOverride,
    // 审查  修复：补全 contextBudget 会话级覆盖字段
    this.recentMinRatioOverride,
    this.retrievalRatioOverride,
    // DOC-14 §3.3（schemaVersion ≥ 34）：压缩触发线会话级覆盖
    this.compactionTriggerRatioOverride,
    // v0.3 导演模式（schemaVersion ≥ 39）：每轮最大步数预算
    this.maxSteps,
    // v0.3 体验重构卡片 C（schemaVersion ≥ 42）：剧情锚（AI 维护）
    this.storyAnchor,
    // v0.3 体验重构 （schemaVersion ≥ 43）：监督模式（写前审批）
    this.watchMode,
    // v0.3 导演设置体系（schemaVersion ≥ 44）：工具权限 JSON map
    //（watchMode 的泛化）+ 单轮时间预算会话覆盖（分钟）
    this.toolPermissions,
    this.maxDurationMinutes,
    // v0.3 剧情节奏档（schemaVersion ≥ 46）：会话覆盖，NULL=跟随全局
    this.narrativePacing,
    //  turn 单一事实源（schemaVersion ≥ 47）：下一轮轮次号计数器。
    // NULL = 存量会话未物化（运行时按公式惰性回退，首次 persist 后物化）。
    this.nextTurn,
    // 导演会话「检索松紧度」快照 JSON（具体值语义）。
    // NULL = 存量会话未物化，消费方回落内置默认值。
    this.retrievalOverrides,
    // 导演向导「初始化你的角色」：自由描述原文（第 1 轮一次性注入）
    // 与所选角色卡 id（物化时应用、列值留档）。
    this.characterInitPrompt,
    this.characterInitCardId,
  });

  /// 会话唯一标识
  final String sessionId;

  /// 会话标题
  final String title;

  /// 会话模式：chat / intermediate / advanced
  ///
  /// 使用 ChatMode 常量避免 magic string。
  final String mode;

  /// 创建时间
  final DateTime createdAt;

  /// 最后活跃时间
  final DateTime lastActiveAt;

  /// 消息数量
  final int messageCount;

  /// 模型 ID（覆盖全局默认）
  final String? modelId;

  /// 预设 ID（覆盖全局默认）
  final String? presetId;

  /// 系统提示词覆盖（覆盖全局默认）
  final String? systemPromptOverride;

  /// 温度参数（覆盖全局默认）
  final double? temperature;

  /// top_p 参数（覆盖全局默认）
  final double? topP;

  /// 最大 token 数（覆盖全局默认）
  final int? maxTokens;

  /// 存在惩罚（presence_penalty，覆盖全局默认，2026-07-18 新增）
  ///
  /// 取值范围 -2.0 ~ 2.0。正值鼓励 LLM 谈论新话题。
  /// NULL = 使用全局默认（故事模式从 intermediate.generation.presence_penalty 取，
  /// Simple 模式无此字段，回退到 broadcast_chat 兜底）。
  ///
  /// 主要用于故事模式，避免剧情单调重复。
  /// 持久化：`chat_sessions.presence_penalty`（schemaVersion ≥ 20）。
  final double? presencePenalty;

  /// 频率惩罚（frequency_penalty，覆盖全局默认，2026-07-18 新增）
  ///
  /// 取值范围 -2.0 ~ 2.0。正值减少 LLM 重复用词。
  /// NULL = 使用全局默认。
  ///
  /// 主要用于故事模式，避免重复描写、口头禅。
  /// 持久化：`chat_sessions.frequency_penalty`（schemaVersion ≥ 20）。
  final double? frequencyPenalty;

  /// 是否自动压缩（覆盖全局默认）
  final bool? autoCompaction;

  /// 压缩阈值（覆盖全局默认）
  final double? compactionThreshold;

  /// 是否启用流式（覆盖全局默认）
  final bool? streamEnabled;

  /// 最大上下文消息数（覆盖全局默认，0 = 无限制）
  final int? maxContextMessages;

  /// 单次请求 token 上限（v0.2，2026-07-29 新增）
  ///
  /// 限制每次 LLM 请求实际塞入的 token 数，取 min(配置值, 模型窗口)。
  /// NULL = 使用全局默认或模型窗口。用于应对 TPM 限制（如腾讯云 500万 TPM）。
  /// 仅故事模式 generating/reviewing 阶段生效。
  /// 持久化：`chat_sessions.effective_context_limit`（schemaVersion ≥ 29）。
  final int? effectiveContextLimit;

  /// 思考预算档位（覆盖全局默认，NULL = 使用全局默认）
  ///
  /// 仅对具备 reasoning 能力的模型生效。值为 [ReasoningEffort] 枚举的 name。
  /// 参见 [ReasoningEffort] 了解档位语义。
  final ReasoningEffort? reasoningEffort;

  /// 工具调用会话级覆盖（仅 intermediate 模式生效）。
  ///
  /// 三态语义（V2 四步流程，DOC-09B §8.6 / §10.2）：
  /// - `null`（默认）：跟随全局 `intermediate.stream.tool_calling_enabled` 配置
  /// - `true`：强制启用工具调用（extracting/summarizing 优先工具调用，不兼容时降级 JSON）
  /// - `false`：强制禁用工具调用（直接使用 JSON 模式，兼容不支持的供应商）
  ///
  /// 持久化：`chat_sessions.json_mode_override`（schemaVersion ≥ 17，字段名保留兼容）。
  /// 应用位置：`IntermediateChatController._prepareAndRunRound` → `_applyToolCallingOverride`。
  final bool? jsonModeOverride;

  /// 故事模式会话级分步骤模型配置（schemaVersion ≥ 23，2026-07-21 新增）
  ///
  /// 4 个生成步骤（generating/extracting/reviewing/summarizing）各自独立的
  /// preset+model 覆盖。空值 = 使用全局步骤配置（intermediate.phase_models.*）。
  ///
  /// 设计变更：删除原 intermediate.model_id/preset_id 中间层后，
  /// 故事模式模型配置优先级简化为：会话级 phase > 全局 phase。
  /// 没配就报错或走降级，不再回退到 Simple 模式默认。
  ///
  /// 仅 intermediate 模式生效；simple 模式忽略此字段。
  final SessionPhaseModels phaseModels;

  /// Last message content preview (first 50 chars), populated by getAllSessions
  final String? lastMessagePreview;

  /// Whether the session is starred (pinned to top)
  final bool isStarred;

  /// Sort order for drag-to-reorder (lower = higher position)
  final double sortOrder;

  /// 当前叙事时间（v0.2 叙事时间机制，2026-07-25 新增）
  ///
  /// 记录会话当前的故事内时间（如"来公寓第三天"），每轮 summarizing
  /// 阶段由 LLM 输出并更新。null 表示尚未建立叙事时间（首轮或重置后）。
  ///
  /// 持久化：`chat_sessions.current_narrative_time`（schemaVersion ≥ 26）。
  final String? currentNarrativeTime;

  /// 推荐回复会话级模型供应商 ID（schemaVersion ≥ 30，2026-07-29 新增）
  ///
  /// 推荐回复功能：点击按钮调用 LLM 生成 3 条候选用户回复。
  /// NULL = 使用全局 `intermediate.suggest_reply.preset_id`；
  /// 全局也未配置时 fallback 到 generating 阶段模型。
  final String? suggestReplyPresetId;

  /// 推荐回复会话级模型 ID
  ///
  /// NULL = 使用全局 `intermediate.suggest_reply.model_id`；
  /// 全局也未配置时 fallback 到 generating 阶段模型。
  final String? suggestReplyModelId;

  /// 推荐回复会话级提示词覆盖
  ///
  /// NULL = 使用全局 `intermediate.suggest_reply.prompt` 或内置默认提示词。
  /// 非空时直接作为推荐回复的系统提示词使用。
  final String? suggestReplyPromptOverride;

  /// 审查会话级覆盖（schemaVersion ≥ 31，新增）
  ///
  /// 三态语义：
  /// - `null`（默认）：跟随全局 `intermediate.reviewEnabled` 配置
  /// - `true`：强制启用 reviewing 阶段（4 次 LLM 调用，审查修正）
  /// - `false`：强制跳过 reviewing 阶段（3 次 LLM 调用，生成即最终）
  ///
  /// 持久化：`chat_sessions.review_enabled_override`（schemaVersion ≥ 31）。
  /// 应用位置：`IntermediateChatController._runGeneratePhase` 末尾条件判断。
  final bool? reviewEnabledOverride;

  /// 原文区下限比例会话级覆盖（schemaVersion ≥ 31，审查  修复，2026-07-31）
  ///
  /// 三态语义：
  /// - `null`（默认）：跟随全局 `intermediate.contextBudget.recentMinRatio`
  /// - 非 null：使用此值作为原文区下限比例（如 0.3 = 30%）
  ///
  /// 持久化：`chat_sessions.recent_min_ratio_override`（schemaVersion ≥ 31）。
  /// 应用位置：`IntermediateChatController._applyContextBudgetOverride`。
  final double? recentMinRatioOverride;

  /// 检索区比例会话级覆盖（schemaVersion ≥ 31，审查  修复，2026-07-31）
  ///
  /// 三态语义：
  /// - `null`（默认）：跟随全局 `intermediate.contextBudget.retrievalRatio`
  /// - 非 null：使用此值作为检索区比例（如 0.15 = 15%）
  ///
  /// 持久化：`chat_sessions.retrieval_ratio_override`（schemaVersion ≥ 31）。
  /// 应用位置：`IntermediateChatController._applyContextBudgetOverride`。
  final double? retrievalRatioOverride;

  /// 压缩触发线会话级覆盖（DOC-14 §3.3，schemaVersion ≥ 34）
  ///
  /// 三态语义：
  /// - `null`（默认）：跟随全局 `intermediate.contextBudget.compactionTriggerRatio`
  /// - 非 null：使用此值作为压缩触发线比例（如 0.5 = 50%）
  ///
  /// 持久化：`chat_sessions.compaction_trigger_ratio_override`（schemaVersion ≥ 34）。
  /// 应用位置：`IntermediateChatController._applyContextBudgetOverride`。
  final double? compactionTriggerRatioOverride;

  /// v0.3 导演模式：每轮最大步数（Agent Loop 预算），null = 使用默认 8。
  ///
  /// 持久化：`chat_sessions.max_steps`（schemaVersion ≥ 39）。
  final int? maxSteps;

  /// v0.3 体验重构卡片 C：剧情锚（当前弧线/伏笔清单/叙事时间/一句主线）。
  ///
  /// 只由 AI 经 update_story_anchor 工具维护（用户无编辑入口），用于
  /// 长剧情的"将来时"载体与幕间 Recap 卡。null = 从未设锚。
  /// 持久化：`chat_sessions.story_anchor` JSON（schemaVersion ≥ 42）。
  final StoryAnchor? storyAnchor;

  /// v0.3 体验重构 ：监督模式（watch mode）。
  ///
  /// 开启后导演轮写/控制档工具执行前经审批 seam 需用户逐项确认。
  /// null = 默认关。持久化：`chat_sessions.watch_mode`（schemaVersion ≥ 43）。
  final bool? watchMode;

  /// v0.3 导演设置体系：工具权限 JSON（`{工具名: allow|ask|deny}`）。
  ///
  /// watchMode 的泛化：会话级逐工具覆盖，解析时后写优先于全局
  /// advanced.tools。null = 跟随全局。
  /// 持久化：`chat_sessions.tool_permissions`（schemaVersion ≥ 44）。
  final String? toolPermissions;

  /// v0.3 导演设置体系：单轮时间预算会话覆盖（分钟）。
  ///
  /// null = 跟随全局 advanced.budget.max_duration_minutes。
  /// 持久化：`chat_sessions.max_duration_minutes`（schemaVersion ≥ 44）。
  final int? maxDurationMinutes;

  /// v0.3 剧情节奏档：三档推进幅度会话覆盖（conservative|balanced|aggressive）。
  ///
  /// null = 跟随全局 advanced.narrative_pacing。
  /// 持久化：`chat_sessions.narrative_pacing`（schemaVersion ≥ 46）。
  final String? narrativePacing;

  /// 下一轮轮次号（turn 单一事实源，schemaVersion ≥ 47）
  ///
  /// 会话级唯一轮次来源，替代四套并存的 UI/持久化推导公式：
  /// - persistRound / persistRegeneratedRound 事务内写为「本轮 turnNumber + 1」
  /// - deleteRoundAndDownstream 事务内写为被删起始轮号（下一写复用该号）
  /// - NULL = 存量会话未物化：读取方按
  ///   「压缩基数 + 可见真实对话消息数 ~/ 2 + 1」公式惰性回退，
  ///   首次轮次写入后即物化为计数器（公式与计数器在干净状态下恒等）
  ///
  /// 持久化：`chat_sessions.next_turn`（schemaVersion ≥ 47）。
  final int? nextTurn;

  /// 导演会话「检索松紧度」快照 JSON。
  ///
  /// 具体值快照语义：选中档位即把该档具体值写入本列，此后与档位预设
  /// 定义互不影响。NULL = 存量会话未物化，消费方回落内置默认值。
  /// 语义化读写见 `DirectorSessionX.sessionRetrievalProfile`。
  /// 持久化：`chat_sessions.retrieval_overrides`（repairSchema 开库补列）。
  final String? retrievalOverrides;

  /// 导演向导「初始化你的角色」自由描述原文。
  ///
  /// 仅第 1 轮尾部一次性注入（firstTurnCharacterInitHint）；此后角色由
  /// 正文与事实层承载。NULL = 未启用。
  /// 持久化：`chat_sessions.character_init_prompt`（repairSchema 开库补列）。
  final String? characterInitPrompt;

  /// 导演向导「初始化你的角色」所选角色卡 id。
  ///
  /// 草稿物化时应用卡（资料通道建基线实体），本列留档供排查；
  /// 运行时不再消费。NULL = 未启用。
  /// 持久化：`chat_sessions.character_init_card_id`（repairSchema 开库补列）。
  final String? characterInitCardId;

  /// Sentinel value used by [copyWith] to distinguish "not provided" from
  /// "explicitly null" for nullable fields.
  static const _sentinel = Object();

  /// 创建副本并应用修改。
  ///
  /// Nullable fields (modelId, systemPromptOverride, etc.) can be explicitly
  /// set to null by passing null — this is different from omitting the
  /// parameter, which keeps the existing value.
  ChatSession copyWith({
    Object? sessionId = _sentinel,
    Object? title = _sentinel,
    Object? mode = _sentinel,
    Object? createdAt = _sentinel,
    Object? lastActiveAt = _sentinel,
    Object? messageCount = _sentinel,
    Object? modelId = _sentinel,
    Object? presetId = _sentinel,
    Object? systemPromptOverride = _sentinel,
    Object? temperature = _sentinel,
    Object? topP = _sentinel,
    Object? maxTokens = _sentinel,
    Object? presencePenalty = _sentinel,
    Object? frequencyPenalty = _sentinel,
    Object? autoCompaction = _sentinel,
    Object? compactionThreshold = _sentinel,
    Object? streamEnabled = _sentinel,
    Object? maxContextMessages = _sentinel,
    Object? effectiveContextLimit = _sentinel,
    Object? reasoningEffort = _sentinel,
    Object? jsonModeOverride = _sentinel,
    Object? phaseModels = _sentinel,
    Object? lastMessagePreview = _sentinel,
    Object? isStarred = _sentinel,
    Object? sortOrder = _sentinel,
    Object? currentNarrativeTime = _sentinel,
    Object? suggestReplyPresetId = _sentinel,
    Object? suggestReplyModelId = _sentinel,
    Object? suggestReplyPromptOverride = _sentinel,
    Object? reviewEnabledOverride = _sentinel,
    Object? recentMinRatioOverride = _sentinel,
    Object? retrievalRatioOverride = _sentinel,
    Object? compactionTriggerRatioOverride = _sentinel,
    Object? maxSteps = _sentinel,
    Object? storyAnchor = _sentinel,
    Object? watchMode = _sentinel,
    Object? toolPermissions = _sentinel,
    Object? maxDurationMinutes = _sentinel,
    Object? narrativePacing = _sentinel,
    Object? nextTurn = _sentinel,
    Object? retrievalOverrides = _sentinel,
    Object? characterInitPrompt = _sentinel,
    Object? characterInitCardId = _sentinel,
  }) {
    return ChatSession(
      sessionId:
          sessionId == _sentinel ? this.sessionId : (sessionId as String?)!,
      title: title == _sentinel ? this.title : (title as String?)!,
      mode: mode == _sentinel ? this.mode : (mode as String?)!,
      createdAt:
          createdAt == _sentinel ? this.createdAt : (createdAt as DateTime?)!,
      lastActiveAt: lastActiveAt == _sentinel
          ? this.lastActiveAt
          : (lastActiveAt as DateTime?)!,
      messageCount: messageCount == _sentinel
          ? this.messageCount
          : (messageCount as int?)!,
      modelId: modelId == _sentinel ? this.modelId : modelId as String?,
      presetId: presetId == _sentinel ? this.presetId : presetId as String?,
      systemPromptOverride: systemPromptOverride == _sentinel
          ? this.systemPromptOverride
          : systemPromptOverride as String?,
      temperature:
          temperature == _sentinel ? this.temperature : temperature as double?,
      topP: topP == _sentinel ? this.topP : topP as double?,
      maxTokens: maxTokens == _sentinel ? this.maxTokens : maxTokens as int?,
      presencePenalty: presencePenalty == _sentinel
          ? this.presencePenalty
          : presencePenalty as double?,
      frequencyPenalty: frequencyPenalty == _sentinel
          ? this.frequencyPenalty
          : frequencyPenalty as double?,
      autoCompaction: autoCompaction == _sentinel
          ? this.autoCompaction
          : autoCompaction as bool?,
      compactionThreshold: compactionThreshold == _sentinel
          ? this.compactionThreshold
          : compactionThreshold as double?,
      streamEnabled: streamEnabled == _sentinel
          ? this.streamEnabled
          : streamEnabled as bool?,
      maxContextMessages: maxContextMessages == _sentinel
          ? this.maxContextMessages
          : maxContextMessages as int?,
      effectiveContextLimit: effectiveContextLimit == _sentinel
          ? this.effectiveContextLimit
          : effectiveContextLimit as int?,
      reasoningEffort: reasoningEffort == _sentinel
          ? this.reasoningEffort
          : reasoningEffort as ReasoningEffort?,
      jsonModeOverride: jsonModeOverride == _sentinel
          ? this.jsonModeOverride
          : jsonModeOverride as bool?,
      phaseModels: phaseModels == _sentinel
          ? this.phaseModels
          : phaseModels! as SessionPhaseModels,
      lastMessagePreview: lastMessagePreview == _sentinel
          ? this.lastMessagePreview
          : lastMessagePreview as String?,
      isStarred: isStarred == _sentinel
          ? this.isStarred
          : (isStarred as bool?) ?? this.isStarred,
      sortOrder: sortOrder == _sentinel
          ? this.sortOrder
          : (sortOrder as double?) ?? this.sortOrder,
      currentNarrativeTime: currentNarrativeTime == _sentinel
          ? this.currentNarrativeTime
          : currentNarrativeTime as String?,
      suggestReplyPresetId: suggestReplyPresetId == _sentinel
          ? this.suggestReplyPresetId
          : suggestReplyPresetId as String?,
      suggestReplyModelId: suggestReplyModelId == _sentinel
          ? this.suggestReplyModelId
          : suggestReplyModelId as String?,
      suggestReplyPromptOverride: suggestReplyPromptOverride == _sentinel
          ? this.suggestReplyPromptOverride
          : suggestReplyPromptOverride as String?,
      reviewEnabledOverride: reviewEnabledOverride == _sentinel
          ? this.reviewEnabledOverride
          : reviewEnabledOverride as bool?,
      recentMinRatioOverride: recentMinRatioOverride == _sentinel
          ? this.recentMinRatioOverride
          : recentMinRatioOverride as double?,
      retrievalRatioOverride: retrievalRatioOverride == _sentinel
          ? this.retrievalRatioOverride
          : retrievalRatioOverride as double?,
      compactionTriggerRatioOverride:
          compactionTriggerRatioOverride == _sentinel
              ? this.compactionTriggerRatioOverride
              : compactionTriggerRatioOverride as double?,
      maxSteps: maxSteps == _sentinel ? this.maxSteps : maxSteps as int?,
      storyAnchor: storyAnchor == _sentinel
          ? this.storyAnchor
          : storyAnchor as StoryAnchor?,
      watchMode: watchMode == _sentinel ? this.watchMode : watchMode as bool?,
      toolPermissions: toolPermissions == _sentinel
          ? this.toolPermissions
          : toolPermissions as String?,
      maxDurationMinutes: maxDurationMinutes == _sentinel
          ? this.maxDurationMinutes
          : maxDurationMinutes as int?,
      narrativePacing: narrativePacing == _sentinel
          ? this.narrativePacing
          : narrativePacing as String?,
      nextTurn: nextTurn == _sentinel ? this.nextTurn : nextTurn as int?,
      retrievalOverrides: retrievalOverrides == _sentinel
          ? this.retrievalOverrides
          : retrievalOverrides as String?,
      characterInitPrompt: characterInitPrompt == _sentinel
          ? this.characterInitPrompt
          : characterInitPrompt as String?,
      characterInitCardId: characterInitCardId == _sentinel
          ? this.characterInitCardId
          : characterInitCardId as String?,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChatSession && other.sessionId == sessionId;

  @override
  int get hashCode => sessionId.hashCode;
}
