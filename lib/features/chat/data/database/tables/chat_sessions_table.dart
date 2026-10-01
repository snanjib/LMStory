import 'package:drift/drift.dart';

/// chat_sessions 表定义
/// 存储聊天会话，包含 9 个会话级可空设置字段
class ChatSessionsTable extends Table {
  @override
  String get tableName => 'chat_sessions';

  IntColumn get id => integer().autoIncrement()();
  TextColumn get sessionId => text().withLength(min: 1).unique()();
  TextColumn get title => text().withLength(min: 1)();
  // 会话模式：'chat'（对话模式）/ 'intermediate'（故事模式）/ 'advanced'（高级模式，v0.3）
  // 默认 'chat'（v0.2 起，原 'simple' 已废弃）
  TextColumn get mode => text().withDefault(const Constant<String>('chat'))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastActiveAt =>
      dateTime().withDefault(currentDateAndTime)();
  IntColumn get messageCount => integer().withDefault(const Constant(0))();

  // 会话级可空设置字段（NULL = 使用全局默认）
  TextColumn get modelId => text().nullable()();
  TextColumn get presetId => text().nullable()();
  TextColumn get systemPromptOverride => text().nullable()();
  RealColumn get temperature => real().nullable()();
  RealColumn get topP => real().nullable()();
  IntColumn get maxTokens => integer().nullable()();
  BoolColumn get autoCompaction => boolean().nullable()();
  RealColumn get compactionThreshold => real().nullable()();
  BoolColumn get streamEnabled => boolean().nullable()();
  IntColumn get maxContextMessages => integer().nullable()();

  /// 单次请求 token 上限（v0.2，2026-07-29 新增）
  ///
  /// 限制每次 LLM 请求实际塞入的 token 数。NULL = 使用全局默认或模型窗口。
  /// 取 min(配置值, 模型窗口)，避免配置超过模型能力。
  /// 用于应对 TPM 限制（如腾讯云 500万 TPM）：模型窗口虽大（如 GLM5.2 = 1M），
  /// 但单次请求塞太多会触发 TPM 429。用户可通过此配置主动限制。
  /// 仅故事模式 generating/reviewing 阶段生效。
  IntColumn get effectiveContextLimit => integer().nullable()();

  // 思考预算档位（disabled/low/medium/high），NULL = 使用全局默认
  // 仅对具备 reasoning 能力的模型生效
  TextColumn get reasoningEffort => text().nullable()();
  // 工具调用会话级覆盖（NULL = 使用全局默认，V2 四步流程）
  // true = 强制启用工具调用（extracting/summarizing 优先工具调用）；
  // false = 强制禁用，直接用 JSON 模式；
  // NULL = 跟随 intermediate.stream.tool_calling_enabled 全局配置。
  // 仅 intermediate 模式生效。字段名保留兼容（语义已从"JSON模式"迁移到"工具调用"）。
  BoolColumn get jsonModeOverride => boolean().nullable()();

  // 存在惩罚（presence_penalty，OpenAI 兼容参数，2026-07-18 新增）
  // NULL = 使用全局默认（intermediate.generation.presence_penalty 或 broadcast_chat 兜底）。
  // 取值范围 -2.0 ~ 2.0。鼓励 LLM 谈论新话题，避免剧情单调。
  RealColumn get presencePenalty => real().nullable()();

  // 频率惩罚（frequency_penalty，OpenAI 兼容参数，2026-07-18 新增）
  // NULL = 使用全局默认。取值范围 -2.0 ~ 2.0。
  // 减少 LLM 重复用词，避免描写冗余。
  RealColumn get frequencyPenalty => real().nullable()();

  // ── 故事模式会话级分步骤模型配置（schemaVersion ≥ 23，2026-07-21 新增）
  //
  // 4 个生成步骤（generating/extracting/reviewing/summarizing）各自独立的
  // preset+model 覆盖。NULL = 使用全局步骤配置（intermediate.phase_models.*）。
  //
  // 设计变更：删除原 intermediate.model_id/preset_id 中间层后，
  // 故事模式模型配置优先级简化为：会话级 phase > 全局 phase。
  // 没配就报错或走降级，不再回退到 Simple 模式默认。
  TextColumn get generatingPresetId => text().nullable()();
  TextColumn get generatingModelId => text().nullable()();
  TextColumn get extractingPresetId => text().nullable()();
  TextColumn get extractingModelId => text().nullable()();
  TextColumn get reviewingPresetId => text().nullable()();
  TextColumn get reviewingModelId => text().nullable()();
  TextColumn get summarizingPresetId => text().nullable()();
  TextColumn get summarizingModelId => text().nullable()();

  BoolColumn get isStarred => boolean().withDefault(const Constant(false))();
  RealColumn get sortOrder => real().withDefault(const Constant(0))();

  /// 当前叙事时间（v0.2 叙事时间机制，2026-07-25 新增）
  ///
  /// 记录会话当前的故事内时间（如"来公寓第三天"），每轮 summarizing
  /// 阶段由 LLM 输出并更新。null 表示尚未建立叙事时间（首轮或重置后）。
  TextColumn get currentNarrativeTime => text().nullable()();

  // ── 推荐回复会话级配置（schemaVersion ≥ 30，2026-07-29 新增）
  //
  // 推荐回复功能：点击按钮后调用 LLM 生成 3 条候选用户回复，
  // 浮出气泡供用户选择，点击某条填充到输入框光标位置。
  //
  // 优先级：会话级 suggest_reply_* > 全局 intermediate.suggest_reply.*
  // NULL = 使用全局配置；全局也未配置时 fallback 到 generating 阶段模型。
  //
  // prompt_override：会话级提示词覆盖，NULL = 使用全局提示词或内置默认。
  TextColumn get suggestReplyPresetId => text().nullable()();
  TextColumn get suggestReplyModelId => text().nullable()();
  TextColumn get suggestReplyPromptOverride => text().nullable()();

  // schemaVersion ≥ 31：故事模式架构调整会话级配置（3 列）
  // v0.2.2 架构调整：审查开关 + 上下文预算会话级覆盖，NULL = 使用全局默认
  BoolColumn get reviewEnabledOverride => boolean().nullable()();
  RealColumn get recentMinRatioOverride => real().nullable()();
  RealColumn get retrievalRatioOverride => real().nullable()();
  // schemaVersion ≥ 34：压缩触发线会话级覆盖（DOC-14 §3.3），NULL = 跟随全局
  RealColumn get compactionTriggerRatioOverride => real().nullable()();
  // schemaVersion ≥ 39：导演模式每轮最大步数（Agent Loop 预算），NULL = 使用默认 8
  IntColumn get maxSteps => integer().nullable()();
  // schemaVersion ≥ 42：导演模式剧情锚 JSON（体验重构卡片 C：当前弧线/伏笔
  // 清单/叙事时间/一句主线，只由 AI 经 update_story_anchor 维护）
  TextColumn get storyAnchor => text().nullable()();
  // schemaVersion ≥ 43：导演模式监督模式开关（体验重构 ：写/控制档工具
  // 执行前走审批 seam），NULL = 默认关
  BoolColumn get watchMode => boolean().nullable()();
  // schemaVersion ≥ 44：导演模式工具权限（JSON {工具名: allow|ask|deny}，
  // NULL = 跟随全局 advanced.tools；watchMode 的泛化，旧列保留不删不读）
  TextColumn get toolPermissions => text().nullable()();
  // schemaVersion ≥ 44：导演模式单轮时间预算会话覆盖（分钟，NULL = 跟随全局）
  IntColumn get maxDurationMinutes => integer().nullable()();
  // schemaVersion ≥ 46：剧情节奏档会话覆盖（conservative|balanced|aggressive，
  // NULL = 跟随全局 advanced.narrative_pacing；剧情节奏档位设计 §5.3）
  TextColumn get narrativePacing => text().nullable()();
  // schemaVersion ≥ 47：下一轮轮次号（turn 单一事实源）。
  // 会话级唯一轮次来源：persist 事务内写为「本轮 turnNumber + 1」，
  // deleteRoundAndDownstream 写为被删起始轮号；NULL = 存量会话未物化，
  // 运行时按「压缩基数 + 可见对话轮数 + 1」公式惰性回退（写入后即物化）。
  IntColumn get nextTurn => integer().nullable()();

  // 导演会话「检索松紧度」快照（JSON：
  // {"top_k": int, "vector_score_threshold": double}，具体值快照语义，
  // 选中即写入、与档位预设互不影响；NULL = 存量会话未物化，消费方
  // 回落内置默认值）。经 repairSchema 开库补列（纯增量，无版本 bump）。
  TextColumn get retrievalOverrides => text().nullable()();
}
