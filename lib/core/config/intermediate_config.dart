import 'package:lmstory/core/config/intermediate_prompts.dart';
import 'package:lmstory/core/config/intermediate_prompts_v2.dart';
import 'package:lmstory/core/config/output_token_policy.dart';

/// 中级模式配置（顶层聚合）
///
/// 对应 default_config.json 的 `intermediate` 顶层 key。
/// 与 Simple 模式的 BroadcastChatConfig 平级，互不影响。
///
/// **2026-07-21 配置架构重构**：删除原顶层 `model_id` / `preset_id` 字段
/// （即"故事模式默认模型"中间层）。重构后故事模式仅保留两层模型配置：
/// - 会话级：`chat_sessions.{phase}_preset_id` / `{phase}_model_id`（8 列）
/// - 全局级：`intermediate.phase_models.{phase}_preset_id` / `{phase}_model_id`
/// 优先级：会话级 > 全局级；都没配置时直接报错，不再回退到 broadcastChat。
/// 标题生成模型独立于故事模式，统一在 `common.title_model` 中配置。
///
/// Schema 依据：DOC-09B §10（新增 `prompts` 子节点）。
/// 序列化方式：手写 fromJson（与 AppConfig 风格一致，不用 json_serializable）。
class IntermediateConfig {
  const IntermediateConfig({
    this.embeddingPresetId = '',
    this.embeddingModelId = '',
    this.systemPrompt = '',
    this.generation = const GenerationConfig(),
    this.retrieval = const RetrievalConfig(),
    this.context = const ContextConfig(),
    this.retry = const RetryConfig(),
    this.phaseModels = const PhaseModelsConfig(),
    this.embedding = const EmbeddingConfig(),
    this.stream = const StreamConfig(),
    this.fork = const ForkConfig(),
    this.prompts = const PromptsConfig(),
    this.consolidation = const ConsolidationConfig(),
    this.memory = const MemoryConfig(),
    this.suggestReply = const SuggestReplyConfig(),
    this.reviewEnabled = false,
    this.contextBudget = const ContextBudget(),
  });

  factory IntermediateConfig.fromJson(Map<String, dynamic> json) =>
      IntermediateConfig(
        embeddingPresetId: json['embedding_preset_id'] as String? ?? '',
        embeddingModelId: json['embedding_model_id'] as String? ?? '',
        systemPrompt: json['system_prompt'] as String? ?? '',
        generation: GenerationConfig.fromJson(
          json['generation'] as Map<String, dynamic>? ?? {},
        ),
        retrieval: RetrievalConfig.fromJson(
          json['retrieval'] as Map<String, dynamic>? ?? {},
        ),
        context: ContextConfig.fromJson(
          json['context'] as Map<String, dynamic>? ?? {},
        ),
        retry: RetryConfig.fromJson(
          json['retry'] as Map<String, dynamic>? ?? {},
        ),
        phaseModels: PhaseModelsConfig.fromJson(
          json['phase_models'] as Map<String, dynamic>? ?? {},
        ),
        embedding: EmbeddingConfig.fromJson(
          json['embedding'] as Map<String, dynamic>? ?? {},
        ),
        stream: StreamConfig.fromJson(
          json['stream'] as Map<String, dynamic>? ?? {},
        ),
        fork: ForkConfig.fromJson(
          json['fork'] as Map<String, dynamic>? ?? {},
        ),
        prompts: PromptsConfig.fromJson(
          json['prompts'] as Map<String, dynamic>? ?? {},
        ),
        consolidation: ConsolidationConfig.fromJson(
          json['consolidation'] as Map<String, dynamic>? ?? {},
        ),
        memory: MemoryConfig.fromJson(
          json['memory'] as Map<String, dynamic>? ?? {},
        ),
        suggestReply: SuggestReplyConfig.fromJson(
          json['suggest_reply'] as Map<String, dynamic>? ?? {},
        ),
        reviewEnabled: json['reviewEnabled'] as bool? ?? false,
        contextBudget: ContextBudget.fromJson(
          json['contextBudget'] as Map<String, dynamic>? ?? {},
        ),
      );

  /// 语义检索用 embedding 全局默认供应商 ID（V1 启用语义检索）。
  ///
  /// 与聊天模型独立配置（embedding 模型切换影响向量维度，全局统一避免
  /// 同会话内向量不一致）。空串表示未配置 → FTS5 兜底。
  /// 持久化：SettingsRepository user_overrides（key: `intermediate.embedding_preset_id`）。
  final String embeddingPresetId;

  /// 语义检索用 embedding 全局默认模型 ID（V1 启用语义检索）。
  ///
  /// 空串表示未配置 → FTS5 兜底。
  /// 持久化：SettingsRepository user_overrides（key: `intermediate.embedding_model_id`）。
  final String embeddingModelId;

  /// 全局默认系统提示词（用户在「故事模式设置」中配置）。
  ///
  /// 优先级（DOC-09B §10.2）：会话级 systemPrompt > 全局 systemPrompt > kDefaultRolePrompt。
  /// 空串表示未配置，回落到 kDefaultRolePrompt（intermediate_prompts.dart）。
  /// 持久化：通过 SettingsRepository 的 user_overrides 机制（key: `intermediate.system_prompt`）。
  final String systemPrompt;

  /// 故事模式独立生成参数配置（2026-07-18 新增）。
  ///
  /// 故事模式不再复用 `broadcastChat` 的 temperature/topP/maxTokens/penalty，
  /// 改为本字段独立配置，会话级覆盖优先级高于本字段。
  ///
  /// 优先级（ConfigurationResolver.resolveIntermediateSettings）：
  /// - temperature/topP/maxTokens/presencePenalty/frequencyPenalty：
  ///   会话级 > intermediate.generation > broadcastChat（向后兼容兜底）
  ///
  /// 默认值综合 SillyTavern / ChatBox / Qwen / DeepSeek 参数调研得出：
  /// - temperature=0.8（比 Simple 0.7 略高，鼓励创造性）
  /// - top_p=0.95（略低于 Simple 1.0，配合 temperature 控制质量）
  /// - max_tokens=8192（0 表示不设置应用层输出上限）
  /// - presence_penalty=0（多数新模型已弃用 penalties，默认不惩罚；
  ///   老模型用户可自行调高）
  /// - frequency_penalty=0（同上）
  final GenerationConfig generation;

  final RetrievalConfig retrieval;
  final ContextConfig context;
  final RetryConfig retry;

  /// 分步骤模型配置（phase_models 组）
  ///
  /// 允许四步生成流程的每个步骤使用不同的模型/供应商。
  /// 未配置（空串）的步骤回退到 `modelId` / `presetId`（全局默认）。
  /// 仅拆分模型（modelId/presetId），不拆分 temperature/maxTokens 等参数。
  /// 仅全局配置，不暴露会话级分步骤覆盖。
  /// Schema 依据：DOC-09B §10.1。
  final PhaseModelsConfig phaseModels;

  final EmbeddingConfig embedding;
  final StreamConfig stream;

  /// Fork 机制配置（简化 Fork：覆盖式重写）
  final ForkConfig fork;

  /// 提示词文本配置（新增；V2 四步重构 2026-07-10）
  ///
  /// 10 段 V2 活跃提示词可通过 default_config.json 的 `intermediate.prompts` 子节点覆盖，
  /// 或通过 SettingsRepository 的 user_overrides 机制（key 前缀 `intermediate.prompts.*`）覆盖。
  /// 缺省值取自 `intermediate_prompts.dart`（共享常量）与
  /// `intermediate_prompts_v2.dart`（V2 四步常量）。
  /// V1 旧字段（draftSuffix/reviewSuffix/reviewSuffixJson 等）标注 @Deprecated，保留供 fromJson
  /// 兼容旧配置，正式发版时移除。
  final PromptsConfig prompts;

  /// 批量记忆提炼配置（新增）
  ///
  /// 控制低重要性记忆的合并触发条件与批量大小。详见 [ConsolidationConfig]。
  final ConsolidationConfig consolidation;

  /// 多粒度记忆配置（DOC-10 v1.1 新增）
  ///
  /// 控制宏摘要生成行为：触发条件、生成模式、微摘要向量化门槛。
  /// 详见 [MemoryConfig]。
  final MemoryConfig memory;

  /// 推荐回复功能配置（2026-07-29 新增）
  ///
  /// 推荐回复：点击按钮调用 LLM 生成 3 条候选用户回复，浮出气泡供选择。
  /// 独立配置模型（preset + modelId）和提示词，未配置时 fallback 到
  /// generating 阶段模型。详见 [SuggestReplyConfig]。
  final SuggestReplyConfig suggestReply;

  /// 审查阶段开关（v0.2.2 架构调整新增）
  ///
  /// false（默认）= 生成即最终，跳过 reviewing 阶段，3 次 LLM 调用
  /// true = 增加 reviewing 阶段做审查修正，4 次 LLM 调用
  /// 优先级：会话级 reviewEnabledOverride > 全局 reviewEnabled
  final bool reviewEnabled;

  /// 上下文预算分配（v0.2.2 架构调整新增）
  ///
  /// 控制原文区上限/下限 + 检索区的百分比分配。
  /// 详见 [ContextBudget]。
  final ContextBudget contextBudget;
}

/// 检索策略配置（retrieval 组）
///
/// 控制 hybrid search 的权重、关键事件加权、归一化等。
/// Schema 依据：DOC-09B §10.1。
///  新增：recencyWeight / importanceWeight / recencyHalfLife / vectorScoreThreshold。
///
/// 2026-07-16 优化：
/// - keyEventThreshold / keyEventBoost 默认值改为不生效（999 / 1.0），
///   因 importanceWeight 已能独立完成 importance 加成，避免双重加成扭曲排序。
/// - vectorScoreThreshold 从 0.3 提升到 0.55（对应 cosine > 0.1），
///   原 0.3 在 (cos+1)/2 归一化下等价于 cosine > -0.4，形同虚设。
///
/// 2026-07-19 修订（v0.2 Phase C 方案二）：
/// - topK 从 5 调整为 3。原方案一每条记忆只是单段概括，需要更多条数覆盖；
///   方案二改为 5W1E 多字段结构后，每条记忆信息密度更高、更具体，
///   3 条已足够覆盖相关上下文，同时减少 token 占用和注意力稀释。
///
/// 2026-07-30 修订（v0.2.2 架构调整）：
/// - topK 从 3 调整为 12。v0.2.2 将关键词分类从 entities/events 2 类扩展为
///   characters/items/locations/actions/plots 5 类，检索改为 5 路并行
///   （3 路 FTS5 实体通道 + 2 路 Vector 事件通道），每路需更多结果覆盖。
class RetrievalConfig {
  const RetrievalConfig({
    this.topK = 12,
    this.fts5Weight = 0.5,
    this.vectorWeight = 0.5,
    this.keyEventThreshold = 999,
    this.keyEventBoost = 1.0,
    this.normalizationEpsilon = 0.01,
    this.recencyWeight = 0.05,
    this.importanceWeight = 0.1,
    this.recencyHalfLife = 20,
    this.vectorScoreThreshold = 0.55,
    this.importanceStorageThreshold = 3,
    this.microVectorizeThreshold = 4,
    this.absoluteThreshold = 0.5,
    this.relativeThreshold = 0.65,
    this.vectorOnlyCosineFloor = 0.3,
    this.substringFallbackEnabled = true,
    this.substringFallbackLimit = 5,
  });

  factory RetrievalConfig.fromJson(Map<String, dynamic> json) =>
      RetrievalConfig(
        topK: json['top_k'] as int? ?? 12,
        fts5Weight: (json['fts5_weight'] as num?)?.toDouble() ?? 0.5,
        vectorWeight: (json['vector_weight'] as num?)?.toDouble() ?? 0.5,
        keyEventThreshold: json['key_event_threshold'] as int? ?? 999,
        keyEventBoost: (json['key_event_boost'] as num?)?.toDouble() ?? 1.0,
        normalizationEpsilon:
            (json['normalization_epsilon'] as num?)?.toDouble() ?? 0.01,
        recencyWeight: (json['recency_weight'] as num?)?.toDouble() ?? 0.05,
        importanceWeight:
            (json['importance_weight'] as num?)?.toDouble() ?? 0.1,
        recencyHalfLife: json['recency_half_life'] as int? ?? 20,
        vectorScoreThreshold:
            (json['vector_score_threshold'] as num?)?.toDouble() ?? 0.55,
        importanceStorageThreshold:
            json['importance_storage_threshold'] as int? ?? 3,
        microVectorizeThreshold: json['micro_vectorize_threshold'] as int? ?? 4,
        absoluteThreshold:
            (json['absolute_threshold'] as num?)?.toDouble() ?? 0.5,
        relativeThreshold:
            (json['relative_threshold'] as num?)?.toDouble() ?? 0.65,
        vectorOnlyCosineFloor:
            (json['vector_only_cosine_floor'] as num?)?.toDouble() ?? 0.3,
        substringFallbackEnabled:
            json['substring_fallback_enabled'] as bool? ?? true,
        substringFallbackLimit: json['substring_fallback_limit'] as int? ?? 5,
      );

  /// 检索返回的记忆条数
  final int topK;

  /// FTS5 权重
  final double fts5Weight;

  /// Vector 权重
  final double vectorWeight;

  /// 关键事件重要性阈值
  final int keyEventThreshold;

  /// 关键事件加权倍数
  final double keyEventBoost;

  /// 归一化平滑项
  final double normalizationEpsilon;

  /// 时间衰减权重（新增，2026-08-06 降低）
  ///
  /// recencyBoost = 0.5 ^ (turnsAgo / recencyHalfLife)，
  /// 加到 finalScore 中。默认 0.05（从0.15降低，因近期内容已在对话原文中），
  /// 设为 0 禁用时间衰减。
  final double recencyWeight;

  /// importance 乘法加权（新增，2026-08-06 修订为乘法）
  ///
  /// finalScore *= 1.0 + (importance - 3) * importanceWeight
  /// importance=3 时不影响分数，importance=5 时提升，importance=1 时降低。
  /// 默认 0.1（乘法语义下 0.1 = importance 5 给 20% 提升、importance 1 给 20% 降低）。
  /// 设为 0 禁用 importance 加权。
  final double importanceWeight;

  /// 时间衰减半衰期（轮次， 新增）
  ///
  /// turnsAgo = currentTurnNumber - memory.turnNumber，
  /// 每经过 recencyHalfLife 轮，recencyBoost 衰减一半。默认 20。
  final int recencyHalfLife;

  /// Vector 分数阈值（新增）
  ///
  /// 质量过滤：vectorScore < threshold 且 fts5Score == 0 的记忆被过滤。
  /// 默认 0.3，设为 0 禁用质量过滤。
  final double vectorScoreThreshold;

  /// 记忆持久化重要性门槛（新增）
  ///
  /// importance < threshold 的记忆仍写入 experiential_memories（保留原始记录），
  /// 但**不建立 FTS5 索引、不生成 embedding**（不可被检索）。
  /// 这些低重要性记忆留给  按需批量记忆提炼（memory_consolidator）
  /// 后续合并为高 importance 记忆再建索引。
  ///
  /// 默认 3，设为 0 表示所有记忆都建索引（禁用门槛）。
  final int importanceStorageThreshold;

  /// 微摘要向量化门槛
  ///
  /// importance >= 此值的微摘要才生成 embedding 向量；
  /// importance < 此值但 >= importanceStorageThreshold 的微摘要仅建 FTS5 索引。
  /// 默认 4。
  final int microVectorizeThreshold;

  /// 质量过滤绝对阈值（v0.2.2 新增）
  /// 分数低于此值的记忆直接丢弃
  final double absoluteThreshold;

  /// 质量过滤相对阈值（v0.2.2 新增）
  /// 分数低于本批最高分 × 此比例的记忆丢弃
  final double relativeThreshold;

  /// 纯语义候选独立低阈
  ///
  /// FTS 未命中（<0.02 偶然命中线）的 vector-only 候选不走
  /// [absoluteThreshold]——该阈在 finalScore=vec/2 刻度下等价于原始
  /// cosine ≥0.625，跨轮非对称嵌入的典型 0.3-0.6 全灭（语义召回窄带）。
  /// 改为原始 cosine ≥ 此值（默认 0.3）即保留。混合命中（FTS 有分）
  /// 仍走双阈值，不受影响。
  final double vectorOnlyCosineFloor;

  /// 主表子串兜底开关（新增）
  ///
  /// FTS/向量通道只覆盖已建索引/已向量化的记忆；开启后，当阈值过滤把
  /// 结果清空时，用主表 LIKE 子串召回补位——保证「记忆库里看得见的记忆
  /// 一定能被检索到」。默认 true；置 false 可回到纯评分通道旧行为。
  final bool substringFallbackEnabled;

  /// 子串兜底最多补位条数（默认 5）
  final int substringFallbackLimit;

  // 注：v0.2.2 的 key_entity_importance_threshold / key_entity_max_inject
  // 两键已于 2026-08-29 审查删除——关键实体注入自 v0.2.3 起由
  // FactualConfig.keyEntityImportanceThreshold（memory.factual 段）控制，
  // 这两个 retrieval 键全库无消费。
}

/// 上下文组装配置（context 组）
///
/// 控制 token 预算分配。
/// Schema 依据：DOC-09B §10.1。
/// 架构树异常观察1 收口：
/// dialogue_budget_ratio/output_reserve 自 v0.2.2 废弃（V2 方法改用
/// maxTokens 统一控制输出预留，不再按比例截断历史），字段/解析/发货
/// 键一并移除；存量 flat key 展开后 fromJson 忽略未知键静默失活。
class ContextConfig {
  const ContextConfig({
    this.effectiveContextLimit,
  });

  factory ContextConfig.fromJson(Map<String, dynamic> json) => ContextConfig(
        effectiveContextLimit: json['effective_context_limit'] as int?,
      );

  /// 单次请求 token 上限（v0.2，2026-07-29 新增）
  ///
  /// 限制每次 LLM 请求实际塞入的 token 数。null = 使用模型窗口。
  /// 实际取 min(配置值, 模型窗口)，避免配置超过模型能力。
  /// 用于应对 TPM 限制（如腾讯云 500万 TPM）：模型窗口虽大（如 GLM5.2 = 1M），
  /// 但单次请求塞太多会触发 TPM 429。
  /// 仅故事模式 generating/reviewing 阶段生效。
  final int? effectiveContextLimit;
}

/// 上下文预算配置（v0.2.2 架构调整新增）
///
/// 控制故事模式上下文窗口的预算分配：
/// - [compactionTriggerRatio]：压缩触发线（固定 0.5，总占用达此比例触发压缩）
/// - [recentMinRatio]：原文区下限（null=动态计算，非 null=用户自定义）
/// - [retrievalRatio]：检索区比例（固定 0.15）
/// - [recentMinTokenTarget]：下限动态计算的目标 token 数（默认 32000）
///
/// 下限动态计算逻辑：recentMinRatio 为 null 时，基于 recentMinTokenTarget
/// 反推百分比，下限保护 10%-45%。
///
/// 关联设计：doc/design/13_故事模式上下文机制设计.md §5、
///§5.5
class ContextBudget {
  const ContextBudget({
    this.compactionTriggerRatio = 0.5,
    this.recentMinRatio,
    this.retrievalRatio = 0.15,
    this.recentMinTokenTarget = 32000,
  });

  factory ContextBudget.fromJson(Map<String, dynamic> json) => ContextBudget(
        compactionTriggerRatio: _clampTriggerRatio(
          (json['compactionTriggerRatio'] as num?)?.toDouble(),
        ),
        recentMinRatio: (json['recentMinRatio'] as num?)?.toDouble(),
        retrievalRatio: (json['retrievalRatio'] as num?)?.toDouble() ?? 0.15,
        recentMinTokenTarget:
            (json['recentMinTokenTarget'] as num?)?.toInt() ?? 32000,
      );

  /// CC-3：触发线病态值防御——手改
  /// user_overrides / 导入手改备份可能写入 ≤0 或 ≥1 的值：≤0 会让
  /// 轮前压缩静默禁用（triggerTokens<=0 直接 return false），≥1 永远
  /// 触不到线（导演退化为每轮软着陆收尾）。病态值回默认 0.5；
  /// 导演侧 UI 域 [0.30,0.80] 的钳制在导演合并点另做（故事侧 0.2-0.9
  /// 合法域不受此防御影响）。
  static double _clampTriggerRatio(double? raw) {
    if (raw == null || raw <= 0 || raw >= 1) return 0.5;
    return raw;
  }

  /// 压缩触发线（固定 0.5，总占用达 contextWindow × 此比例时触发压缩）
  ///
  /// 语义为"何时压缩"而非"原文区上限"——固定开销动态变化时，
  /// 基于总占用的触发线永远可达，不会出现死循环。详见设计文档 §5.1。
  final double compactionTriggerRatio;

  /// 原文区下限百分比。null=动态计算，非 null=用户自定义
  final double? recentMinRatio;

  /// 检索区比例
  final double retrievalRatio;

  /// 下限动态计算的目标 token 数
  final int recentMinTokenTarget;

  /// 动态计算下限百分比
  ///
  /// [recentMinRatio] 非 null 时直接返回用户自定义值；
  /// 为 null 时基于 [recentMinTokenTarget] / [availableWindow] 反推，
  /// 下限保护 0.10-0.45（避免挤占其他区）。
  double computeRecentMinRatio({required int availableWindow}) {
    if (recentMinRatio != null) return recentMinRatio!;
    final raw = recentMinTokenTarget / availableWindow;
    return raw.clamp(0.10, 0.45);
  }
}

/// 重试策略配置（retry 组）
///
/// 控制各阶段失败后的额外重试次数（不含首次尝试）。
/// 语义：`*_max_retries: 2` = 首次尝试 + 2 次重试 = 共 3 次。
/// Schema 依据：DOC-09B §10.1、DOC-09A-2 §6.2 重试语义。
class RetryConfig {
  /// 默认 5（2026-10-15 批 E / P5 ：三模式统一默认自动重试 5 次——
  /// 进度透明化后高默认=知情自决；阶段键保留为**阶段粒度覆盖项**，
  /// 退避/判定/预算读共享 RetryPolicy（lib/core/network/retry_policy.dart）
  const RetryConfig({
    this.generatingMaxRetries = 5,
    this.extractingMaxRetries = 5,
    this.retrievalMaxRetries = 5,
    this.reviewingMaxRetries = 5,
    this.summarizingMaxRetries = 5,
    this.streamInterruptRetry = 5,
  });

  factory RetryConfig.fromJson(Map<String, dynamic> json) => RetryConfig(
        generatingMaxRetries: json['generating_max_retries'] as int? ?? 5,
        extractingMaxRetries: json['extracting_max_retries'] as int? ?? 5,
        retrievalMaxRetries: json['retrieval_max_retries'] as int? ?? 5,
        reviewingMaxRetries: json['reviewing_max_retries'] as int? ?? 5,
        summarizingMaxRetries: json['summarizing_max_retries'] as int? ?? 5,
        streamInterruptRetry: json['stream_interrupt_retry'] as int? ?? 5,
      );

  /// 生成失败后额外重试次数
  final int generatingMaxRetries;

  /// 关键词提取失败后额外重试次数（四步重构 extracting 步骤）
  ///
  /// extracting 步骤输出结构化 JSON（工具调用/JSON 模式），
  /// 解析失败时按此值重试。语义同其他 *_max_retries：2 = 共 3 次。
  final int extractingMaxRetries;

  /// 检索完全失败后额外重试次数
  final int retrievalMaxRetries;

  /// 修正生成失败后额外重试次数
  final int reviewingMaxRetries;

  /// 事件摘要提取失败后额外重试次数（四步重构 summarizing 步骤）
  ///
  /// summarizing 步骤输出结构化 JSON（工具调用/JSON 模式），
  /// 解析失败时按此值重试。compact 降级场景仍走 summarizing，同样适用。
  final int summarizingMaxRetries;

  /// 流式中断额外重试次数
  ///
  /// （json_format_retry 死键已删：2026-10-15 批 E / P9 ，全库无消费者；
  /// 格式错误由 extracting/summarizing 的语义化判定与共享策略覆盖）
  final int streamInterruptRetry;
}

/// Embedding 向量化配置（embedding 组）
///
/// 控制 embedding API 的超时与降级行为。
/// Schema 依据：DOC-09B §10.1。
///
/// 2026-07-21 重大变更：fallbackOnFailure 默认值从 true 改为 false。
/// 原因：用户反馈"静默降级到字符串匹配是反模式"——用户必须明确知道
/// embedding 调用失败，而不是被偷偷降级。新行为：
/// - false（默认）：调用失败 → 抛异常 → 触发失败对话框，用户可选择
///   "重试 / 临时降级继续本轮 / 中止本轮"
/// - true：保留旧行为（仅 warn 日志，静默降级），供高级用户主动配置
class EmbeddingConfig {
  const EmbeddingConfig({
    this.timeoutMs = 5000,
    this.fallbackOnFailure = false,
  });

  factory EmbeddingConfig.fromJson(Map<String, dynamic> json) =>
      EmbeddingConfig(
        timeoutMs: json['timeout_ms'] as int? ?? 5000,
        fallbackOnFailure: json['fallback_on_failure'] as bool? ?? false,
      );

  /// embedding API 超时时间（毫秒）
  final int timeoutMs;

  /// 失败时是否降级（false = 失败则整轮失败，触发 UI 对话框让用户决策）
  final bool fallbackOnFailure;

  /// 超时 Duration 便捷访问
  Duration get timeout => Duration(milliseconds: timeoutMs);
}

/// 流式显示配置（stream 组）
///
/// 控制流式响应的解析标记和小窗折叠延迟。
/// Schema 依据：DOC-09B §10.1、§7.3 时序图。
class StreamConfig {
  const StreamConfig({
    this.toolCallingEnabled = true,
    @Deprecated(
      'Phase 6 四步重构后不再使用分隔标记模式，generating 改为纯文本输出。保留字段供 fromJson 兼容旧配置，将在正式发版时移除。',
    )
    this.generatingSeparator = '<<<KEYWORDS>>>',
    @Deprecated(
      'Phase 6 四步重构后不再使用分隔标记模式，reviewing 改为纯文本输出。保留字段供 fromJson 兼容旧配置，将在正式发版时移除。',
    )
    this.eventSummarySeparator = '<<<EVENT_SUMMARY>>>',
    @Deprecated(
      'Phase 6 四步重构后不再影响四步流程行为，会话级覆盖已迁移到 toolCallingEnabled。仅保留供 fromJson 兼容旧配置，将在正式发版时移除。',
    )
    this.jsonFallback = true,
    @Deprecated(
      'Phase 6 四步重构后不再影响四步流程行为，会话级覆盖已迁移到 toolCallingEnabled。仅保留供 fromJson 兼容旧配置，将在正式发版时移除。',
    )
    this.injectResponseFormat = true,
    this.skipReviewWhenEmptyRetrieval = true,
    this.generatingFoldDelayMs = generatingFoldDelayMsDefault,
    this.retrievalFoldDelayMs = retrievalFoldDelayMsDefault,
  });

  factory StreamConfig.fromJson(Map<String, dynamic> json) => StreamConfig(
        toolCallingEnabled: json['tool_calling_enabled'] as bool? ?? true,
        generatingSeparator:
            json['generating_separator'] as String? ?? '<<<KEYWORDS>>>',
        eventSummarySeparator:
            json['event_summary_separator'] as String? ?? '<<<EVENT_SUMMARY>>>',
        jsonFallback: json['json_fallback'] as bool? ?? true,
        injectResponseFormat: json['inject_response_format'] as bool? ?? true,
        skipReviewWhenEmptyRetrieval:
            json['skip_review_when_empty_retrieval'] as bool? ?? true,
        generatingFoldDelayMs: json['generating_fold_delay_ms'] as int? ?? 2000,
        retrievalFoldDelayMs: json['retrieval_fold_delay_ms'] as int? ?? 1000,
      );

  /// 是否启用工具调用作为结构化输出的首选方式（四步重构）
  ///
  /// 四步拆分后，extracting/summarizing 两步需要结构化输出。降级链：
  /// 工具调用（tool_choice=required）→ JSON 模式 → 提示词约束。
  ///
  /// - true（默认）：优先尝试工具调用。供应商不支持时（首次请求 400）自动
  ///   降级到 JSON 模式并弹窗提示用户。
  /// - false：跳过工具调用，直接走 JSON 模式（兼容已知不支持的供应商）。
  ///
  /// 为 v0.3 高级模式 Agent Loop 预置工具调用基础设施。
  final bool toolCallingEnabled;

  /// 生成内容/关键词分隔标记
  @Deprecated(
    'Phase 6 四步重构后不再使用分隔标记模式，generating 改为纯文本输出。保留字段供 fromJson 兼容旧配置，将在正式发版时移除。',
  )
  final String generatingSeparator;

  /// 回复/事件摘要分隔标记
  @Deprecated(
    'Phase 6 四步重构后不再使用分隔标记模式，reviewing 改为纯文本输出。保留字段供 fromJson 兼容旧配置，将在正式发版时移除。',
  )
  final String eventSummarySeparator;

  /// 是否使用 JSON 模式（默认 true）
  ///
  /// **Phase 6 四步重构后**：此字段不再影响 generating/reviewing（改用 runPlainText
  /// 纯文本输出）和 extracting/summarizing（改用 [toolCallingEnabled] 控制工具调用）。
  /// 会话级覆盖机制已迁移到 [toolCallingEnabled]（`_applyToolCallingOverride`），
  /// 此字段无任何调用点，仅保留供 fromJson 兼容旧配置。
  @Deprecated(
    'Phase 6 四步重构后不再影响四步流程行为，会话级覆盖已迁移到 toolCallingEnabled。仅保留供 fromJson 兼容旧配置，将在正式发版时移除。',
  )
  final bool jsonFallback;

  /// 是否注入 OpenAI `response_format` 强制 LLM 输出结构化 JSON
  ///
  /// **Phase 6 四步重构后**：此字段不再影响四步流程行为（同 [jsonFallback]）。
  /// 会话级覆盖机制已迁移到 [toolCallingEnabled]，此字段无任何调用点。
  @Deprecated(
    'Phase 6 四步重构后不再影响四步流程行为，会话级覆盖已迁移到 toolCallingEnabled。仅保留供 fromJson 兼容旧配置，将在正式发版时移除。',
  )
  final bool injectResponseFormat;

  /// 当生成关键词为空或记忆检索结果为空时，跳过"重写回复"步骤，
  /// 直接用生成内容作为最终回复，第二次 LLM 请求仅生成 EventSummary。
  ///
  /// 降级策略（DOC-09A-2 §6.6）：避免在无检索素材时浪费 token 重写回复，
  /// 同时保留 EventSummary 生成以维持记忆持久化链路完整。
  /// 默认 true：用户期望"生成即最终"的轻量降级。
  ///
  /// 2026-07-16 优化项10：compact 降级已移除，此字段保留但不再生效（向后兼容）。
  /// 原因：reviewing 有双重功能（按记忆修正 + 润色文案），即使无记忆也有润色价值。
  /// 注入前质量过滤（双阈值取严格）在 ContextBuilder._formatMemories 中完成。
  final bool skipReviewWhenEmptyRetrieval;

  /// 生成面板自动折叠延迟（毫秒）
  final int generatingFoldDelayMs;

  /// 检索小窗自动折叠延迟（毫秒）
  final int retrievalFoldDelayMs;

  /// 默认值常量（供未加载配置时的 UI 兜底使用）
  static const int generatingFoldDelayMsDefault = 2000;
  static const int retrievalFoldDelayMsDefault = 1000;
}

/// Fork 机制配置（fork 组）
///
/// 控制简化 Fork（覆盖式重写）的行为参数。
/// Schema 依据：DOC-09A-1 §2.7、DOC-09B §10.1。
class ForkConfig {
  const ForkConfig({this.regenerateWindowRounds = 5});

  factory ForkConfig.fromJson(Map<String, dynamic> json) => ForkConfig(
        regenerateWindowRounds: json['regenerate_window_rounds'] as int? ?? 5,
      );

  /// 可重新生成/编辑重发/删除整轮的「最近 N 轮」窗口大小。
  ///
  /// 仅最近 N 轮内的消息可执行覆盖式重写操作；更早的消息菜单项禁用。
  /// 默认 5 轮。用户可通过配置调整（增大以支持更深回退）。
  final int regenerateWindowRounds;
}

/// 提示词文本配置（prompts 组， 新增）
///
/// 中级模式四步生成的提示词文本，全部可通过 default_config.json 的
/// `intermediate.prompts` 子节点覆盖，或通过 SettingsRepository 的 user_overrides
/// 机制（key 前缀 `intermediate.prompts.*`）覆盖。
///
/// **白盒化目的**：用户可在「故事模式设置 → 提示词」页面查看与编辑每段提示词，
/// 适配不同 LLM 的格式稳定性差异（弱模型可能需要更严格的格式约束）。
///
/// **缺省值**：V2 活跃字段取自 `intermediate_prompts.dart`（共享常量）与
/// `intermediate_prompts_v2.dart`（V2 四步常量）；V1 废弃字段保留供 fromJson
/// 兼容旧配置。当 JSON 节点缺失或字段为空时，回落到常量默认值。
///
/// Schema 依据：DOC-09B §10.1（扩展）。
class PromptsConfig {
  const PromptsConfig({
    this.defaultRolePrompt = kDefaultRolePrompt,
    this.generatingSuffixV2 = kGeneratingSuffixPromptV2,
    this.reviewSuffixV2 = kReviewSuffixPromptV2,
    this.extractKeywordsPrompt = kExtractKeywordsToolPrompt,
    this.extractSummaryPrompt = kExtractSummaryToolPrompt,
    this.extractFactsPrompt = kExtractFactsToolPrompt,
    @Deprecated(
      'Phase 6 四步重构后改用 generatingSuffixV2，将在正式发版时移除。',
    )
    this.draftSuffix = kDraftSuffixPrompt,
    @Deprecated(
      'Phase 6 四步重构后改用 generatingSuffixV2，将在正式发版时移除。',
    )
    this.draftSuffixJson = kDraftSuffixPromptJson,
    @Deprecated(
      'Phase 6 四步重构后改用 reviewSuffixV2，将在正式发版时移除。',
    )
    this.reviewSuffix = kReviseSuffixPrompt,
    @Deprecated(
      'Phase 6 四步重构后改用 reviewSuffixV2，将在正式发版时移除。',
    )
    this.reviewSuffixJson = kReviseSuffixPromptJson,
    @Deprecated(
      'Phase 6 四步重构后 compact 降级复用 extractSummaryPrompt，将在正式发版时移除。',
    )
    this.compactReviewSuffix = kCompactReviseSuffixPrompt,
    @Deprecated(
      'Phase 6 四步重构后 compact 降级复用 extractSummaryPrompt，将在正式发版时移除。',
    )
    this.compactReviewSuffixJson = kCompactReviseSuffixPromptJson,
    this.generatedInjectionPrefix = kGeneratedInjectionPrefix,
    this.memoriesInjectionTitle = kMemoriesInjectionTitle,
    this.factInjectionTitle = kFactInjectionTitle,
    this.directiveInjectionTitle = kDirectiveInjectionTitle,
    this.consolidationPrompt = kConsolidationPrompt,
  });

  factory PromptsConfig.fromJson(Map<String, dynamic> json) => PromptsConfig(
        defaultRolePrompt:
            json['default_role_prompt'] as String? ?? kDefaultRolePrompt,
        generatingSuffixV2: json['generating_suffix_v2'] as String? ??
            kGeneratingSuffixPromptV2,
        reviewSuffixV2:
            json['review_suffix_v2'] as String? ?? kReviewSuffixPromptV2,
        extractKeywordsPrompt: json['extract_keywords_prompt'] as String? ??
            kExtractKeywordsToolPrompt,
        extractSummaryPrompt: json['extract_summary_prompt'] as String? ??
            kExtractSummaryToolPrompt,
        extractFactsPrompt:
            json['extract_facts_prompt'] as String? ?? kExtractFactsToolPrompt,
        draftSuffix: json['draft_suffix'] as String? ?? kDraftSuffixPrompt,
        draftSuffixJson:
            json['draft_suffix_json'] as String? ?? kDraftSuffixPromptJson,
        reviewSuffix: json['review_suffix'] as String? ?? kReviseSuffixPrompt,
        reviewSuffixJson:
            json['revise_suffix_json'] as String? ?? kReviseSuffixPromptJson,
        compactReviewSuffix: json['compact_revise_suffix'] as String? ??
            kCompactReviseSuffixPrompt,
        compactReviewSuffixJson:
            json['compact_revise_suffix_json'] as String? ??
                kCompactReviseSuffixPromptJson,
        generatedInjectionPrefix:
            json['generated_injection_prefix'] as String? ??
                kGeneratedInjectionPrefix,
        memoriesInjectionTitle: json['memories_injection_title'] as String? ??
            kMemoriesInjectionTitle,
        factInjectionTitle:
            json['fact_injection_title'] as String? ?? kFactInjectionTitle,
        directiveInjectionTitle: json['directive_injection_title'] as String? ??
            kDirectiveInjectionTitle,
        consolidationPrompt:
            json['consolidation_prompt'] as String? ?? kConsolidationPrompt,
      );

  /// 默认角色指引（会话/全局 systemPrompt 为空时使用）
  final String defaultRolePrompt;

  /// 生成步骤后缀（V2 四步版，generating 用，纯文本输出）
  ///
  /// 取自 [kGeneratingSuffixPromptV2]。四步拆分后 generating 步骤专用。
  final String generatingSuffixV2;

  /// 审查步骤后缀（V2 四步版，reviewing 用，纯文本输出）
  ///
  /// 取自 [kReviewSuffixPromptV2]。四步拆分后 reviewing 步骤专用。
  final String reviewSuffixV2;

  /// 关键词提取系统提示（V2 四步版，extracting 用，兼容工具调用与 JSON 降级）
  ///
  /// 取自 [kExtractKeywordsToolPrompt]。结构化步骤专用。
  final String extractKeywordsPrompt;

  /// 事件摘要系统提示（V2 四步版，summarizing 用，compact 降级复用）
  ///
  /// 取自 [kExtractSummaryToolPrompt]。compact 降级（检索为空→跳过 reviewing）
  /// 时也复用本提示词生成事件摘要以持久化记忆。
  final String extractSummaryPrompt;

  /// 事实变更提取系统提示（V2 四步版，summarizing 并行调用，DOC-11 §5.1）
  ///
  /// 取自 [kExtractFactsToolPrompt]。与 [extractSummaryPrompt] 同时作为
  /// summarizing 阶段的系统提示，LLM 可并行调用 extract_event_summary 与
  /// extract_facts 两个工具。本轮无事实变更时不调用 extract_facts。
  ///
  /// 2026-07-20 新增（DOC-11 事实层中间方案）。
  final String extractFactsPrompt;

  /// 生成后缀（分隔标记版，Phase 6 标记 @Deprecated）
  ///
  /// 四步重构后改用 [generatingSuffixV2]。保留字段供 fromJson 兼容旧配置，
  /// 将在正式发版时移除。
  @Deprecated('Phase 6 四步重构后改用 generatingSuffixV2，将在正式发版时移除。')
  final String draftSuffix;

  /// 生成后缀（JSON 兜底版，Phase 6 标记 @Deprecated）
  @Deprecated('Phase 6 四步重构后改用 generatingSuffixV2，将在正式发版时移除。')
  final String draftSuffixJson;

  /// 审查后缀（分隔标记版，Phase 6 标记 @Deprecated）
  @Deprecated('Phase 6 四步重构后改用 reviewSuffixV2，将在正式发版时移除。')
  final String reviewSuffix;

  /// 审查后缀（JSON 兜底版，Phase 6 标记 @Deprecated）
  @Deprecated('Phase 6 四步重构后改用 reviewSuffixV2，将在正式发版时移除。')
  final String reviewSuffixJson;

  /// Compact 审查后缀（分隔标记版，Phase 6 标记 @Deprecated）
  ///
  /// 四步重构后 compact 降级复用 [extractSummaryPrompt]。
  @Deprecated(
    'Phase 6 四步重构后 compact 降级复用 extractSummaryPrompt，将在正式发版时移除。',
  )
  final String compactReviewSuffix;

  /// Compact 审查后缀（JSON 兜底版，Phase 6 标记 @Deprecated）
  @Deprecated(
    'Phase 6 四步重构后 compact 降级复用 extractSummaryPrompt，将在正式发版时移除。',
  )
  final String compactReviewSuffixJson;

  /// 生成内容注入消息前缀（system 角色注入，DOC-09A-2 §4.6）
  final String generatedInjectionPrefix;

  /// 经历摘要类记忆注入消息标题（system 角色注入，DOC-09A-1 §3.2）
  ///
  /// 默认 '【经历摘要类记忆检索结果】'。
  final String memoriesInjectionTitle;

  /// 事实类记忆注入消息标题（system 角色注入，DOC-11 §6.4）
  ///
  /// 默认 '【事实类记忆检索结果】'，与 [memoriesInjectionTitle] 同风格。
  /// 在 generating/reviewing 阶段标注事实层注入区块，注入在经历摘要类记忆之前：
  /// ```dart
  /// [factInjectionTitle]
  /// {factBlock}
  ///
  /// [memoriesInjectionTitle]
  /// {memoryBlock}
  /// ```
  ///
  /// **引用传递原则**：提示词文本中涉及此标题时不得硬编码，必须通过占位符
  /// 或变量引用传递，使配置项变更时 prompt 自动跟随。详见设计文档 §7.4。
  ///
  /// 2026-07-20 新增（DOC-11 事实层中间方案）。
  final String factInjectionTitle;

  /// 【常驻指令】区块标题（v0.2.3 实体强制注入开关）
  ///
  /// 默认 '【常驻指令】'，标注「强制注入 → 常驻指令」实体区块，与
  /// [factInjectionTitle] 同风格、允许用户自定义。
  final String directiveInjectionTitle;

  /// 批量记忆提炼提示词（新增）
  ///
  /// 由 `MemoryConsolidator` 使用，合并低重要性事件摘要为高重要性剧情节点记忆。
  /// 缺省值取自 [kConsolidationPrompt]。
  final String consolidationPrompt;
}

/// 批量记忆提炼配置（consolidation 组，  新增）
///
/// 控制低重要性记忆的合并触发条件与批量大小。
/// 当上下文 token 占用率达到 [triggerThreshold] 时，查询未建索引的低重要性记忆
/// （importance < [RetrievalConfig.importanceStorageThreshold]），交由 LLM 合并为
/// 高重要性记忆后建索引，避免模型在相近轮次重复提取相似事件。
///
/// Schema 依据：DOC-09B §10.1（扩展）。
///
/// **2026-07-19 v0.2 Phase C 方案二禁用**：方案二将记忆结构从单字段 `summary`
/// 扩展为 6 字段（when/where/who/what/significance/extra），原 consolidation
/// 提示词（`kConsolidationPrompt`）与合并逻辑只针对单字段设计，需重新设计后
/// 才能启用。当前通过 `default_config.json` 中 `trigger_threshold=2.0` 等效
/// 禁用（`usageRatio` 永远 ≤ 1.0 < 2.0，触发条件永不满足）。代码保留待未来
/// 恢复：恢复时把 `trigger_threshold` 改回 0.8，并重新设计 consolidation
/// 提示词与 `persistConsolidatedMemories` 以适配新的 6 字段结构。
class ConsolidationConfig {
  const ConsolidationConfig({
    this.triggerThreshold = 0.8,
    this.minArtifactsToConsolidate = 3,
    this.maxArtifactsToConsolidate = 10,
  });

  factory ConsolidationConfig.fromJson(Map<String, dynamic> json) =>
      ConsolidationConfig(
        triggerThreshold:
            (json['trigger_threshold'] as num?)?.toDouble() ?? 0.8,
        minArtifactsToConsolidate:
            json['min_artifacts_to_consolidate'] as int? ?? 3,
        maxArtifactsToConsolidate:
            json['max_artifacts_to_consolidate'] as int? ?? 10,
      );

  /// 上下文 token 占用率触发阈值（占 contextWindow - outputReserve 的比例）
  ///
  /// 当 `totalTokens / (contextWindow - outputReserve) > triggerThreshold` 时
  /// 触发批量提炼。默认 0.8（80% 占用率）。设为 1.0+ 禁用提炼。
  ///
  /// **2026-07-19 当前值 2.0**（`default_config.json`）：等效禁用，原因见类注释。
  final double triggerThreshold;

  /// 触发提炼所需的最少未索引记忆条数
  ///
  /// 未索引记忆少于该值时不触发（不值得一次 LLM 调用）。默认 3。
  final int minArtifactsToConsolidate;

  /// 单次提炼最多处理的未索引记忆条数
  ///
  /// 避免单次合并输入过大导致 LLM 上下文超限。默认 10。
  /// 超出部分留待下次触发处理。
  final int maxArtifactsToConsolidate;
}

/// 记忆配置（memory 组）
///
/// 控制事实层实体/属性的提取、防护与注入行为。
///
/// 2026-07-20 扩展（DOC-11 事实层中间方案）：新增 [factual] 子节点，
/// 控制事实层实体/属性的提取、防护与注入行为。
///
/// v0.2.3 修订：移除 macroSummary 子节点（独立宏摘要已废弃，
/// 改由压缩摘要在压缩时生成分段宏摘要，详见 DOC-08 §4.5）。
///
/// Schema 依据：DOC-10 §7.1、DOC-11 §9。
class MemoryConfig {
  const MemoryConfig({
    this.factual = const FactualConfig(),
  });

  factory MemoryConfig.fromJson(Map<String, dynamic> json) => MemoryConfig(
        factual: FactualConfig.fromJson(
          json['factual'] as Map<String, dynamic>? ?? {},
        ),
      );

  /// 事实层配置（DOC-11 §9，2026-07-20 新增）
  final FactualConfig factual;
}

/// 分步骤模型配置（phase_models 组）
///
/// 允许四步生成流程（generating/extracting/reviewing/summarizing）的每个步骤
/// 使用不同的模型/供应商。未配置（空串）的步骤回退到
/// `IntermediateConfig.modelId` / `IntermediateConfig.presetId`（全局默认）。
///
/// **设计目的**：简单任务（如关键词提取、事件摘要）可配置小模型降低成本，
/// 复杂任务（如生成、审查）保留大模型保证质量。
///
/// **仅拆分模型**：只拆分 modelId/presetId，不拆分 temperature/maxTokens 等参数
/// （这些参数仍由 broadcastChat 全局配置统一控制）。
///
/// **仅全局配置**：不暴露会话级分步骤覆盖（会话级仅覆盖单一 modelId/presetId）。
///
/// Schema 依据：DOC-09B §10.1。
class PhaseModelsConfig {
  const PhaseModelsConfig({
    this.generatingPresetId = '',
    this.generatingModelId = '',
    this.extractingPresetId = '',
    this.extractingModelId = '',
    this.reviewingPresetId = '',
    this.reviewingModelId = '',
    this.summarizingPresetId = '',
    this.summarizingModelId = '',
  });

  factory PhaseModelsConfig.fromJson(Map<String, dynamic> json) =>
      PhaseModelsConfig(
        generatingPresetId: json['generating_preset_id'] as String? ?? '',
        generatingModelId: json['generating_model_id'] as String? ?? '',
        extractingPresetId: json['extracting_preset_id'] as String? ?? '',
        extractingModelId: json['extracting_model_id'] as String? ?? '',
        reviewingPresetId: json['reviewing_preset_id'] as String? ?? '',
        reviewingModelId: json['reviewing_model_id'] as String? ?? '',
        summarizingPresetId: json['summarizing_preset_id'] as String? ?? '',
        summarizingModelId: json['summarizing_model_id'] as String? ?? '',
      );

  /// 生成阶段的供应商 ID（空串 = 回退到全局默认 presetId）
  final String generatingPresetId;

  /// 生成阶段的模型 ID（空串 = 回退到全局默认 modelId）
  final String generatingModelId;

  /// 关键词提取阶段的供应商 ID（空串 = 回退到全局默认 presetId）
  final String extractingPresetId;

  /// 关键词提取阶段的模型 ID（空串 = 回退到全局默认 modelId）
  final String extractingModelId;

  /// 审查阶段的供应商 ID（空串 = 回退到全局默认 presetId）
  final String reviewingPresetId;

  /// 审查阶段的模型 ID（空串 = 回退到全局默认 modelId）
  final String reviewingModelId;

  /// 事件摘要阶段的供应商 ID（空串 = 回退到全局默认 presetId）
  final String summarizingPresetId;

  /// 事件摘要阶段的模型 ID（空串 = 回退到全局默认 modelId）
  final String summarizingModelId;

  /// 所有步骤均未配置（全部回退到全局默认）
  bool get isAllEmpty =>
      generatingPresetId.isEmpty &&
      generatingModelId.isEmpty &&
      extractingPresetId.isEmpty &&
      extractingModelId.isEmpty &&
      reviewingPresetId.isEmpty &&
      reviewingModelId.isEmpty &&
      summarizingPresetId.isEmpty &&
      summarizingModelId.isEmpty;
}

/// 故事模式生成参数配置（generation 组，2026-07-18 新增）
///
/// 故事模式独立的 LLM 生成参数配置段，不再复用 `broadcastChat` 的对应字段。
/// 设计目的：故事模式对创造性、话题多样性、用词丰富度有更高要求，
/// 与 Simple 模式的"工具型对话"参数需求不同。
///
/// **默认值调研依据**（综合类似产品）：
/// | 参数 | 默认值 | SillyTavern | ChatBox | Qwen | DeepSeek | 设计理由 |
/// |------|--------|-------------|---------|------|----------|----------|
/// | temperature | 0.8 | 0.5-0.9 | 0.7 | 0.8 | 0.7 | 故事模式偏创造性，比 Simple 0.7 略高 |
/// | top_p | 0.95 | 0.9-0.95 | 1.0 | 0.8 | 1.0 | 配合 temperature 控制质量，略低于 Simple 1.0 |
/// | max_tokens | 8192 | - | 4096 | 8192 | 4096 | 为故事续写留出更充足空间；0 表示由模型/供应商决定 |
/// | presence_penalty | 0 | 0 | 0 | 0 | 0 | 默认不惩罚（多数新模型已弃用） |
/// | frequency_penalty | 0 | 0 | 0 | 0 | 0 | 默认不惩罚（多数新模型已弃用） |
///
/// **会话级覆盖**：ChatSession 的对应 nullable 字段（temperature/topP/maxTokens/
/// presencePenalty/frequencyPenalty）非 null 时覆盖本字段值。
///
/// **reasoningEffort**（v0.2.2 新增）：思考预算档位，存储枚举 name 字符串
///（'disabled'/'low'/'medium'/'high'），null = 未配置（跟随模型默认）。
/// 仅作用于 generating（生成阶段）与 reviewing（审查阶段）阶段；extracting/
/// summarizing 等结构化阶段不消费此参数。
/// 用 String? 而非 ReasoningEffort 枚举，避免 core 层依赖 domain 层。
///
/// Schema 依据：DOC-09B §10.1（2026-07-18 扩展，2026-07-31 增 reasoning_effort）。
class GenerationConfig {
  const GenerationConfig({
    this.temperature = 0.8,
    this.topP = 0.95,
    this.maxTokens = OutputTokenPolicy.storyDefaultLimit,
    this.presencePenalty = 0,
    this.frequencyPenalty = 0,
    this.reasoningEffort,
  });

  factory GenerationConfig.fromJson(Map<String, dynamic> json) =>
      GenerationConfig(
        temperature: (json['temperature'] as num?)?.toDouble() ?? 0.8,
        topP: (json['top_p'] as num?)?.toDouble() ?? 0.95,
        maxTokens:
            json['max_tokens'] as int? ?? OutputTokenPolicy.storyDefaultLimit,
        presencePenalty: (json['presence_penalty'] as num?)?.toDouble() ?? 0,
        frequencyPenalty: (json['frequency_penalty'] as num?)?.toDouble() ?? 0,
        reasoningEffort: json['reasoning_effort'] as String?,
      );

  /// 温度参数（0.0-2.0，故事模式默认 0.8）
  ///
  /// 控制生成随机性，值越高越发散。故事模式略高于 Simple 模式（0.7）
  /// 以鼓励剧情创造性，但不过高以免逻辑混乱。
  final double temperature;

  /// top_p 采样（0.0-1.0，故事模式默认 0.95）
  ///
  /// 核采样：仅从累积概率达到 top_p 的 token 集合中采样。
  /// 与 temperature 配合使用，0.95 在保持质量的同时允许适度发散。
  final double topP;

  /// 单次生成最大 token 数（默认 8192；0 = 不设置应用层上限）
  ///
  /// 故事模式单轮回复通常 1000-3000 token，8192 为推理 token 和长回复留出余量。
  /// 用户可按需调大（如需要长篇描写）或调小（控制成本）。
  final int maxTokens;

  /// 存在惩罚（-2.0 ~ 2.0，故事模式默认 0.6）
  ///
  /// 鼓励 LLM 谈论新话题：token 一旦出现在已生成文本中，
  /// 后续采样统一施加惩罚（不管出现几次）。正值越大越鼓励新话题。
  /// 故事模式用 0.6 避免剧情单调重复出现相同场景/角色行为。
  ///
  /// 注意：与 frequency_penalty 同时使用时效果叠加，建议从小值开始调整。
  final double presencePenalty;

  /// 频率惩罚（-2.0 ~ 2.0，故事模式默认 0.3）
  ///
  /// 减少 LLM 重复用词：token 每多出现一次，惩罚递增。
  /// 故事模式用 0.3 避免重复描写（如"她笑了笑"反复出现），
  /// 同时保持较低值避免影响正常修辞（如合理排比）。
  final double frequencyPenalty;

  /// 思考预算档位（v0.2.2 新增，存储 ReasoningEffort 枚举 name）
  ///
  /// 可选值：'disabled' / 'low' / 'medium' / 'high'。
  /// null = 未配置（跟随模型默认行为，不发送 reasoning 参数）。
  ///
  /// **作用范围**：仅 generating（生成阶段）与 reviewing（审查阶段）阶段消费
  /// 此参数；extracting（关键词提取）/summarizing（事件摘要）
  /// 等结构化阶段硬编码 disabled，不受此配置影响。
  ///
  /// 持久化：SettingsRepository user_overrides
  ///（key: `intermediate.generation.reasoning_effort`）。
  /// 会话级覆盖：ChatSession.reasoningEffort（null = 跟随本全局默认）。
  final String? reasoningEffort;
}

/// 事实层配置（memory.factual 子节点，DOC-11 §9，2026-07-20 新增）
///
/// 控制事实层中间方案的提取、防护与注入行为。事实层在不引入 v0.3
/// Agent Loop 的前提下，通过 summarizing 阶段并行调用 extract_facts
/// 工具写入事实数据，解决长对话后设定漂移问题。
///
/// | 配置项 | 类型 | 默认值 | 说明 |
/// |--------|------|--------|------|
/// | enabled | bool | true | 事实层总开关 |
/// | key_entity_importance_threshold | int | 5 | 关键实体重要性门槛（>= 此值强制注入） |
/// | key_entity_auto_cap | int | 10 | 无条件自动携带的关键档案份数上限（DEC-06） |
/// | injection_max_entities | int | 20 | 注入 prompt 的最大实体数 |
/// | modify_confidence_threshold | int | 4 | 修改关键属性的置信度门槛 |
/// | max_updates_per_3turns | int | 4 | 同实体最近 3 轮最多更新次数 |
/// | max_attr_value_length | int | 500 | 单个属性值最长字数 |
class FactualConfig {
  const FactualConfig({
    this.enabled = true,
    this.keyEntityImportanceThreshold = 5,
    this.keyEntityAutoCap = 10,
    this.injectionMaxEntities = 20,
    this.forceInjectSafetyCap = 50,
    this.modifyConfidenceThreshold = 4,
    this.maxUpdatesPer3Turns = 4,
    this.maxAttrValueLength = 500,
  });

  factory FactualConfig.fromJson(Map<String, dynamic> json) => FactualConfig(
        enabled: json['enabled'] as bool? ?? true,
        keyEntityImportanceThreshold:
            json['key_entity_importance_threshold'] as int? ?? 5,
        keyEntityAutoCap: json['key_entity_auto_cap'] as int? ?? 10,
        injectionMaxEntities: json['injection_max_entities'] as int? ?? 20,
        forceInjectSafetyCap: json['force_inject_safety_cap'] as int? ?? 50,
        modifyConfidenceThreshold:
            json['modify_confidence_threshold'] as int? ?? 4,
        maxUpdatesPer3Turns: json['max_updates_per_3turns'] as int? ?? 4,
        maxAttrValueLength: json['max_attr_value_length'] as int? ?? 500,
      );

  /// 事实层总开关
  ///
  /// false 时跳过 extract_facts 工具调用，只调用 extract_summary
  /// （DOC-11 §15 边界情况）。
  final bool enabled;

  /// 关键实体重要性门槛（>= 此值强制注入 prompt）
  ///
  /// retrieving 阶段 FactContextBuilder 加载所有 importance >= 此值
  /// 的未归档实体，无需 keywords 命中（DOC-11 §6.1 步骤 1）。
  /// 默认 5（2026-08-06：从4提升至5），仅主角级别每轮自动注入。
  final int keyEntityImportanceThreshold;

  /// 无条件自动携带的关键档案份数上限（DEC-06，默认 10）
  ///
  /// importance >= [keyEntityImportanceThreshold] 的关键实体不再无界
  /// 全量注入：消费层（FactContextBuilder.buildFactBlock / 导演
  /// assembleDirectorCoreBlocks）按 importance DESC → updatedAt/updatedTurn
  /// 新者在前 → entityId 稳定序排序后取前 N 份。关键档案计入
  /// [injectionMaxEntities] 总量（关键 ≤ 本上限 + 本轮相关填充 = 总量）；
  /// forceWorld/forceDirective 显式常驻通道不受此上限约束（各自
  /// [forceInjectSafetyCap] 独立安全帽）。
  final int keyEntityAutoCap;

  /// 注入 prompt 的最大实体数
  ///
  /// 超过此值时只注入 importance 最高的 + 本轮 keywords 命中的实体
  /// （DOC-11 §5.2、§15 边界情况）。
  final int injectionMaxEntities;

  /// 强制注入实体总数兜底上限（v0.2.3）
  ///
  /// 防大量开开关撑爆 prompt；超限按 importance 降序截断并记警告。
  final int forceInjectSafetyCap;

  /// 修改关键属性的置信度门槛
  ///
  /// importance >= 4 的关键属性（如角色名、种族），需要 confidence
  /// >= 此值才允许 UPDATE_ATTR（DOC-11 §7.2 三重防护第三层）。
  final int modifyConfidenceThreshold;

  /// 同实体最近 3 轮最多更新次数（DOC-11 §7.4.5）
  ///
  /// 防止 LLM 把"临时状态"误当"持久事实"提取，导致主角每轮都产出
  /// FactsDelta、历史表爆炸。超出此值时跳过本次更新。
  final int maxUpdatesPer3Turns;

  /// 单个属性值最长字数（DOC-11 §7.4.6）
  ///
  /// 防止 location.description 越更新越长。超出此值时跳过本次更新。
  final int maxAttrValueLength;
}

/// 推荐回复配置（suggest_reply 组，2026-07-29 新增）
///
/// 推荐回复功能：点击按钮调用 LLM 生成 3 条候选用户回复，
/// 浮出气泡供用户选择，点击某条填充到输入框光标位置。
///
/// **省 token 设计**：
/// - 单次非流式调用，禁用 reasoning
/// - 上下文：最近 1 轮全文 + 前 2 轮 micro 摘要
/// - 输出：JSON 格式 3 条候选，每条限制字数
/// - 预估：约 500~800 token/次
///
/// **模型配置优先级**：
/// 1. 会话级 `suggestReplyPresetId/ModelId`
/// 2. 全局 `suggest_reply.preset_id/model_id`
/// 3. generating 阶段模型（fallback）
///
/// **提示词优先级**：
/// 1. 会话级 `suggestReplyPromptOverride`
/// 2. 全局 `suggest_reply.prompt`
/// 3. 内置默认提示词（`kSuggestReplyDefaultPrompt`）
///
/// 持久化 key 前缀：`intermediate.suggest_reply.*`
class SuggestReplyConfig {
  const SuggestReplyConfig({
    this.presetId = '',
    this.modelId = '',
    this.prompt = '',
    this.temperature = 0.8,
    this.maxTokens = 600,
    this.candidateCount = 3,
    this.maxReplyLength = 150,
  });

  factory SuggestReplyConfig.fromJson(Map<String, dynamic> json) =>
      SuggestReplyConfig(
        presetId: json['preset_id'] as String? ?? '',
        modelId: json['model_id'] as String? ?? '',
        prompt: json['prompt'] as String? ?? '',
        temperature: (json['temperature'] as num?)?.toDouble() ?? 0.8,
        maxTokens: json['max_tokens'] as int? ?? 600,
        candidateCount: json['candidate_count'] as int? ?? 3,
        maxReplyLength: json['max_reply_length'] as int? ?? 150,
      );

  /// 推荐回复专用供应商 ID（空串 = fallback 到 generating 阶段）
  final String presetId;

  /// 推荐回复专用模型 ID（空串 = fallback 到 generating 阶段）
  final String modelId;

  /// 推荐回复系统提示词（空串 = 使用内置默认提示词）
  final String prompt;

  /// 生成温度（默认 0.8，与故事模式一致）
  ///
  /// 推荐回复需要一定创造性以提供多样化选项。
  final double temperature;

  /// 单次生成最大 token 数（默认 600）
  ///
  /// API 层面的总 token 硬限制，防止 LLM 输出过长被截断。
  /// 与 [maxReplyLength] 互补：maxTokens 是 API 兜底，
  /// maxReplyLength 是提示词层面的单条质量控制。
  final int maxTokens;

  /// 一次生成的候选回复数量（默认 3）
  final int candidateCount;

  /// 单条候选回复最大字数（默认 150）
  ///
  /// 在提示词中告诉 LLM 每条回复不超过多少字。
  /// 与 [maxTokens] 互补：maxReplyLength 控制单条质量，
  /// maxTokens 是 API 层面的总 token 兜底。
  final int maxReplyLength;
}
