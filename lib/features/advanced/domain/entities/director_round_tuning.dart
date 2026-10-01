import 'package:lmstory/core/config/advanced_config.dart';
import 'package:lmstory/features/advanced/domain/entities/narrative_pacing.dart';

/// 导演轮运行旋钮（预算/HITL/doom-loop/子代理），控制器每轮从 [AdvancedConfig]
/// 组装传入 runner——这些不是 story_runtime 共享关注点，不进 RoundContext。
///
/// 键表：advanced.budget / doom_loop / hitl / subagent（设计文档 §4）。
/// askUserTimeout 默认 3 分钟（原硬编码 10 分钟，全计划唯一默认行为变更，
/// 用户 ，可配回）；**0 = 永不超时**（对齐 maxSteps
/// 0=无上限语义）——[askUserTimeout] 为 null 表示一直等待导演回答。
/// 审批超时保持 fail-closed（0 不开放，安全默认不变）。
class DirectorRoundTuning {
  const DirectorRoundTuning({
    required this.defaultMaxSteps,
    required this.maxDurationMinutes,
    required this.tokenBudgetRatio,
    required this.maxRequestRetries,
    required this.doomLoopThreshold,
    required this.askUserTimeout,
    required this.approvalTimeout,
    required this.subagentMaxSteps,
    required this.subagentMaxDuration,
    required this.subagentTokenBudgetRatio,
    this.globalTools = const {},
    this.globalPacing = NarrativePacing.balanced,
    this.toolOutputLimit = 20000,
    this.toolTimeout = const Duration(seconds: 120),
    this.coreBlocksInTail = false,
    this.fullChunkEvents = false,
    this.foreshadowCheckInterval = 8,
    this.eventLogRetentionTurns = 20,
  });

  factory DirectorRoundTuning.fromConfig(AdvancedConfig c) =>
      DirectorRoundTuning(
        defaultMaxSteps: c.defaults.maxSteps,
        maxDurationMinutes: c.budget.maxDurationMinutes,
        tokenBudgetRatio: c.budget.tokenBudgetRatio,
        maxRequestRetries: c.budget.maxRequestRetries,
        doomLoopThreshold: c.doomLoop.threshold,
        // ask_user_timeout_minutes=0 → 永不超时（null）
        askUserTimeout: c.hitl.askUserTimeoutMinutes <= 0
            ? null
            : Duration(minutes: c.hitl.askUserTimeoutMinutes),
        // approval_timeout=0 会物化 Duration.zero →
        // 审批 completer.future.timeout(0) 立即超时，fail-closed 每次秒拒
        // 且横幅闪没。设置 UI 已挡 0（fail-closed 不开放），此处对手编/
        // 导入的坏值钳回默认 5 分钟；0 的「合法立即拒」语义如需开放应
        // 显式设计而非副作用。
        approvalTimeout: c.hitl.approvalTimeoutMinutes <= 0
            ? const Duration(minutes: 5)
            : Duration(minutes: c.hitl.approvalTimeoutMinutes),
        subagentMaxSteps: c.subagent.maxSteps,
        subagentMaxDuration: Duration(minutes: c.subagent.maxDurationMinutes),
        subagentTokenBudgetRatio: c.subagent.tokenBudgetRatio,
        globalTools: c.tools,
        globalPacing: NarrativePacing.fromConfigValue(c.narrativePacing),
        toolOutputLimit: c.harness.toolOutputLimit,
        toolTimeout: c.harness.toolTimeoutSeconds <= 0
            ? null
            : Duration(seconds: c.harness.toolTimeoutSeconds),
        coreBlocksInTail: c.harness.coreBlocksInTail,
        fullChunkEvents: c.harness.fullChunkEvents,
        foreshadowCheckInterval: c.harness.foreshadowCheckInterval,
        eventLogRetentionTurns: c.harness.eventLogRetentionTurns,
      );

  /// 会话 maxSteps 列 NULL 时的回退默认（advanced.defaults.max_steps）
  final int defaultMaxSteps;
  final int maxDurationMinutes;
  final double tokenBudgetRatio;
  final int maxRequestRetries;
  final int doomLoopThreshold;

  /// ask_user 挂起超时（null = 永不超时，「一直等待」档）
  final Duration? askUserTimeout;
  final Duration approvalTimeout;
  final int subagentMaxSteps;
  final Duration subagentMaxDuration;

  /// 子代理 token 上限比例（主轮 contextWindow × 此值；
  /// 0 = 不限制）
  final double subagentTokenBudgetRatio;

  /// 全局工具权限覆盖（advanced.tools；空 map = 全 allow 内置默认）
  final Map<String, String> globalTools;

  /// 全局剧情节奏档（advanced.narrative_pacing；会话列 narrative_pacing
  /// 非 NULL 时在 runner 消费点覆盖——剧情节奏档位设计 §4.1）
  final NarrativePacing globalPacing;

  /// 工具输出字符预算（advanced.harness.tool_output_limit）
  final int toolOutputLimit;

  /// 单工具执行超时（advanced.harness.tool_timeout_seconds，0=禁用）
  final Duration? toolTimeout;

  ///  实验：coreBlocks 挪尾（advanced.harness.core_blocks_in_tail）
  final bool coreBlocksInTail;

  /// 流式正文分片全量落盘（：advanced.harness.full_chunk_events，
  /// 默认关；最小粒度聚合档恒开）
  final bool fullChunkEvents;

  /// 伏笔定期清点间隔轮数（advanced.harness.foreshadow_check_interval，
  /// 默认 8；0 = 停用）。清点轮：轮尾注入未兑现清单提醒 + finish_round
  /// 伏笔对账闸门拦截一次——两处共用同一节奏源（isForeshadowSweepRound）。
  final int foreshadowCheckInterval;

  /// 事件日志滚动保留轮数（批 I；0=不限制）
  final int eventLogRetentionTurns;
}
