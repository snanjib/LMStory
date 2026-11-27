import 'package:lmstory/core/llm/llm_usage.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_live_block.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_timeline_block.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_work_step.dart';
import 'package:lmstory/features/advanced/domain/services/engineering_context_mode.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/entities/story_anchor.dart';
import 'package:lmstory/features/story_runtime/domain/entities/auxiliary_generation_failure.dart';
import 'package:lmstory/features/story_runtime/domain/entities/context_usage_estimate.dart';
import 'package:lmstory/features/story_runtime/domain/entities/message_variant_record.dart';
import 'package:lmstory/features/story_runtime/domain/entities/round_artifacts.dart';
import 'package:lmstory/features/story_runtime/domain/entities/story_phase_models.dart';

/// Transient current activity; content and execution events advance this state.
enum AgentActivity {
  waitingResponse,
  thinking,
  processing,
  generating,
  narrating,
  tool,
  retryWaiting
}

/// 导演模式 Controller 状态（P2 解耦：与 IntermediateChatState 拆分为
/// 两个独立完整类，骨架字段受控重复，不搞继承）。
///
/// 骨架字段（phase/messages/session/失败与重试/建议回复等）与
/// 故事模式语义一致；差异：
/// - 无六步管线专属产物字段（关键词/检索结果/审查开关等）
/// - 流式正文为直播分块 [liveBlocks]（opencode 式 part 分段），非单字符串
/// - 携带 5 个导演字段（agentSteps/agentWorkSummary/agentStoryAnchor/
///   agentAskPrompt/agentApprovalPrompt），原寄生在 IntermediateChatState
class AdvancedChatState {
  const AdvancedChatState({
    required this.phase,
    required this.messages,
    required this.retryCounts,
    required this.session,
    this.failureContext,
    this.userInput,
    this.regenerateTurnNumber,
    this.artifactsByTurnNumber,
    this.usageSummariesByTurn,
    this.compactedTurnBase = 0,
    this.pendingUserMessage,
    this.liveBlocks = const [],
    this.agentActivity = AgentActivity.waitingResponse,
    this.agentActivityStepIndex = 0,
    this.isPreparingRegenerate = false,
    this.embeddingDegradedForRound = false,
    // ── 停止中标识 ─────────────────────────────────────────────────────
    //
    // 用户点击停止按钮后立即置 true，后台清理完成后置 false。
    // UI 据此显示灰色"正在终止"按钮（带动画），并禁用发送。
    // 生命周期：cancel() 置 true -> 后台取消完成 -> 置 false。
    // clearTemporary() 不清空此字段（由 controller 的后台回调管理）。
    this.isStopping = false,
    // ── 推荐回复（suggest_reply）──────────────────────────────────────
    //
    // 与故事模式同源：点击按钮后调用 LLM 生成 3 条候选用户回复，
    // 浮出气泡供用户选择。生命周期与清空时机同故事模式。
    this.suggestReplies = const [],
    this.isGeneratingSuggest = false,
    this.suggestExpanded = false,
    this.suggestFailure,
    // ── 导演模式：本轮 agent 工作步骤 + 收拢摘要 ──────────────────────
    this.agentSteps = const [],
    this.agentTimeline = const [],
    this.agentWorkSummary,
    this.agentRetryWait,
    // 轮中预算进度快照（live work group 标题数据源）
    this.agentRoundProgress,
    // 50 轮大周期双任务阶段标记（任务一完稿后切 true，任务二期间定稿正文并冻结上方工作组）
    this.inMaintenancePhase = false,
    this.maintenanceStepStart = 0,
    this.loadingHistory = false,
    // 溢出自愈提示计数（单调递增，页面 ref.listen 消费弹 toast）
    this.overflowHealedTick = 0,
    // HITL 超时裁决提示计数（ask/审批分列，同上消费）
    this.hitlAskTimeoutTick = 0,
    this.hitlApprovalTimeoutTick = 0,
    // 变体切换被拒提示计数与原因（存在后续轮/已压缩区域无法安全交换
    // 记忆层，页面 ref.listen 消费弹 toast）
    this.variantSwitchBlockedTick = 0,
    this.variantSwitchBlockedReason,
    this.factWriteWarning,
    // ── 单槽待发消息（生成中排队，轮正常结束后自动发送一次）─────
    //
    // null = 无排队。排队文本同时落会话草稿列（重启/离开页面后回到输入
    // 框，绝不自动发送）；撤回时退还输入框可编辑。单槽：再次排队
    // 需先确认覆盖。
    this.queuedMessage,
    // ── 工程上下文模式（导演实验）三态解析结果 ─────────────────────
    //
    // loadHistory 打开/切换会话时对账会话列与账本纪元后写入；正常关闭为
    // 默认值。需要修复态下发送入口被拦截（留痕停轮、trim 跳过），用户经
    // 设置面板「修复重捕获/确认退出」处置后恢复。
    this.engineeringMode = EngineeringRuntimeMode.normalClosed,
    this.engineeringModeReason,
    // 上下文构成分段字符数（轮装配期埋点；key=system/coreBlocks/
    // history/directive，详情面板按占比×最近请求 promptTokens 估算展示）
    this.contextSegmentChars,
    this.variantsByTurn,
    this.variantFlashTurn,
    this.variantFlashStartedAtMs,
    // ── 导演模式：本轮剧情锚（live Recap 卡数据源）────────────────────
    this.agentStoryAnchor,
    // ── 导演模式：ask_user 横幅 / 监督模式审批横幅 ────────────────────
    this.agentAskPrompt,
    this.agentApprovalPrompt,
    // ── 上下文用量指示──────────────────────────────────
    // 与轮前压缩判定同源：contextWindowTokens = _resolveContextWindow 结果；
    // compactionTriggerTokens = contextWindow × compactionTriggerRatio
    // （环形指示器满刻度）。会话打开 loadHistory 与每轮准备阶段刷新。
    this.contextWindowTokens,
    this.compactionTriggerTokens,
    // 旧会话回填的最新请求 promptTokens（§3.2；新轮 persist 后清空）
    this.backfilledPromptTokens,
    // 同源回填的 cache 命中读分项（详情面板命中率分子）
    this.backfilledCacheReadTokens,
    // 同源回填的完整输入面（新日志才有；旧日志 null → 命中率样本降级）
    this.backfilledTotalInputTokens,
    // 同源回填的末次请求计量异常（缺失/旧日志为用户空列表）
    this.backfilledUsageWarnings,
    // 当前预计上下文（主数字；压缩后即时调整，null = 回填/实报兜底）
    this.contextEstimate,
    // ── 手动压缩（上下文用量指示 §4.3）────────────────────────────
    this.isManualCompacting = false,
    this.manualCompactionDelta = '',
    this.manualCompactionError,
  });

  /// 初始状态
  factory AdvancedChatState.initial(ChatSession session) => AdvancedChatState(
        phase: IntermediatePhase.idle,
        messages: [],
        retryCounts: {},
        session: session,
      );

  /// 当前阶段
  final IntermediatePhase phase;

  /// 已持久化的消息列表（不含流式中的临时内容）
  final List<ChatMessage> messages;

  /// 直播分块时间线（opencode 式 part 分段，2026-08-23 重构）
  ///
  /// agent 轮实时更新：思考/正文增量按 step 与类型分段追加（纯函数
  /// [AgentLiveTranscript]），UI 按序渲染交错块；最后一个非空文本段为
  /// 正文落库候选。persist 后清空——定稿内容走 messages。
  final List<AgentLiveBlock> liveBlocks;
  final AgentActivity agentActivity;
  final int agentActivityStepIndex;

  /// 失败时记录失败阶段 + 失败原因（phase=failed 时非 null）
  final FailureContext? failureContext;

  /// 重试计数（按阶段分别计数）
  final Map<IntermediatePhase, int> retryCounts;

  /// 当前会话（UI 访问 title 等；会话物化后更新为真实会话）
  final ChatSession session;

  bool get isAwaitingFirstRound =>
      session.messageCount == 0 &&
      (session.nextTurn ?? 1) == 1 &&
      messages.isEmpty;

  /// 本轮用户输入（重试时复用）
  final String? userInput;

  /// 重新生成的目标轮次号
  ///
  /// 非 null 时表示当前轮处于"重新生成"流程：用户消息（user_N）已存在，
  /// persist 应走 `persistRegeneratedRound` 分支（只写 assistant + 事件摘要），
  /// 而非 `persistRound`（写 user + assistant + 事件摘要）。
  final int? regenerateTurnNumber;

  /// 历史轮次的中间产物（按 turnNumber 索引）
  ///
  /// 导演轮的 agentSteps/agentWorkSummary/storyAnchor 快照持久化于此，
  /// 历史轮次重新进入时按时间线重建工具卡与 Recap。
  final Map<int, StoryRoundArtifacts>? artifactsByTurnNumber;

  /// 耗用统计覆盖整个会话，包括已压缩或未读取详细过程的轮。
  /// 有键但值为空表示该轮没有可读摘要。
  final Map<int, AgentWorkSummary?>? usageSummariesByTurn;

  AgentWorkSummary? get latestHistoryTurnSummary {
    final summaries = usageSummariesByTurn;
    final artifacts = artifactsByTurnNumber;
    final latestSummaryTurn = summaries == null || summaries.isEmpty
        ? null
        : summaries.keys.reduce((a, b) => a > b ? a : b);
    final latestDetailTurn = artifacts == null || artifacts.isEmpty
        ? null
        : artifacts.keys.reduce((a, b) => a > b ? a : b);
    if (latestDetailTurn != null &&
        (latestSummaryTurn == null || latestDetailTurn >= latestSummaryTurn)) {
      return artifacts?[latestDetailTurn]?.agentWorkSummary;
    }
    return summaries?[latestSummaryTurn];
  }

  Iterable<AgentWorkSummary?> get _historyUsageSummaries sync* {
    final summaries = usageSummariesByTurn;
    final details = artifactsByTurnNumber;
    if (summaries != null) {
      for (final entry in summaries.entries) {
        if (!(details?.containsKey(entry.key) ?? false)) yield entry.value;
      }
    }
    if (details != null) {
      for (final artifact in details.values) {
        yield artifact.agentWorkSummary;
      }
    }
  }

  ({
    double? averageCacheHit,
    int cacheCoveredRounds,
    int sessionRounds,
  }) get historyUsageStatistics {
    var input = 0;
    var cached = 0;
    var covered = 0;
    var rounds = 0;
    for (final summary in _historyUsageSummaries) {
      rounds++;
      if (summary == null || summary.lastCacheHitRatio == null) continue;
      covered++;
      input += summary.lastInputTokens ?? 0;
      cached += summary.lastCacheReadTokens ?? 0;
    }
    return (
      averageCacheHit: LlmUsage.hitRateOf(
        cacheReadTokens: cached,
        inputTokens: input,
      ),
      cacheCoveredRounds: covered,
      sessionRounds: rounds,
    );
  }

  /// 已压缩覆盖的轮次基数（修复，2026-08-23）
  ///
  /// 语义与维护时机同 IntermediateChatState.compactedTurnBase：保证导演轮
  /// 的 turnNumber 跨压缩单调（recency/按轮删除/时间线依赖真实轮次号）。
  /// loadHistory / _prepareAndRunRound 装载历史时重算。
  final int compactedTurnBase;

  /// 未持久化的临时用户消息（UI 即时显示 + 失败时保留）
  ///
  /// `sendMessage` 时立即创建并写入本字段，UI body 在 [messages] 列表前
  /// 渲染本字段（如果非 null）。persist 成功后清空；失败时保留。
  final ChatMessage? pendingUserMessage;

  /// 重新生成/编辑重发"准备中"标识（DB 删除期间遮罩 UI）。
  final bool isPreparingRegenerate;

  /// 本轮是否临时降级为关键词检索（E104 错误用户选择"临时降级继续"后置 true）
  ///
  /// 作用：query_facts 的向量检索跳过 embedding 调用（直接返回 null），
  /// 保证本轮后续不再因 embedding 失败而中断。
  final bool embeddingDegradedForRound;

  /// 是否正在停止生成
  final bool isStopping;

  // ── 推荐回复状态字段 ────────────────────────────────────────────────

  /// 推荐回复候选列表（通常 3 条，空列表表示无候选或未生成）
  final List<String> suggestReplies;

  /// 是否正在生成推荐回复
  final bool isGeneratingSuggest;

  /// 推荐回复气泡是否展开
  final bool suggestExpanded;

  /// 推荐回复生成是否失败
  final AuxiliaryGenerationFailure? suggestFailure;

  bool get suggestFailed => suggestFailure != null;

  /// 导演模式：本轮 agent 执行的工具步骤（live 渲染，结束后保留至下轮）
  final List<AgentWorkStep> agentSteps;

  /// 导演模式：请求重试等待中（null = 无等待）
  ///
  /// agent_runner 退避/Retry-After 等待开始时置位，等待结束（下一
  /// AgentStepStarted）/换轮时清除。UI 以 [AgentRetryWait.scheduledAtMs]
  /// 为锚渲染倒计时（防时钟偏差）。
  final AgentRetryWait? agentRetryWait;

  /// 导演模式：轮中预算进度（null = 非生成中/旧状态）
  ///
  /// 轮开始时快照（maxSteps 与 AgentBudget 同源 effectiveMaxSteps、
  /// startedAtMs 对齐 runner 秒表起点），每个 AgentStepStarted 推进
  /// currentStep。live work group 标题据此渲染「第 N/M 步 · 已用 X:XX」，
  /// 步数口径与 maxSteps 同单位（LLM 循环步，非工具调用数）。
  final AgentRoundProgress? agentRoundProgress;

  /// 是否已从写作任务（任务一）切换至周期审查与维护阶段（任务二）。
  final bool inMaintenancePhase;

  /// 任务二启动时已累计的 [agentSteps] 起始下标（用于隔离任务一与任务二步骤展示）。
  final int maintenanceStepStart;

  /// 溢出自愈发生计数（单调递增，页面 ref.listen 消费弹 toast）
  final int overflowHealedTick;

  /// ask_user 超时裁决计数（页面监听弹 toast）
  final int hitlAskTimeoutTick;

  /// 审批超时裁决计数（页面监听弹 toast）
  final int hitlApprovalTimeoutTick;

  /// 变体切换被拒提示计数（页面监听弹 toast，原因见
  /// [variantSwitchBlockedReason]）
  final int variantSwitchBlockedTick;

  /// 最近一次变体切换被拒的原因（downstream=存在后续轮，compacted=
  /// 已压缩区域）；null=无被拒记录
  final String? variantSwitchBlockedReason;

  /// One state emission when a committed round has individual fact failures.
  final ({int turnNumber, int count})? factWriteWarning;

  /// 单槽待发消息（生成中排队；轮正常结束后自动发送一次）
  ///
  /// null = 无排队。排队文本同时落会话草稿列（重启/离开页面后回到
  /// 输入框，绝不自动发送）；撤回时退还输入框可编辑。单槽：再次排队
  /// 需先确认覆盖。失败/停止轮不清空（clearTemporary 不含本字段）。
  final String? queuedMessage;

  /// 工程上下文模式（导演实验）三态解析结果（loadHistory 对账后写入）
  final EngineeringRuntimeMode engineeringMode;

  /// 需要修复态的原因码（诊断/展示用；其余态为 null）
  final String? engineeringModeReason;

  /// 最近一次主请求的数字与异常标识（必须整组取自同一样本）。
  ///
  /// 最新轮摘要带完整输入时整组取摘要；否则整组取事件日志回填。
  /// 不允许「数字取回填、异常只校验摘要」的拼接——那会把旧冲突样本
  /// 重新算成精确比例。
  ({
    int? inputTokens,
    int? promptTokens,
    int? completionTokens,
    int? cacheReadTokens,
    List<String> warnings
  })? get latestMainRequestUsage {
    final summary = latestHistoryTurnSummary;
    final reported = summary?.lastInputTokens;
    if (summary != null && reported != null && reported > 0) {
      return (
        inputTokens: reported,
        promptTokens: summary.lastPromptTokens,
        completionTokens: summary.lastCompletionTokens,
        cacheReadTokens: summary.lastCacheReadTokens,
        warnings: summary.usageWarnings,
      );
    }
    final backfilledInput = backfilledTotalInputTokens;
    if (backfilledInput != null && backfilledInput > 0) {
      return (
        inputTokens: backfilledInput,
        promptTokens: backfilledPromptTokens,
        completionTokens: null,
        cacheReadTokens: backfilledCacheReadTokens,
        warnings: backfilledUsageWarnings ?? const [],
      );
    }
    final backfilledPrompt = backfilledPromptTokens;
    if (backfilledPrompt != null && backfilledPrompt > 0) {
      // 旧日志只有协议原生 prompt：只作展示，不当完整输入分母
      return (
        inputTokens: null,
        promptTokens: backfilledPrompt,
        completionTokens: null,
        cacheReadTokens: backfilledCacheReadTokens,
        warnings: backfilledUsageWarnings ?? const [],
      );
    }
    return null;
  }

  /// 最近一次主请求的完整输入（命中率分母/「最近请求」区）
  ///
  /// 单一取值策略：控制器与页面共用本 getter。
  /// 只认最新一轮的实报；最新轮缺失时用同轮事件日志回填值，仍缺失返回
  /// null。不跨早期轮次回扫——早轮输入属于另一材料修订，不能冒充当前锚点。
  int? get latestMainRequestInputTokens => latestMainRequestUsage?.inputTokens;

  /// 最近一次主请求的 cache 命中读分项（与 [latestMainRequestInputTokens]
  /// 同源：整组摘要或整组回填）
  int? get latestMainRequestCacheReadTokens =>
      latestMainRequestUsage?.cacheReadTokens;

  /// 最近一次主请求的计量异常（与数字同源）
  List<String> get latestMainRequestUsageWarnings =>
      latestMainRequestUsage?.warnings ?? const [];

  /// 最近一次主请求的已校验命中率（异常/非法 → null）
  double? get latestMainRequestCacheHitRatio {
    final sample = latestMainRequestUsage;
    if (sample == null || sample.warnings.isNotEmpty) return null;
    return LlmUsage.hitRateOf(
      cacheReadTokens: sample.cacheReadTokens,
      inputTokens: sample.inputTokens,
    );
  }

  /// 最近一次主请求分项是否不可比较（异常或合法范围外）
  bool get latestMainRequestCacheSampleInvalid {
    final sample = latestMainRequestUsage;
    if (sample == null) return false;
    if (sample.warnings.isNotEmpty) return true;
    return sample.cacheReadTokens != null &&
        sample.inputTokens != null &&
        latestMainRequestCacheHitRatio == null;
  }

  /// 上下文构成分段字符数（null=未装配/旧状态）
  ///
  /// 轮装配期由 runner 埋点（系统提示词/场记板/历史对话/本轮指令四段）；
  /// 详情面板把最近一次请求的 promptTokens 按字符占比拆分到各段——
  /// 真实分段 token 供应商接口不提供，占比为估算口径（面板有标注）。
  final Map<String, int>? contextSegmentChars;

  /// 会话历史加载中（loadHistory 开始置位、finally 清除）
  ///
  /// body 在 loading 且内容为空时渲染骨架占位而非空态引导——重会话
  /// 打开瞬间不再闪「发送第一句话开始」。
  final bool loadingHistory;

  /// 各轮稿件变体快照（loadHistory 装载，key=turnNumber）
  ///
  /// null/空 = 无变体（单版本轮不进表）。当前指针在
  /// `artifactsByTurnNumber[turn]`.currentVariantIndex。
  final Map<int, List<MessageVariantRecord>>? variantsByTurn;

  /// 新变体刚收稿的轮次（切换器高亮 2s 的信号，UI 消费后清除）
  final int? variantFlashTurn;

  /// 新变体收稿时刻——高亮 2s 从收稿
  /// 起表而非行物化起表：视口外收稿/延迟滚到该轮时只闪剩余时长，
  /// 不再与收稿时刻脱钩（可晚数分钟）。
  final int? variantFlashStartedAtMs;

  /// 导演模式：本轮轮时间线（对话流计划 §4，2026-08-28）
  ///
  /// collectRound 收稿时由 AgentTimelineAssembler 装配（思考/播报/动作
  /// 交错），persist 随 artifacts 双写；live 态 UI 由 liveBlocks+agentSteps
  /// 现算，本字段在收稿后供"定稿时间线"渲染。清空时机与 agentSteps 一致。
  final List<AgentTimelineBlock> agentTimeline;

  /// 导演模式：本轮工作摘要（收拢为一行，结束后保留至下轮）
  final AgentWorkSummary? agentWorkSummary;

  /// 导演模式：本轮剧情锚（update_story_anchor 更新后的值；live 幕间
  /// Recap 卡的数据源，persist 时快照到 artifacts 并更新会话当前锚）
  final StoryAnchor? agentStoryAnchor;

  /// 导演模式：待回答的导演问题（ask_user 横幅；null = 无待答问题）
  final AgentAskPrompt? agentAskPrompt;

  /// 导演模式：待确认的工具写入（监督模式审批横幅；null = 无待确认）
  final AgentApprovalPrompt? agentApprovalPrompt;

  /// 解析后的上下文窗口 token（null = 尚未解析）
  final int? contextWindowTokens;

  /// 压缩触发线 token（环形指示器满刻度），与 shouldCompact 同公式同值
  final int? compactionTriggerTokens;

  /// 旧会话回填的最新 promptTokens（§3.2；新轮 persist 后清空）
  final int? backfilledPromptTokens;

  /// 旧会话回填的最新 cache 命中读 token（新轮 persist 后清空）
  final int? backfilledCacheReadTokens;

  /// 旧会话回填的完整输入 token（旧日志缺键为 null → 不参与命中率累计）
  final int? backfilledTotalInputTokens;

  /// 与回填数字同源的末次请求计量异常（null = 旧日志未记录）
  final List<String>? backfilledUsageWarnings;

  /// 当前预计上下文（主数字；压缩等本地材料变更后即时调整）
  final ContextUsageEstimate? contextEstimate;

  /// 手动压缩进行中（§4.3；输入区发送/重生成入口据此拒绝）
  final bool isManualCompacting;

  /// 手动压缩摘要流式增量（面板实时打字）
  final String manualCompactionDelta;

  /// 手动压缩失败信息（非 null = 失败态，面板显示重试）
  final String? manualCompactionError;

  /// Sentinel 区分"未提供"与"显式 null"
  static const _sentinel = Object();

  /// 创建副本并应用修改
  AdvancedChatState copyWith({
    IntermediatePhase? phase,
    List<ChatMessage>? messages,
    List<AgentLiveBlock>? liveBlocks,
    AgentActivity? agentActivity,
    int? agentActivityStepIndex,
    Object? failureContext = _sentinel,
    Map<IntermediatePhase, int>? retryCounts,
    ChatSession? session,
    Object? userInput = _sentinel,
    Object? regenerateTurnNumber = _sentinel,
    Object? artifactsByTurnNumber = _sentinel,
    Object? usageSummariesByTurn = _sentinel,
    int? compactedTurnBase,
    Object? pendingUserMessage = _sentinel,
    bool? isPreparingRegenerate,
    bool? embeddingDegradedForRound,
    bool? isStopping,
    // 推荐回复字段
    List<String>? suggestReplies,
    bool? isGeneratingSuggest,
    bool? suggestExpanded,
    Object? suggestFailure = _sentinel,
    List<AgentWorkStep>? agentSteps,
    List<AgentTimelineBlock>? agentTimeline,
    Object? agentWorkSummary = _sentinel,
    Object? agentStoryAnchor = _sentinel,
    Object? agentRetryWait = _sentinel,
    Object? agentRoundProgress = _sentinel,
    bool? inMaintenancePhase,
    int? maintenanceStepStart,
    int? overflowHealedTick,
    int? variantSwitchBlockedTick,
    String? variantSwitchBlockedReason,
    ({int turnNumber, int count})? factWriteWarning,
    Object? queuedMessage = _sentinel,
    EngineeringRuntimeMode? engineeringMode,
    Object? engineeringModeReason = _sentinel,
    int? hitlAskTimeoutTick,
    int? hitlApprovalTimeoutTick,
    Object? contextSegmentChars = _sentinel,
    bool? loadingHistory,
    Object? variantsByTurn = _sentinel,
    Object? variantFlashTurn = _sentinel,
    Object? variantFlashStartedAtMs = _sentinel,
    Object? agentAskPrompt = _sentinel,
    Object? agentApprovalPrompt = _sentinel,
    Object? contextWindowTokens = _sentinel,
    Object? compactionTriggerTokens = _sentinel,
    Object? backfilledPromptTokens = _sentinel,
    Object? backfilledCacheReadTokens = _sentinel,
    Object? backfilledTotalInputTokens = _sentinel,
    Object? backfilledUsageWarnings = _sentinel,
    Object? contextEstimate = _sentinel,
    // 手动压缩三字段必须全部 sentinel 化——流式回调只传 delta
    // 不传标志，默认值会把 isManualCompacting 打回 false，互斥守卫失效。
    Object? isManualCompacting = _sentinel,
    Object? manualCompactionDelta = _sentinel,
    Object? manualCompactionError = _sentinel,
    bool clearAgentSteps = false,
  }) {
    return AdvancedChatState(
      phase: phase ?? this.phase,
      messages: messages ?? this.messages,
      liveBlocks: liveBlocks ?? this.liveBlocks,
      agentActivity: agentActivity ?? this.agentActivity,
      agentActivityStepIndex:
          agentActivityStepIndex ?? this.agentActivityStepIndex,
      failureContext: identical(failureContext, _sentinel)
          ? this.failureContext
          : failureContext as FailureContext?,
      retryCounts: retryCounts ?? this.retryCounts,
      session: session ?? this.session,
      userInput: identical(userInput, _sentinel)
          ? this.userInput
          : userInput as String?,
      regenerateTurnNumber: identical(regenerateTurnNumber, _sentinel)
          ? this.regenerateTurnNumber
          : regenerateTurnNumber as int?,
      artifactsByTurnNumber: identical(artifactsByTurnNumber, _sentinel)
          ? this.artifactsByTurnNumber
          : artifactsByTurnNumber as Map<int, StoryRoundArtifacts>?,
      usageSummariesByTurn: identical(usageSummariesByTurn, _sentinel)
          ? this.usageSummariesByTurn
          : usageSummariesByTurn as Map<int, AgentWorkSummary?>?,
      compactedTurnBase: compactedTurnBase ?? this.compactedTurnBase,
      pendingUserMessage: identical(pendingUserMessage, _sentinel)
          ? this.pendingUserMessage
          : pendingUserMessage as ChatMessage?,
      isPreparingRegenerate:
          isPreparingRegenerate ?? this.isPreparingRegenerate,
      embeddingDegradedForRound:
          embeddingDegradedForRound ?? this.embeddingDegradedForRound,
      isStopping: isStopping ?? this.isStopping,
      suggestReplies: suggestReplies ?? this.suggestReplies,
      isGeneratingSuggest: isGeneratingSuggest ?? this.isGeneratingSuggest,
      suggestExpanded: suggestExpanded ?? this.suggestExpanded,
      suggestFailure: identical(suggestFailure, _sentinel)
          ? this.suggestFailure
          : suggestFailure as AuxiliaryGenerationFailure?,
      agentSteps: clearAgentSteps ? const [] : (agentSteps ?? this.agentSteps),
      // clearAgentSteps 同步清空时间线（两者生命周期一致）
      agentTimeline:
          clearAgentSteps ? const [] : (agentTimeline ?? this.agentTimeline),
      agentWorkSummary: identical(agentWorkSummary, _sentinel)
          ? this.agentWorkSummary
          : agentWorkSummary as AgentWorkSummary?,
      agentStoryAnchor: identical(agentStoryAnchor, _sentinel)
          ? this.agentStoryAnchor
          : agentStoryAnchor as StoryAnchor?,
      agentRetryWait: identical(agentRetryWait, _sentinel)
          ? this.agentRetryWait
          : agentRetryWait as AgentRetryWait?,
      agentRoundProgress: identical(agentRoundProgress, _sentinel)
          ? this.agentRoundProgress
          : agentRoundProgress as AgentRoundProgress?,
      inMaintenancePhase:
          inMaintenancePhase ?? (!clearAgentSteps && this.inMaintenancePhase),
      maintenanceStepStart: maintenanceStepStart ??
          (clearAgentSteps ? 0 : this.maintenanceStepStart),
      overflowHealedTick: overflowHealedTick ?? this.overflowHealedTick,
      variantSwitchBlockedTick:
          variantSwitchBlockedTick ?? this.variantSwitchBlockedTick,
      variantSwitchBlockedReason: variantSwitchBlockedReason,
      factWriteWarning: factWriteWarning,
      queuedMessage: identical(queuedMessage, _sentinel)
          ? this.queuedMessage
          : queuedMessage as String?,
      engineeringMode: engineeringMode ?? this.engineeringMode,
      engineeringModeReason: identical(engineeringModeReason, _sentinel)
          ? this.engineeringModeReason
          : engineeringModeReason as String?,
      hitlAskTimeoutTick: hitlAskTimeoutTick ?? this.hitlAskTimeoutTick,
      hitlApprovalTimeoutTick:
          hitlApprovalTimeoutTick ?? this.hitlApprovalTimeoutTick,
      contextSegmentChars: identical(contextSegmentChars, _sentinel)
          ? this.contextSegmentChars
          : contextSegmentChars as Map<String, int>?,
      loadingHistory: loadingHistory ?? this.loadingHistory,
      variantsByTurn: identical(variantsByTurn, _sentinel)
          ? this.variantsByTurn
          : variantsByTurn as Map<int, List<MessageVariantRecord>>?,
      variantFlashTurn: identical(variantFlashTurn, _sentinel)
          ? this.variantFlashTurn
          : variantFlashTurn as int?,
      variantFlashStartedAtMs: identical(variantFlashStartedAtMs, _sentinel)
          ? this.variantFlashStartedAtMs
          : variantFlashStartedAtMs as int?,
      agentAskPrompt: identical(agentAskPrompt, _sentinel)
          ? this.agentAskPrompt
          : agentAskPrompt as AgentAskPrompt?,
      agentApprovalPrompt: identical(agentApprovalPrompt, _sentinel)
          ? this.agentApprovalPrompt
          : agentApprovalPrompt as AgentApprovalPrompt?,
      contextWindowTokens: identical(contextWindowTokens, _sentinel)
          ? this.contextWindowTokens
          : contextWindowTokens as int?,
      compactionTriggerTokens: identical(compactionTriggerTokens, _sentinel)
          ? this.compactionTriggerTokens
          : compactionTriggerTokens as int?,
      backfilledPromptTokens: identical(backfilledPromptTokens, _sentinel)
          ? this.backfilledPromptTokens
          : backfilledPromptTokens as int?,
      backfilledCacheReadTokens: identical(backfilledCacheReadTokens, _sentinel)
          ? this.backfilledCacheReadTokens
          : backfilledCacheReadTokens as int?,
      backfilledTotalInputTokens:
          identical(backfilledTotalInputTokens, _sentinel)
              ? this.backfilledTotalInputTokens
              : backfilledTotalInputTokens as int?,
      backfilledUsageWarnings: identical(backfilledUsageWarnings, _sentinel)
          ? this.backfilledUsageWarnings
          : backfilledUsageWarnings as List<String>?,
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
    );
  }

  /// 清理本轮临时产物（重试/清空/取消时用），保留 messages 和 userInput
  ///
  /// 同时清空 retryCounts——手动重试/取消后从新一轮开始，重试计数归零。
  /// **不清空** [artifactsByTurnNumber]——历史轮次产物不属临时状态。
  AdvancedChatState clearTemporary() {
    return copyWith(
      phase: IntermediatePhase.idle,
      liveBlocks: const [],
      failureContext: null,
      // 显式置 null，结束"重新生成"流程标识
      regenerateTurnNumber: null,
      retryCounts: {},
      // 准备中标识归位（正常流程在 controller 截断 state 时已置 false，
      // 此处兜底防止异常路径残留导致 UI 永久遮罩）
      isPreparingRegenerate: false,
      // 临时降级标识归位（避免下一轮误判为降级模式）
      embeddingDegradedForRound: false,
      // 未完成轮的步骤属临时状态——取消后不清会在时间线留孤儿
      // 汇总行（无用户气泡对应），首轮取消还会挤掉空态引导
      clearAgentSteps: true,
      // 等待中的重试状态同属临时态，取消后不得残留
      agentRetryWait: null,
      // 预算进度快照随轮清理
      agentRoundProgress: null,
      inMaintenancePhase: false,
      maintenanceStepStart: 0,
    );
  }
}

/// 请求重试等待快照
///
/// agent_runner 在退避/Retry-After 等待开始时经 AgentRetryScheduled 事件
/// 送达；UI 倒计时以 [scheduledAtMs]（事件到达时刻）为锚计算剩余，不各自
/// 起表（防客户端时钟偏差）。
class AgentRetryWait {
  const AgentRetryWait({
    required this.waitMs,
    required this.attempt,
    required this.scheduledAtMs,
    this.maxAttempts,
    this.cause,
  });

  /// 总等待毫秒数
  final int waitMs;

  /// 等待结束后将开始的尝试序号（1 起）
  final int attempt;

  /// 事件到达时刻（ms epoch；倒计时锚点）
  final int scheduledAtMs;

  /// 重试总预算（批 F：k/N 进度显示；null = 未知/旧值）
  final int? maxAttempts;

  /// 归一语义码（UI 层映射人话原因；null = 未知）
  final String? cause;

  /// 按 [nowMs] 计算的剩余毫秒（下限 0）
  int remainingMs(int nowMs) {
    final remaining = waitMs - (nowMs - scheduledAtMs);
    return remaining < 0 ? 0 : remaining;
  }
}

/// 轮中预算进度快照
///
/// 轮开始时由 runner 快照进 state（[AdvancedChatState.agentRoundProgress]），
/// live work group 标题行据此渲染「第 N/M 步 · 已用 X:XX · 正在…」；数据
/// 全部来自 runner 既有计数，不新增通信通道。
class AgentRoundProgress {
  const AgentRoundProgress({
    required this.currentStep,
    required this.maxSteps,
    required this.startedAtMs,
  });

  /// 当前 LLM 循环步号（1 起；与 maxSteps 同单位，非工具调用数）
  final int currentStep;

  /// 每轮最大步数（0 = 无上限；与 AgentBudget.maxSteps 同语义）
  final int maxSteps;

  /// 轮开始时刻（ms epoch；用时Ticker 的锚点）
  final int startedAtMs;

  /// 预算占用比例（0.0–1.0+；无上限时恒 0）
  double get budgetRatio => maxSteps <= 0 ? 0 : currentStep / maxSteps;

  AgentRoundProgress copyWith({int? currentStep, int? maxSteps}) =>
      AgentRoundProgress(
        currentStep: currentStep ?? this.currentStep,
        maxSteps: maxSteps ?? this.maxSteps,
        startedAtMs: startedAtMs,
      );
}
