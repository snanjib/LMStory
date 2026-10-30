import 'package:lmstory/core/agent/agent_budget.dart';
import 'package:lmstory/core/agent/agent_message.dart';

/// 轮停止原因
enum AgentStopReason {
  /// 模型输出最终回复
  completed,

  /// 控制类工具（finish_round）终结轮次
  completedByTool,

  /// 步数预算耗尽（maxSteps）
  maxSteps,

  /// token 累计消耗达成本预算上限（语义：成本口径）
  budgetTokens,

  /// 上下文余量越限（：最近请求 promptTokens ≥ 窗口×0.85 触发线）
  contextHeadroom,

  /// 时间预算耗尽
  budgetDuration,

  /// doom-loop 保护触发（连续同参工具调用）
  doomLoop,

  /// 用户取消
  cancelled,

  /// pre-step 钩子拒绝
  hookRejected,

  /// 请求错误且重试耗尽 / 未捕获异常
  error,
}

/// 单个 step 的结束形态
enum AgentStepStopKind {
  /// 模型输出文本回复（无工具调用）
  textReply,

  /// 模型发起工具调用
  toolCalls,

  /// 无内容（异常流，防御性记录）
  empty,
}

/// Agent 运行实时事件（live 广播； 另有持久事件日志信封）
///
/// 事件流驱动 UI（过程卡/时间线）——把 `message.part.*` 式事件流
/// 渲染成时间线是 harness 标配（设计报告 §3.5）。
sealed class AgentRunEvent {
  AgentRunEvent({DateTime? at}) : at = at ?? DateTime.now();

  final DateTime at;
}

/// 轮开始
class AgentTurnStarted extends AgentRunEvent {
  AgentTurnStarted({required this.maxSteps, this.resumed = false, super.at});

  final int maxSteps;

  /// 是否为失败后续跑（携带续跑种子）；durable 层落 turn/begin 标记用
  final bool resumed;
}

/// step 开始（一次模型请求）
class AgentStepStarted extends AgentRunEvent {
  AgentStepStarted({required this.stepIndex, this.attempt = 0, super.at});

  final int stepIndex;

  /// 同一 step 的第几次尝试（request-error 重试时递增；0 = 首次尝试。
  /// 正文交付契约 §7.1：attempt>0 时消费方应清除该 step 的半截直播块）
  final int attempt;
}

/// 请求错误重试已排定（退避/Retry-After 等待开始； 可视化）
///
/// 在等待开始前发出；等待结束后的 [AgentStepStarted]（attempt 递增）
/// 标志等待结束。UI 倒计时以本事件到达时刻为锚（防时钟偏差）。
class AgentRetryScheduled extends AgentRunEvent {
  AgentRetryScheduled({
    required this.waitMs,
    required this.attempt,
    this.maxAttempts,
    this.cause,
    super.at,
  });

  /// 距重试的等待毫秒数（Retry-After 优先 / 指数退避 ± jitter）
  final int waitMs;

  /// 等待结束后将开始的尝试序号（与 AgentStepStarted.attempt 对齐）
  final int attempt;

  /// 重试总预算（2026-10-15 批 F：让用户知道还要等多久；null = 未知/旧值）
  final int? maxAttempts;

  /// 归一语义码（人话原因由 UI 层经 RetryWaitReason 映射；null = 未知）
  final String? cause;
}

/// 正文文本增量
class AgentTextDeltaEvent extends AgentRunEvent {
  AgentTextDeltaEvent({required this.stepIndex, required this.delta, super.at});

  final int stepIndex;
  final String delta;
}

/// 思考内容增量
class AgentThinkingDeltaEvent extends AgentRunEvent {
  AgentThinkingDeltaEvent({
    required this.stepIndex,
    required this.delta,
    super.at,
  });

  final int stepIndex;
  final String delta;
}

/// 模型发起了工具调用（协议解析完成）
class AgentToolCallReceived extends AgentRunEvent {
  AgentToolCallReceived({
    required this.stepIndex,
    required this.call,
    super.at,
  });

  final int stepIndex;
  final AgentToolCall call;
}

/// assistant 消息已入 surface（持久化 sink 据此写 assistant/message 事件）
class AgentAssistantMessageEvent extends AgentRunEvent {
  AgentAssistantMessageEvent({
    required this.stepIndex,
    required this.message,
    super.at,
  });

  final int stepIndex;
  final AgentMessage message;
}

/// 工具开始执行
class AgentToolExecutionStarted extends AgentRunEvent {
  AgentToolExecutionStarted({
    required this.callId,
    required this.toolName,
    required this.argsPreview,
    super.at,
  });

  final String callId;
  final String toolName;
  final String argsPreview;
}

/// 工具执行结束（含被拒绝/失败/占位补齐）
class AgentToolExecutionFinished extends AgentRunEvent {
  AgentToolExecutionFinished({
    required this.callId,
    required this.toolName,
    required this.title,
    required this.output,
    required this.isError,
    required this.duration,
    this.synthetic = false,
    super.at,
  });

  final String callId;
  final String toolName;
  final String title;

  /// 给模型的完整输出（持久化 sink 据此写 tool/result 事件）
  final String output;

  final bool isError;
  final Duration duration;

  /// true = 中断/循环保护补齐的占位结果（并非真实执行）
  final bool synthetic;
}

/// step 结束（含 usage）
class AgentStepFinished extends AgentRunEvent {
  AgentStepFinished({
    required this.stepIndex,
    required this.stopKind,
    required this.promptTokens,
    required this.completionTokens,
    required this.totalTokens,
    this.cacheReadTokens,
    this.cacheCreationTokens,
    super.at,
  });

  final int stepIndex;
  final AgentStepStopKind stopKind;
  final int? promptTokens;
  final int? completionTokens;
  final int? totalTokens;

  /// 缓存命中分项（：进 durable 事件日志，聚合卡与旧会话回填用；
  /// null = 端点未上报缓存信息）
  final int? cacheReadTokens;
  final int? cacheCreationTokens;
}

// ==================== 注入消息事件====================

/// 注入来源标识（durable user/message 的 source 字段值）
abstract final class AgentInjectedMessageKinds {
  /// 预算软着陆最后通牒（：步数/token 成本/时长/余量四触发共用）
  static const String budgetFinalNotice = 'budget_final_notice';

  /// 空响应续跑提示
  static const String emptyStopNudge = 'empty_stop_nudge';

  /// 尾部执笔重述
  static const String penReminder = 'pen_reminder';

  // ====================  轮首补账（尾部装配面落日志）====================

  /// turn1 开篇角色提示（向导「初始化你的角色」自由描述路径）
  static const String characterInit = 'character_init';

  /// turn1 能力提示
  static const String firstTurnHint = 'first_turn_hint';

  /// 工作契约（每轮尾部）
  static const String tailContract = 'tail_contract';

  /// 文风铁律（每轮尾部）
  static const String styleIronRule = 'style_iron_rule';

  /// 节奏指令（每轮尾部收尾）
  static const String pacing = 'pacing';

  /// 风格漂移一次性告知（触发轮才有）
  static const String driftReminder = 'drift_reminder';

  /// coreBlocks 挪尾（B 案：coreBlocks 以 user 消息进本轮输入前）
  static const String coreBlocksTail = 'core_blocks_tail';

  /// 跨轮 round-work 工作痕迹（上一轮的痕迹，本轮装配期注入历史区）
  static const String workTrace = 'work_trace';

  /// 资料边界尾部重申（：世界状态含导入来源内容时）
  static const String dataBoundaryReassert = 'data_boundary_reassert';

  /// repeat-tool 递进提醒（：同参连调阈值前的纠错注入）
  static const String repeatToolReminder = 'repeat_tool_reminder';

  /// 伏笔定期清点提醒（清点轮才有：未兑现清单 + 对账指引；与 finish_round
  /// 伏笔对账闸门共用同一节奏源 isForeshadowSweepRound）
  static const String foreshadowSweep = 'foreshadow_sweep';
}

/// harness 合成注入消息已入 surface（补账：此前轮内动态注入不发任何
/// 事件，日志无法重建每步实际发出的完整消息序列）
class AgentInjectedMessageEvent extends AgentRunEvent {
  AgentInjectedMessageEvent({
    required this.message,
    required this.kind,
    super.at,
  });

  final AgentMessage message;

  /// 注入来源（见 [AgentInjectedMessageKinds]）
  final String kind;
}

/// doom-loop 保护触发
class AgentDoomLoopDetected extends AgentRunEvent {
  AgentDoomLoopDetected({
    required this.toolName,
    required this.consecutiveCalls,
    super.at,
  });

  final String toolName;
  final int consecutiveCalls;
}

/// surface/replace 的「替换到投影末尾」哨兵（溢出压缩整面替换用）
///
/// 投影坐标是全会话累积的，轮内消息数无法换算——溢出压缩产物与实际请求
/// 面同构（自带 system 前缀），恒为整面替换。
const int kAgentSurfaceReplaceToEnd = -1;

/// 溢出压缩自愈后的整体 surface 替换（：压缩结果落日志，
/// deriveAgentSurface 经 surface/replace 反映压缩后的消息序列）
class AgentSurfaceReplaced extends AgentRunEvent {
  AgentSurfaceReplaced({
    required this.messages,
    required this.replaceEnd,
    this.replaceStart = 0,
    super.at,
  });

  /// 压缩后的完整消息列表（system 前缀 + 摘要 + 近期消息，协议配对完整）
  final List<AgentMessage> messages;

  /// 被替换区间（投影坐标系；溢出压缩恒为 [0, kAgentSurfaceReplaceToEnd)
  /// 即整面替换）
  final int replaceStart;
  final int replaceEnd;
}

/// 轮结束
class AgentTurnFinished extends AgentRunEvent {
  AgentTurnFinished({
    required this.reason,
    required this.steps,
    required this.usage,
    required this.errorMessage,
    super.at,
  });

  final AgentStopReason reason;
  final int steps;
  final AgentUsageAccumulator usage;
  final String? errorMessage;
}
