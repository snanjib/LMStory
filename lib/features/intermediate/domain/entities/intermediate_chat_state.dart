import 'package:lmstory/core/llm/llm_usage.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/memory/domain/entities/event_summary.dart';
import 'package:lmstory/features/memory/domain/entities/experiential_memory.dart';
import 'package:lmstory/features/memory/domain/entities/facts_change_record.dart';
import 'package:lmstory/features/memory/domain/services/fact_context_builder.dart';
import 'package:lmstory/features/story_runtime/domain/entities/classified_keywords.dart';
import 'package:lmstory/features/story_runtime/domain/entities/context_usage_estimate.dart';
import 'package:lmstory/features/story_runtime/domain/entities/message_variant_record.dart';
import 'package:lmstory/features/story_runtime/domain/entities/round_artifacts.dart';
import 'package:lmstory/features/story_runtime/domain/entities/story_phase_models.dart';
import 'package:lmstory/features/story_runtime/domain/services/compaction_service.dart'
    show StoryCompactionService;
import 'package:lmstory/features/story_runtime/domain/services/suggest_reply_generator.dart'
    show SuggestReplyGenerator;

// P2 解耦：IntermediatePhase / FailureContext / ErrorCategory 为两模式共享
// 状态机原语，已上移 story_runtime；此处 export 垫片保持旧引用路径兼容
//（import 供本文件使用，export 供下游旧路径引用）。
export 'package:lmstory/features/story_runtime/domain/entities/story_phase_models.dart'
    show ErrorCategory, FailureContext, IntermediatePhase;

/// 中级模式 Controller 状态（DOC-09B §7.1）
///
/// [retryCounts] 启用，按阶段记录自动重试次数。
class IntermediateChatState {
  const IntermediateChatState({
    required this.phase,
    required this.messages,
    required this.retryCounts,
    required this.session,
    this.streamingGenerated,
    this.streamingGeneratedThinking,
    this.extractedKeywords,
    this.classifiedKeywords,
    this.retrievedMemories,
    this.retrievedFacts,
    this.streamingReply,
    this.streamingReplyThinking,
    this.currentEventSummary,
    this.currentFactsChanges,
    this.failureContext,
    this.userInput,
    this.generatedText,
    this.regenerateTurnNumber,
    this.artifactsByTurnNumber,
    this.compactedTurnBase = 0,
    this.pendingUserMessage,
    this.isPreparingRegenerate = false,
    this.embeddingDegradedForRound = false,
    // ── 停止中标识（2026-08-10 新增）───────────────────────────────────────
    //
    // 用户点击停止按钮后立即置 true，后台清理完成后置 false。
    // UI 据此显示灰色"正在终止"按钮（带动画），并禁用发送。
    // 生命周期：cancel() 置 true -> _streamRunner.cancel() 后台完成 -> 置 false。
    // clearTemporary() 不清空此字段（由 controller 的后台回调管理）。
    this.isStopping = false,
    // ── 审查开关（v0.2.2 新增）─────────────────────────────────────────
    //
    // 本轮是否启用审查（reviewing 阶段）。
    // 在 _prepareAndRunRound 中通过 _shouldReview(round) 计算并设置，
    // 供 UI 在生成中判断是否显示 GeneratePanel：
    // - true：显示生成面板（generating 流式生成 → reviewing 流式最终回复）
    // - false：不显示生成面板（generating 流式直接在回复气泡位置显示）
    this.isReviewEnabled = false,
    // ── 推荐回复（suggest_reply，2026-07-29 新增）─────────────────────────
    //
    // 推荐回复功能：点击按钮后调用 LLM 生成 3 条候选用户回复，
    // 浮出气泡供用户选择，点击某条填充到输入框光标位置。
    //
    // 生命周期：点击按钮 → isGeneratingSuggest=true → 生成完成填充 suggestReplies
    // → suggestExpanded=true（展开气泡）→ 用户点击气泡/发送消息 → 全部清空。
    // 生成失败 → suggestFailed=true（浮层显示失败提示+重试按钮）。
    //
    // **省 token 设计**：气泡持久化跨页面切换，发送消息时才真正销毁。
    this.suggestReplies = const [],
    this.isGeneratingSuggest = false,
    this.suggestExpanded = false,
    this.suggestFailed = false,
    // 压缩保留量触底警示轮次号（新增）────────────────────────
    //
    // 最近一次压缩保留量触底（触发线 − 检索预留 − 基础上下文 ≤ 0）的
    // 轮次号；null = 未触底。压缩摘要卡据此显示警示（连续压缩/上下文
    // 吃满的风险）。生命周期：压缩阶段命中置值、未命中清空；不持久化
    //（重进会话后按需重现）。
    this.compactionFloorWarningTurn,
    // ── 已归档轮次范围──────────────────────────────────
    //
    // 最近一次压缩覆盖的轮次区间（1 基）：摘要卡渲染「已归档第 X–Y 轮」。
    // from = 压缩前累计基数+1，to = 压缩后累计基数。轮内压缩时置值；
    // 不持久化（重进会话按需重现）。
    this.archivedTurnRange,
    // ── 疑似重复候选────────────────────────────────────
    //
    // 本轮 create_entity 的名称与既有实体互为包含的候选（与 applier
    // 创建侧警告同口径）。事实变更小窗渲染「疑似重复」条目，点击进
    // 记忆库归并预选。仅当前轮内存态；新一轮开始时清空。
    this.similarNameCandidates,
    // ── 上下文用量指示（自导演移植；口径同 advanced_chat_state）──
    //
    // 与轮前压缩判定同源：contextWindowTokens = _resolveContextWindow 结果；
    // compactionTriggerTokens = contextWindow × compactionTriggerRatio
    // （环形指示器满刻度）。会话打开 loadHistory 与每轮准备阶段刷新。
    this.contextWindowTokens,
    this.compactionTriggerTokens,
    // 最近一轮主请求（reviewing 启用时为其结果，否则 generating）的真实
    // usage。故事模式不持久化 usage（导演存 artifacts.agentWorkSummary）——
    // 仅内存维护，重进会话后至下一轮生成前为 null（空环）。
    this.lastPromptTokens,
    this.lastInputTokens,
    this.lastCompletionTokens,
    this.lastCacheReadTokens,
    this.lastUsageWarnings = const [],
    // 上方 last* 分项是否为本地估算兜底（端点未回 usage 时控制器以
    // tiktoken 估算写入）。仅影响面板「≈」标注，不参与命中率累计。
    this.lastUsageIsEstimated = false,
    // 会话累计 prompt/缓存读 token（averageCacheHit 的分子分母；同不持久化）
    this.contextPromptTokensTotal = 0,
    this.contextCacheReadTokensTotal = 0,
    // 会话累计完整输入 token（命中率分母；Anthropic/OpenAI 同口径）
    this.contextInputTokensTotal = 0,
    // 当前预计上下文（主数字；压缩后即时调整，null = 尚未有估算）
    this.contextEstimate,
    // ── 手动压缩（上下文用量指示 §4.3，自导演移植）──────────────────
    this.isManualCompacting = false,
    this.manualCompactionDelta = '',
    this.manualCompactionError,
    // ── 稿件变体──────────────
    //
    // 重生成/编辑重发的旧版快照（message_variants 表内存镜像），loadHistory
    // /收稿/切换/删除四处写点。切换器渲染条件=variants.length>1 且指针非 null。
    this.variantsByTurn,
    // 新变体收稿高亮信号（2s）：值=轮次号；UI 消费后经 clearVariantFlash 清除
    this.variantFlashTurn,
    // 收稿时刻（epoch ms， 口径）：高亮剩余时长从收稿起算，
    // 行延迟物化时只闪剩余窗口
    this.variantFlashStartedAtMs,
    // 变体切换被拒提示计数与原因（存在后续轮/已压缩区域无法安全交换
    // 记忆层，页面 ref.listen 消费弹 toast）
    this.variantSwitchBlockedTick = 0,
    this.variantSwitchBlockedReason,
    this.factWriteWarning,
    // ── 中断正文保留─────────────────────────────
    //
    // 失败/中断时把流式缓冲（streamingReply ?? streamingGenerated）的非空
    // 快照拷贝至此，failed 态渲染半截稿件卡；「以此收稿」消费它，
    // 「续写」以它为上下文注入。正常收稿/清本轮时置空。
    this.partialReplySnapshot,
  });

  /// 初始状态
  factory IntermediateChatState.initial(ChatSession session) =>
      IntermediateChatState(
        phase: IntermediatePhase.idle,
        messages: [],
        retryCounts: {},
        session: session,
      );

  /// 当前阶段
  final IntermediatePhase phase;

  /// 已持久化的消息列表（不含流式中的临时内容）
  final List<ChatMessage> messages;

  /// 请求1生成流式内容（generating 阶段实时更新，reviewing 后折叠）
  final String? streamingGenerated;

  /// 请求1生成阶段的思考/推理内容（generating 阶段实时更新）
  ///
  /// 来自模型的 `reasoning_content` / `reasoning` 字段，在 GeneratePanel 中
  /// 以可折叠的"思考过程"区块展示。null 表示无思考内容或模型未返回思考链。
  final String? streamingGeneratedThinking;

  /// 请求1输出的检索关键词（generating 完成后填充）
  final List<String>? extractedKeywords;

  /// 分类关键词（extracting 完成后填充，B-12 新增）
  ///
  /// 与 [extractedKeywords]（扁平化）互补，供 ExtractPanel 分组显示
  /// （characters / items / locations / actions / plots 五类分组，
  /// 与 [ClassifiedKeywords] 字段对齐，DOC-06B §6.2A）。
  final ClassifiedKeywords? classifiedKeywords;

  /// 检索到的经历记忆（retrieving 完成后填充）
  final List<ExperientialMemory>? retrievedMemories;

  /// 检索到的事实层命中（retrieving 完成后填充，DOC-11 §6.1）
  ///
  /// 经历层 [retrievedMemories] 的事实层对照。包含命中的实体列表，
  /// 每个实体携带其属性快照、是否关键实体、是否关键词命中。
  /// null 表示事实层未启用或 retrieving 阶段未执行；空列表表示启用但无命中。
  /// UI 检索面板据此展示【世界设定】分区。
  final List<RetrievedFact>? retrievedFacts;

  /// 请求2回复流式内容（reviewing 阶段实时更新，主区域显示）
  final String? streamingReply;

  /// 请求2审查阶段的思考/推理内容（reviewing 阶段实时更新）
  ///
  /// 来自模型的 `reasoning_content` / `reasoning` 字段，在回复气泡中
  /// 以可折叠的"思考过程"区块展示。null 表示无思考内容或模型未返回思考链。
  final String? streamingReplyThinking;

  /// 请求2输出的事件摘要（reviewing 完成后填充，persisting 阶段使用）
  final EventSummary? currentEventSummary;

  /// 本轮事实层变更记录（summarizing 阶段填充，persisting 阶段使用后清空）
  ///
  /// 生成中态的 UI「事实层变更小窗」据此渲染。注意：summarizing 阶段填入的
  /// 记录 oldValue 为 null（事实层尚未应用，显示"应用中"）；persist 完成后
  /// 由 artifacts 提供含变更前/变更后的完整记录。
  final List<FactsChangeRecord>? currentFactsChanges;

  /// 失败时记录失败阶段 + 失败原因（phase=failed 时非 null）
  final FailureContext? failureContext;

  /// 重试计数（按阶段分别计数； 启用自动重试）
  final Map<IntermediatePhase, int> retryCounts;

  /// 当前会话（UI 访问 title 等；会话物化后更新为真实会话）
  final ChatSession session;

  /// 本轮用户输入（重试时复用）
  final String? userInput;

  /// 生成全文（review 注入 + UI 折叠展示）
  final String? generatedText;

  /// 重新生成的目标轮次号（简化 Fork）
  ///
  /// 非 null 时表示当前轮处于"重新生成"流程：用户消息（user_N）已存在，
  /// `_runPersistPhase` 应走 `persistRegeneratedRound` 分支（只写 assistant + 事件摘要），
  /// 而非 `persistRound`（写 user + assistant + 事件摘要）。
  ///
  /// 生命周期：`regenerateMessage()` 入口置为目标轮次号 → 持久化完成 / 失败 / 取消
  /// 时由 `clearTemporary` 置 null。`sendMessage` / `editAndResend` 流程保持 null。
  final int? regenerateTurnNumber;

  /// 历史轮次的中间产物（按 turnNumber 索引）
  ///
  ///  新增：持久化每轮的生成内容/关键词/检索结果，使历史轮次的小窗
  /// 在切换会话或重新进入时仍可见。loadHistory 时从数据库加载填充，
  /// 当前轮次 persist 成功后追加 entry。
  ///
  /// deleteRound/regenerateMessage/editAndResend 时清理对应 turn 的 entry。
  /// clearTemporary **不清空**此字段（历史轮次产物不属临时状态）。
  final Map<int, StoryRoundArtifacts>? artifactsByTurnNumber;

  /// 已压缩覆盖的轮次基数（修复，2026-08-23）
  ///
  /// turnNumber 必须跨压缩保持单调，否则压缩后新记忆的轮次号会回归到
  /// 库中旧记忆之前（recency 失效 / 按轮删除过杀 / 时间线标签错乱）。
  ///
  /// 语义：最新 CompactionPoint 之前已被摘要覆盖的完整对话轮数。所有
  /// turnNumber 推导统一为：
  ///
  ///   turn = compactedTurnBase + 可见真实对话消息数 ~/ 2 + 1
  ///
  /// 维护时机：loadHistory / _prepareAndRunRound 装载历史时按
  /// [StoryCompactionService.compactedTurnBaseFor] 重算；轮内压缩成功后由
  /// 压缩阶段追加本轮新覆盖的轮数。clearTemporary 不清空（会话级状态）。
  final int compactedTurnBase;

  /// 未持久化的临时用户消息（DOC-09A-2 §6.5：UI 即时显示 + 失败时保留）
  ///
  /// `sendMessage` 时立即创建并写入本字段，UI body 在 [messages] 列表前
  /// 渲染本字段（如果非 null）。`_runPersistPhase` 成功后清空（此时已落入
  /// [messages] 列表作为持久化消息）。`_fail` / `clearTemporary` 不清空
  /// 本字段（失败时保留用户消息显示，让用户看到自己发了什么、便于重发）。
  ///
  /// `regenerateMessage` / `editAndResend` **不设置**本字段（复用已存在的
  /// 用户消息，已在 [messages] 中）。
  final ChatMessage? pendingUserMessage;

  /// 重新生成/编辑重发"准备中"标识（DB 删除期间遮罩 UI）。
  ///
  /// `regenerateMessage` / `editAndResend` 入口立即置 true，避免 await
  /// `deleteRoundAndDownstream` 期间 UI 仍显示待删除的下游消息（残留感）。
  /// DB 删除完成、state.messages 截断时同步置 false（此时下游消息已移除，
  /// 故事模式生成小窗接管 UI 反馈）。DB 删除失败时也置 false（回退可操作态）。
  ///
  /// 生命周期：仅覆盖"DB 删除 → state 截断"这一极短窗口，不跨故事模式生成阶段。
  final bool isPreparingRegenerate;

  /// 本轮是否临时降级为关键词检索（E104 错误用户选择"临时降级继续"后置 true）
  ///
  /// 2026-07-21 新增。用于检索小窗显示「临时降级」标签。
  /// 仅在当前轮次有效，persist 成功或清空时重置为 false。
  ///
  /// 作用：在 IntermediateChatController._resolveQueryVector /
  /// _resolveEmbedding 中跳过 embedding 调用（直接返回 null），保证本轮
  /// 后续阶段不再因 embedding 失败而中断。本轮生成的记忆 has_embedding=false
  /// （后续可通过"重建向量索引"补全）。
  final bool embeddingDegradedForRound;

  /// 是否正在停止生成（2026-08-10 新增）
  ///
  /// 用户点击停止按钮后立即置 true，表示后台正在清理流式资源。
  /// UI 据此显示灰色"正在终止"按钮（带动画），并禁用发送。
  /// 后台 `_streamRunner.cancel` 完成后由 controller 置 false。
  /// [clearTemporary] 不清空此字段（由 controller 后台回调管理）。
  final bool isStopping;

  /// 本轮是否启用审查（v0.2.2 新增）
  ///
  /// 在 _prepareAndRunRound 中通过 _shouldReview(round) 计算并设置。
  /// 供 UI 在生成中判断是否显示 GeneratePanel：
  /// - true：显示生成面板（generating 流式生成 → reviewing 流式最终回复）
  /// - false：不显示生成面板（generating 流式直接在回复气泡位置显示）
  final bool isReviewEnabled;

  // ── 推荐回复状态字段（suggest_reply，2026-07-29 新增）─────────────────

  /// 推荐回复候选列表
  ///
  /// 由 [SuggestReplyGenerator] 生成，通常 3 条。空列表表示无候选或未生成。
  /// 气泡浮层组件读取此字段渲染候选气泡。
  ///
  /// 生命周期：
  /// - 点击推荐按钮 → 置空 + isGeneratingSuggest=true
  /// - 生成成功 → 填充候选 + isGeneratingSuggest=false + suggestExpanded=true
  /// - 生成失败 → 保持空 + isGeneratingSuggest=false（UI 显示失败提示）
  /// - 用户点击候选 → 选中条填充输入框，全部清空
  /// - 用户发送消息 → 全部清空（本轮结束）
  final List<String> suggestReplies;

  /// 是否正在生成推荐回复
  ///
  /// true 时按钮显示 loading 指示器，禁用重复点击。
  /// 不阻塞用户输入和发送消息——用户可随时发消息中断生成（生成结果作废）。
  final bool isGeneratingSuggest;

  /// 推荐回复气泡是否展开
  ///
  /// true = 展开显示所有候选气泡（默认态）
  /// false = 折叠为单个 chip（用户主动收起或生成失败后）
  ///
  /// 折叠态保留 [suggestReplies] 数据，用户可再次展开查看，避免重复生成浪费 token。
  final bool suggestExpanded;

  /// 推荐回复生成是否失败
  ///
  /// true 时浮层显示失败提示（而非直接消失），用户可点击重试或关闭。
  /// 在以下情况重置为 false：重新生成、用户关闭浮层、用户发送消息。
  final bool suggestFailed;

  /// 压缩保留量触底警示轮次号
  ///
  /// 最近一次压缩保留量触底（触发线 − 检索预留 − 基础上下文 ≤ 0）时的
  /// 本轮轮次号；null = 未触底（或后续压缩已恢复）。压缩摘要卡据此
  /// 显示警示。压缩阶段命中置值、未命中清空；不持久化。
  final int? compactionFloorWarningTurn;

  /// 已归档轮次范围：摘要卡「已归档第 X–Y 轮」
  final ({int from, int to})? archivedTurnRange;

  /// 疑似重复候选：本轮创建名 ↔ 既有实体互为包含
  final List<SimilarNameCandidate>? similarNameCandidates;

  /// 解析后的上下文窗口 token（null = 尚未解析）
  final int? contextWindowTokens;

  /// 压缩触发线 token（环形指示器满刻度），与 shouldCompact 同公式同值
  final int? compactionTriggerTokens;

  /// 最近一轮主请求的真实 prompt/completion/缓存读 token
  ///
  /// reviewing 启用时取 reviewing 结果（上下文最全的请求），否则取
  /// generating。null = 本会话尚未生成过（或端点未回 usage）。
  final int? lastPromptTokens;

  /// 最近一轮主请求的完整输入（Anthropic 含 cache read/creation）
  final int? lastInputTokens;
  final int? lastCompletionTokens;
  final int? lastCacheReadTokens;

  /// 最近一轮请求的计量异常说明（字段冲突/非法样本等）。
  ///
  /// 原值仍保留在 [lastCacheReadTokens] 供诊断，但该样本不进入命中率
  /// 展示与累计。
  final List<String> lastUsageWarnings;

  /// 最近一轮缓存命中率（缺输入面/缓存分项或存在计量异常 → null）
  double? get lastCacheHitRatio => lastUsageWarnings.isNotEmpty
      ? null
      : LlmUsage.hitRateOf(
          cacheReadTokens: lastCacheReadTokens,
          inputTokens: lastInputTokens,
        );

  /// 最近一轮分项是否因冲突/越界等异常不可比较
  bool get lastCacheSampleInvalid =>
      lastUsageWarnings.isNotEmpty ||
      (lastCacheReadTokens != null &&
          lastInputTokens != null &&
          lastCacheHitRatio == null);

  /// 最近一轮分项是否为本地估算值（见构造器注释；随 last* 同生命周期，
  /// 不持久化）
  final bool lastUsageIsEstimated;

  /// 会话累计协议原生 prompt token（仅诊断展示；不可做命中率分母）
  final int contextPromptTokensTotal;

  /// 会话累计缓存读 token（缓存命中率分子；，不持久化）
  final int contextCacheReadTokensTotal;

  /// 会话累计完整输入 token（缓存命中率分母；与导演模式同口径）
  final int contextInputTokensTotal;

  /// 当前预计上下文（主数字；压缩等本地材料变更后即时调整）
  final ContextUsageEstimate? contextEstimate;

  /// 会话加权平均缓存命中率 = ΣcacheRead / Σ完整输入。
  ///
  /// 不可用 `cacheRead/(cacheRead+prompt)`：OpenAI/Gemini 的 prompt 已含
  /// 缓存命中部分，会把命中率系统性算低。
  double? get averageCacheHit => contextInputTokensTotal > 0
      ? contextCacheReadTokensTotal / contextInputTokensTotal
      : null;

  /// 手动压缩进行中（§4.3；输入区发送/重生成入口据此拒绝）
  final bool isManualCompacting;

  /// 手动压缩摘要流式增量（面板实时打字）
  final String manualCompactionDelta;

  /// 手动压缩失败信息（非 null = 失败态，面板显示重试）
  final String? manualCompactionError;

  /// 稿件变体表
  final Map<int, List<MessageVariantRecord>>? variantsByTurn;

  /// 新变体收稿高亮信号（值=轮次号；null=无信号）
  final int? variantFlashTurn;

  /// 高亮起表时刻（epoch ms；见构造器注释）
  final int? variantFlashStartedAtMs;

  /// 变体切换被拒提示计数（页面监听弹 toast）
  final int variantSwitchBlockedTick;

  /// 最近一次变体切换被拒的原因（downstream/compacted）；null=无
  final String? variantSwitchBlockedReason;

  /// One state emission when a committed round has individual fact failures.
  final ({int turnNumber, int count})? factWriteWarning;

  /// 失败/中断轮的非空正文快照
  final String? partialReplySnapshot;

  /// Sentinel 区分"未提供"与"显式 null"
  static const _sentinel = Object();

  /// 创建副本并应用修改
  IntermediateChatState copyWith({
    IntermediatePhase? phase,
    List<ChatMessage>? messages,
    Object? streamingGenerated = _sentinel,
    Object? streamingGeneratedThinking = _sentinel,
    Object? extractedKeywords = _sentinel,
    Object? classifiedKeywords = _sentinel,
    Object? retrievedMemories = _sentinel,
    Object? retrievedFacts = _sentinel,
    Object? streamingReply = _sentinel,
    Object? streamingReplyThinking = _sentinel,
    Object? currentEventSummary = _sentinel,
    Object? currentFactsChanges = _sentinel,
    Object? failureContext = _sentinel,
    Map<IntermediatePhase, int>? retryCounts,
    ChatSession? session,
    Object? userInput = _sentinel,
    Object? generatedText = _sentinel,
    Object? regenerateTurnNumber = _sentinel,
    Object? artifactsByTurnNumber = _sentinel,
    int? compactedTurnBase,
    Object? pendingUserMessage = _sentinel,
    bool? isPreparingRegenerate,
    bool? embeddingDegradedForRound,
    bool? isStopping,
    bool? isReviewEnabled,
    // 推荐回复字段（2026-07-29 新增）
    List<String>? suggestReplies,
    bool? isGeneratingSuggest,
    bool? suggestExpanded,
    bool? suggestFailed,
    Object? compactionFloorWarningTurn = _sentinel,
    Object? similarNameCandidates = _sentinel,
    Object? archivedTurnRange = _sentinel,
    // 上下文用量指示
    Object? contextWindowTokens = _sentinel,
    Object? compactionTriggerTokens = _sentinel,
    Object? lastPromptTokens = _sentinel,
    Object? lastInputTokens = _sentinel,
    Object? lastCompletionTokens = _sentinel,
    Object? lastCacheReadTokens = _sentinel,
    List<String>? lastUsageWarnings,
    bool? lastUsageIsEstimated,
    int? contextPromptTokensTotal,
    int? contextCacheReadTokensTotal,
    int? contextInputTokensTotal,
    Object? contextEstimate = _sentinel,
    // 手动压缩三字段 sentinel 化（同源坑：流式回调只传 delta
    // 不传标志，默认值会把 isManualCompacting 打回 false，互斥守卫失效）
    Object? isManualCompacting = _sentinel,
    Object? manualCompactionDelta = _sentinel,
    Object? manualCompactionError = _sentinel,
    // 稿件变体+中断快照
    Object? variantsByTurn = _sentinel,
    Object? variantFlashTurn = _sentinel,
    Object? variantFlashStartedAtMs = _sentinel,
    int? variantSwitchBlockedTick,
    String? variantSwitchBlockedReason,
    ({int turnNumber, int count})? factWriteWarning,
    Object? partialReplySnapshot = _sentinel,
  }) {
    return IntermediateChatState(
      phase: phase ?? this.phase,
      messages: messages ?? this.messages,
      streamingGenerated: identical(streamingGenerated, _sentinel)
          ? this.streamingGenerated
          : streamingGenerated as String?,
      streamingGeneratedThinking:
          identical(streamingGeneratedThinking, _sentinel)
              ? this.streamingGeneratedThinking
              : streamingGeneratedThinking as String?,
      extractedKeywords: identical(extractedKeywords, _sentinel)
          ? this.extractedKeywords
          : extractedKeywords as List<String>?,
      classifiedKeywords: identical(classifiedKeywords, _sentinel)
          ? this.classifiedKeywords
          : classifiedKeywords as ClassifiedKeywords?,
      retrievedMemories: identical(retrievedMemories, _sentinel)
          ? this.retrievedMemories
          : retrievedMemories as List<ExperientialMemory>?,
      retrievedFacts: identical(retrievedFacts, _sentinel)
          ? this.retrievedFacts
          : retrievedFacts as List<RetrievedFact>?,
      streamingReply: identical(streamingReply, _sentinel)
          ? this.streamingReply
          : streamingReply as String?,
      streamingReplyThinking: identical(streamingReplyThinking, _sentinel)
          ? this.streamingReplyThinking
          : streamingReplyThinking as String?,
      currentEventSummary: identical(currentEventSummary, _sentinel)
          ? this.currentEventSummary
          : currentEventSummary as EventSummary?,
      currentFactsChanges: identical(currentFactsChanges, _sentinel)
          ? this.currentFactsChanges
          : currentFactsChanges as List<FactsChangeRecord>?,
      failureContext: identical(failureContext, _sentinel)
          ? this.failureContext
          : failureContext as FailureContext?,
      retryCounts: retryCounts ?? this.retryCounts,
      session: session ?? this.session,
      userInput: identical(userInput, _sentinel)
          ? this.userInput
          : userInput as String?,
      generatedText: identical(generatedText, _sentinel)
          ? this.generatedText
          : generatedText as String?,
      regenerateTurnNumber: identical(regenerateTurnNumber, _sentinel)
          ? this.regenerateTurnNumber
          : regenerateTurnNumber as int?,
      artifactsByTurnNumber: identical(artifactsByTurnNumber, _sentinel)
          ? this.artifactsByTurnNumber
          : artifactsByTurnNumber as Map<int, StoryRoundArtifacts>?,
      compactedTurnBase: compactedTurnBase ?? this.compactedTurnBase,
      pendingUserMessage: identical(pendingUserMessage, _sentinel)
          ? this.pendingUserMessage
          : pendingUserMessage as ChatMessage?,
      isPreparingRegenerate:
          isPreparingRegenerate ?? this.isPreparingRegenerate,
      embeddingDegradedForRound:
          embeddingDegradedForRound ?? this.embeddingDegradedForRound,
      isStopping: isStopping ?? this.isStopping,
      isReviewEnabled: isReviewEnabled ?? this.isReviewEnabled,
      suggestReplies: suggestReplies ?? this.suggestReplies,
      isGeneratingSuggest: isGeneratingSuggest ?? this.isGeneratingSuggest,
      suggestExpanded: suggestExpanded ?? this.suggestExpanded,
      suggestFailed: suggestFailed ?? this.suggestFailed,
      compactionFloorWarningTurn:
          identical(compactionFloorWarningTurn, _sentinel)
              ? this.compactionFloorWarningTurn
              : compactionFloorWarningTurn as int?,
      archivedTurnRange: identical(archivedTurnRange, _sentinel)
          ? this.archivedTurnRange
          : archivedTurnRange as ({int from, int to})?,
      similarNameCandidates: identical(similarNameCandidates, _sentinel)
          ? this.similarNameCandidates
          : similarNameCandidates as List<SimilarNameCandidate>?,
      contextWindowTokens: identical(contextWindowTokens, _sentinel)
          ? this.contextWindowTokens
          : contextWindowTokens as int?,
      compactionTriggerTokens: identical(compactionTriggerTokens, _sentinel)
          ? this.compactionTriggerTokens
          : compactionTriggerTokens as int?,
      lastPromptTokens: identical(lastPromptTokens, _sentinel)
          ? this.lastPromptTokens
          : lastPromptTokens as int?,
      lastInputTokens: identical(lastInputTokens, _sentinel)
          ? this.lastInputTokens
          : lastInputTokens as int?,
      lastCompletionTokens: identical(lastCompletionTokens, _sentinel)
          ? this.lastCompletionTokens
          : lastCompletionTokens as int?,
      lastCacheReadTokens: identical(lastCacheReadTokens, _sentinel)
          ? this.lastCacheReadTokens
          : lastCacheReadTokens as int?,
      lastUsageWarnings: lastUsageWarnings ?? this.lastUsageWarnings,
      lastUsageIsEstimated: lastUsageIsEstimated ?? this.lastUsageIsEstimated,
      contextPromptTokensTotal:
          contextPromptTokensTotal ?? this.contextPromptTokensTotal,
      contextCacheReadTokensTotal:
          contextCacheReadTokensTotal ?? this.contextCacheReadTokensTotal,
      contextInputTokensTotal:
          contextInputTokensTotal ?? this.contextInputTokensTotal,
      contextEstimate: identical(contextEstimate, _sentinel)
          ? this.contextEstimate
          : contextEstimate as ContextUsageEstimate?,
      isManualCompacting: identical(isManualCompacting, _sentinel)
          ? this.isManualCompacting
          : isManualCompacting! as bool,
      manualCompactionDelta: identical(manualCompactionDelta, _sentinel)
          ? this.manualCompactionDelta
          : manualCompactionDelta! as String,
      manualCompactionError: identical(manualCompactionError, _sentinel)
          ? this.manualCompactionError
          : manualCompactionError as String?,
      variantsByTurn: identical(variantsByTurn, _sentinel)
          ? this.variantsByTurn
          : variantsByTurn as Map<int, List<MessageVariantRecord>>?,
      variantFlashTurn: identical(variantFlashTurn, _sentinel)
          ? this.variantFlashTurn
          : variantFlashTurn as int?,
      variantFlashStartedAtMs: identical(variantFlashStartedAtMs, _sentinel)
          ? this.variantFlashStartedAtMs
          : variantFlashStartedAtMs as int?,
      variantSwitchBlockedTick:
          variantSwitchBlockedTick ?? this.variantSwitchBlockedTick,
      variantSwitchBlockedReason: variantSwitchBlockedReason,
      factWriteWarning: factWriteWarning,
      partialReplySnapshot: identical(partialReplySnapshot, _sentinel)
          ? this.partialReplySnapshot
          : partialReplySnapshot as String?,
    );
  }

  /// 清理本轮临时产物（重试/清空/取消时用），保留 messages 和 userInput
  ///
  /// 同时清空 retryCounts——手动重试/取消后从新一轮开始，重试计数归零。
  /// **不清空** [artifactsByTurnNumber]——历史轮次产物不属临时状态。
  IntermediateChatState clearTemporary() {
    return copyWith(
      phase: IntermediatePhase.idle,
      streamingGenerated: null,
      streamingGeneratedThinking: null,
      extractedKeywords: null,
      classifiedKeywords: null,
      retrievedMemories: null,
      retrievedFacts: null,
      streamingReply: null,
      streamingReplyThinking: null,
      currentEventSummary: null,
      currentFactsChanges: null,
      failureContext: null,
      generatedText: null,
      // 显式置 null，结束"重新生成"流程标识
      regenerateTurnNumber: null,
      retryCounts: {},
      // 准备中标识归位（正常流程在 controller 截断 state 时已置 false，
      // 此处兜底防止异常路径残留导致 UI 永久遮罩）
      isPreparingRegenerate: false,
      // 2026-07-21：临时降级标识归位（避免下一轮误判为降级模式）
      embeddingDegradedForRound: false,
      // v0.2.2：审查开关归位（下一轮由 _prepareAndRunRound 重新计算）
      isReviewEnabled: false,
      // 疑似重复候选随轮清空
      similarNameCandidates: null,
      // 变体高亮信号随轮清理——取消/清本轮后信号
      // 滞留会让下一次 idle 渲染时切换器再闪 2s（跨轮残留）
      variantFlashTurn: null,
      variantFlashStartedAtMs: null,
      // 中断正文快照同属本轮临时产物——整轮重试/
      // 清空本轮/取消随轮清理（与新流式缓冲同生命周期，防跨轮陈旧残留）
      partialReplySnapshot: null,
    );
  }
}
