import 'package:lmstory/core/config/advanced_config.dart';
import 'package:lmstory/core/config/network_config.dart';
import 'package:lmstory/features/advanced/domain/entities/narrative_pacing.dart';

/// 导演轮运行旋钮（预算/HITL/doom-loop/子代理），控制器每轮从 [AdvancedConfig]
/// 组装传入 runner——这些不是 story_runtime 共享关注点，不进 RoundContext。
///
/// 键表：advanced.budget / doom_loop / hitl / subagent（设计文档 §4）。
/// askUserTimeout 默认 3 分钟（原硬编码 10 分钟，全计划唯一默认行为变更，
/// 用户 ，可配回）；**0 = 永不超时**（对齐 maxSteps
/// 0=无上限语义）——[askUserTimeout] 为 null 表示一直等待导演回答。
/// 审批超时 2026-10-15 P2 ：[approvalTimeoutEnabled] 关闭时两类 HITL
/// 横幅（审批 + ask_user）均永不超时（[approvalTimeout]/[askUserTimeout]
/// 为 null）；开启时保持 fail-closed（审批 0 值钳制见
/// [AdvancedHitlConfig.effectiveApprovalTimeout]，两侧共用同一真源，
/// 修 ）。
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
    required this.approvalTimeoutEnabled,
    this.responseStartTimeout = const Duration(minutes: 10),
    this.nonStreamingTimeout = const Duration(minutes: 10),
    this.globalTools = const {},
    this.globalPacing = NarrativePacing.balanced,
    this.toolOutputLimit = 20000,
    this.toolTimeout = const Duration(seconds: 120),
    this.coreBlocksInTail = true,
    this.fullChunkEvents = false,
    this.foreshadowCheckInterval = 8,
    this.eventLogRetentionTurns = 20,
    this.maintenanceGapInterval = 7,
    this.maintenanceNudgeCooldown = 4,
    this.majorReviewInterval = 50,
    this.maintenanceExtraSteps = 6,
    this.recentActiveEntitiesWindow = 15,
    this.recentActiveEntitiesCap = 10,
  });

  factory DirectorRoundTuning.fromConfig(
    AdvancedConfig c, {
    NetworkConfig network = const NetworkConfig(),
  }) =>
      DirectorRoundTuning(
        responseStartTimeout:
            Duration(milliseconds: network.directorResponseStartTimeoutMs),
        nonStreamingTimeout:
            Duration(milliseconds: network.directorNonStreamingTimeoutMs),
        defaultMaxSteps: c.defaults.maxSteps,
        maxDurationMinutes: c.budget.maxDurationMinutes,
        tokenBudgetRatio: c.budget.tokenBudgetRatio,
        maxRequestRetries: c.budget.maxRequestRetries,
        doomLoopThreshold: c.doomLoop.threshold,
        // P2 开关同盖：关闭时提问横幅也永不超时；0 = 永不超时（既有语义）
        askUserTimeout: c.hitl.effectiveAskUserTimeout,
        // P2 ：开关关闭 → null（runner 不挂 .timeout，永不 fail-closed）；
        // 开启时 0 值钳回默认 5（Duration.zero 会让 completer 立即秒拒且
        // 横幅闪没）——钳制真源在 AdvancedHitlConfig.effectiveApprovalTimeout，
        // 页面倒计时与 runner 同源（修 ）。
        approvalTimeout: c.hitl.effectiveApprovalTimeout,
        subagentMaxSteps: c.subagent.maxSteps,
        subagentMaxDuration: Duration(minutes: c.subagent.maxDurationMinutes),
        subagentTokenBudgetRatio: c.subagent.tokenBudgetRatio,
        approvalTimeoutEnabled: c.hitl.approvalTimeoutEnabled,
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
        maintenanceGapInterval: c.harness.maintenanceGapInterval,
        maintenanceNudgeCooldown: c.harness.maintenanceNudgeCooldown,
        majorReviewInterval: c.harness.majorReviewInterval,
        maintenanceExtraSteps: c.harness.maintenanceExtraSteps,
        recentActiveEntitiesWindow: c.harness.recentActiveEntitiesWindow,
        recentActiveEntitiesCap: c.harness.recentActiveEntitiesCap,
      );

  DirectorRoundTuning withNetwork(NetworkConfig network) => DirectorRoundTuning(
        defaultMaxSteps: defaultMaxSteps,
        maxDurationMinutes: maxDurationMinutes,
        tokenBudgetRatio: tokenBudgetRatio,
        maxRequestRetries: maxRequestRetries,
        doomLoopThreshold: doomLoopThreshold,
        askUserTimeout: askUserTimeout,
        approvalTimeout: approvalTimeout,
        subagentMaxSteps: subagentMaxSteps,
        subagentMaxDuration: subagentMaxDuration,
        subagentTokenBudgetRatio: subagentTokenBudgetRatio,
        approvalTimeoutEnabled: approvalTimeoutEnabled,
        responseStartTimeout:
            Duration(milliseconds: network.directorResponseStartTimeoutMs),
        nonStreamingTimeout:
            Duration(milliseconds: network.directorNonStreamingTimeoutMs),
        globalTools: globalTools,
        globalPacing: globalPacing,
        toolOutputLimit: toolOutputLimit,
        toolTimeout: toolTimeout,
        coreBlocksInTail: coreBlocksInTail,
        fullChunkEvents: fullChunkEvents,
        foreshadowCheckInterval: foreshadowCheckInterval,
        eventLogRetentionTurns: eventLogRetentionTurns,
        maintenanceGapInterval: maintenanceGapInterval,
        maintenanceNudgeCooldown: maintenanceNudgeCooldown,
        majorReviewInterval: majorReviewInterval,
        maintenanceExtraSteps: maintenanceExtraSteps,
        recentActiveEntitiesWindow: recentActiveEntitiesWindow,
        recentActiveEntitiesCap: recentActiveEntitiesCap,
      );

  /// 会话 maxSteps 列 NULL 时的回退默认（advanced.defaults.max_steps）
  final Duration responseStartTimeout;
  final Duration nonStreamingTimeout;
  final int defaultMaxSteps;
  final int maxDurationMinutes;
  final double tokenBudgetRatio;
  final int maxRequestRetries;
  final int doomLoopThreshold;

  /// ask_user 挂起超时（null = 永不超时，「一直等待」档；P2 开关同盖）
  final Duration? askUserTimeout;

  /// 审批挂起超时（null = 永不超时，P2 开关关闭时；开启时 fail-closed
  /// 必有超时——0 值已由 effectiveApprovalTimeout 钳回默认）
  final Duration? approvalTimeout;

  /// 确认超时自动拒绝开关（P2；页面倒计时显隐与设置文案用）
  final bool approvalTimeoutEnabled;
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

  /// coreBlocks 挪尾（advanced.harness.core_blocks_in_tail，默认 true）
  final bool coreBlocksInTail;

  /// 流式正文分片全量落盘（：advanced.harness.full_chunk_events，
  /// 默认关；最小粒度聚合档恒开）
  final bool fullChunkEvents;

  /// 伏笔定期清点间隔轮数（兼容保留；0 = 停用）。
  final int foreshadowCheckInterval;

  /// 事件日志滚动保留轮数（批 I；0=不限制）
  final int eventLogRetentionTurns;

  /// 轻量维护缺口提示触发间隔（轮数；0 = 停用）
  final int maintenanceGapInterval;

  /// 轻量维护缺口提示冷却轮数
  final int maintenanceNudgeCooldown;

  /// 周期全面审查与维护大周期触发间隔（轮数；0 = 停用）
  final int majorReviewInterval;

  /// 大周期进入维护阶段时额外追加的步数预算
  final int maintenanceExtraSteps;

  /// 近期活跃非核心动态实体的回看轮次窗口
  final int recentActiveEntitiesWindow;

  /// 近期活跃非核心动态实体在 Core Blocks 中的最多展示条数
  final int recentActiveEntitiesCap;
}
