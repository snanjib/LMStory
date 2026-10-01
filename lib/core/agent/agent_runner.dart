import 'dart:async';
import 'dart:math';

import 'package:lmstory/core/agent/agent_budget.dart';
import 'package:lmstory/core/agent/agent_cancellation.dart';
import 'package:lmstory/core/agent/agent_events.dart';
import 'package:lmstory/core/agent/agent_llm_gateway.dart';
import 'package:lmstory/core/agent/agent_message.dart';
import 'package:lmstory/core/agent/agent_tool.dart';
import 'package:lmstory/core/agent/agent_tool_pipeline.dart';
import 'package:lmstory/core/agent/agent_waterfall.dart';
import 'package:lmstory/core/agent/agent_workbench_reminder.dart';
import 'package:lmstory/core/agent/doom_loop_detector.dart';
import 'package:lmstory/core/network/retry_after.dart';
import 'package:lmstory/core/utils/logger.dart';

// ==================== 瀑布钩子类型（dsh 四钩子）====================

/// pre-step 决策：放行（可改写本轮发出的消息批）或拒绝（终止轮）
sealed class AgentPreStepDecision {
  const AgentPreStepDecision();
}

class AgentPreStepProceed extends AgentPreStepDecision {
  const AgentPreStepProceed(this.messages);

  final List<AgentMessage> messages;
}

class AgentPreStepReject extends AgentPreStepDecision {
  const AgentPreStepReject(this.reason);

  final String reason;
}

/// request-error 决策：重试同一 step / 终止轮
sealed class AgentRequestErrorDecision {
  const AgentRequestErrorDecision();
}

class AgentRequestErrorRetry extends AgentRequestErrorDecision {
  const AgentRequestErrorRetry();
}

class AgentRequestErrorAbort extends AgentRequestErrorDecision {
  const AgentRequestErrorAbort(this.reason);

  final String reason;
}

/// pre-step 瀑布钩子（拒/改写消息批）
typedef AgentPreStepHook = AgentWaterfallHook<AgentPreStepDecision>;

/// request 瀑布钩子（改调用配置，不能动 messages）
typedef AgentRequestHook = AgentWaterfallHook<AgentCallConfig>;

/// request-error 瀑布钩子（失败 step 关闭后的恢复点）
typedef AgentRequestErrorHook = AgentWaterfallHook<AgentRequestErrorDecision>;

/// 溢出自愈压缩器
///
/// runner 在 [AgentLlmErrorSemantic.contextOverflow] 错误后调用一次：
/// 返回压缩后的**完整工作消息列表**（system 前缀 + 摘要 + 近期消息，
/// 协议配对必须完整），null 或异常 = 压缩不可用（维持原错误路径）。
/// 实现方复用既有压缩服务（导演侧为 StoryCompactionService）。
// ignore: one_member_abstracts, 单方法抽象接口为依赖反转所需
abstract class AgentOverflowCompactor {
  Future<List<AgentMessage>?> compact(List<AgentMessage> working);
}

/// 瀑布钩子集合
class AgentRunnerHooks {
  AgentRunnerHooks({
    List<AgentPreStepHook>? preStep,
    List<AgentRequestHook>? request,
    List<AgentRequestErrorHook>? requestError,
    List<Future<void> Function()>? selfHealRetry,
  })  : preStep = preStep ?? const [],
        request = request ?? const [],
        requestError = requestError ?? const [],
        selfHealRetry = selfHealRetry ?? const [];

  const AgentRunnerHooks.empty()
      : preStep = const [],
        request = const [],
        requestError = const [],
        selfHealRetry = const [];

  final List<AgentPreStepHook> preStep;
  final List<AgentRequestHook> request;
  final List<AgentRequestErrorHook> requestError;

  /// 溢出自愈重试前的检查点：自愈路径不重跑 request 瀑布，
  /// 挂在瀑布上的 flush 语义在此补一次——保证"进模型的必已入日志"
  /// 在自愈重试的请求上同样成立。
  final List<Future<void> Function()> selfHealRetry;
}

/// 事件出口（live； 在此并联持久事件日志 sink）
// ignore: one_member_abstracts, 单方法抽象接口为多实现（广播/缓冲/持久）所需
abstract class AgentEventSink {
  void emit(AgentRunEvent event);
}

/// 轮结果
class AgentTurnResult {
  const AgentTurnResult({
    required this.reason,
    required this.steps,
    required this.appendedMessages,
    required this.usage,
    this.errorMessage,
    this.error,
  });

  final AgentStopReason reason;
  final int steps;

  /// 本轮追加到 surface 的全部消息（assistant/tool/注入消息）
  final List<AgentMessage> appendedMessages;
  final AgentUsageAccumulator usage;
  final String? errorMessage;

  /// 原始异常对象（：error 停轮时保留类型，供上层按异常类型定错误码
  /// ——如 EmbeddingCallFailedException → E104；与 errorMessage 并存）
  final Object? error;

  /// 最后一条 assistant 文本（回复正文；无则空串）
  String get lastAssistantText {
    for (final msg in appendedMessages.reversed) {
      if (msg.role == 'assistant' &&
          msg.content != null &&
          msg.content!.isNotEmpty) {
        return msg.content!;
      }
    }
    return '';
  }

  bool get isSuccessful =>
      reason == AgentStopReason.completed ||
      reason == AgentStopReason.completedByTool;
}

/// 单轮执行规格
class AgentTurnSpec {
  const AgentTurnSpec({
    required this.sessionId,
    required this.surface,
    required this.tools,
    required this.endpoint,
    required this.budget,
    required this.events,
    required this.cancellation,
    this.hooks = const AgentRunnerHooks.empty(),
    this.pipeline,
    this.callConfig = const AgentCallConfig(),
    this.doomLoopDetector,
    this.watchMode = false,
    this.deniedTools = const {},
    this.approvalRequiredFor,
    this.penReminderText,
    this.onToolProgress,
    this.onToolArgDelta,
    this.overflowCompactor,
  });

  final String sessionId;

  /// 模型可见 surface（含本轮触发消息；调用方负责 append-only）
  final List<AgentMessage> surface;

  /// 本轮可用工具（空列表 = 纯对话轮）
  final List<AgentTool> tools;

  final AgentModelEndpoint endpoint;
  final AgentCallConfig callConfig;
  final AgentBudget budget;
  final AgentRunnerHooks hooks;
  final AgentEventSink events;
  final AgentCancellationToken cancellation;

  /// 工具执行管线（null = 每次执行创建裸管线）
  final AgentToolPipeline? pipeline;

  final DoomLoopDetector? doomLoopDetector;

  /// Watch Mode：写/控制档工具执行前走审批 seam（默认关，即默认 allow）
  final bool watchMode;

  /// 被禁用而未注册的工具名：模型调用它们时，信封区分
  /// 「已被禁用」与「不存在」——后者才列可用工具。
  final Set<String> deniedTools;

  /// 逐工具审批判定（导演设置三态工具权限的 ask 语义）。
  ///
  /// 非 null 时覆盖 [watchMode] 的「写档即审批」默认：返回 true 的工具执行前
  /// 走 [pipeline] 审批 seam（deny 工具不注册，此处只会见到 allow/ask 工具）。
  final bool Function(AgentTool tool)? approvalRequiredFor;

  /// 尾部执笔重述（体验重构  第二层防线；null = 禁用）
  ///
  /// 本轮已执行 ≥3 步且全程未出现 finish_round 调用时，在消息尾部注入一条
  /// 极短 reminder（文风铁律 + prose 交付锚定； 起为 role=user 合成
  /// 消息，workbench-reminder 标记包裹），利用 U 形注意
  /// 曲线的尾部强区对抗漂移。
  final String? penReminderText;

  /// 工具执行进度回调（修复：工具体内 onProgress 的桥接口）
  ///
  /// null = 不桥接（进度提示丢弃，与修复前行为一致）。调用方拿 callId
  /// 定位 running 步骤并更新其展示文本。
  final void Function(String callId, String message)? onToolProgress;

  /// 工具参数 JSON 增量回调（正文交付契约 §4.1：finish_round 的 prose
  /// 参数流直播）。null = 不消费（子代理无正文交付职责，不传）。
  final void Function(String toolCallId, String toolName, String delta)?
      onToolArgDelta;

  /// 溢出自愈压缩器；null = 溢出不自愈（维持原错误路径）
  final AgentOverflowCompactor? overflowCompactor;
}

/// AgentRunner：turn/step 循环（opencode 三层中的 runLoop+process 层）
///
/// - `step` = 一次模型请求 + 它调的工具
/// - `turn` = 0..n 个 step，由本类的 [runTurn] 驱动
///
/// 停止条件（硬性，DOC-03A §6）：
/// - 模型停止且无工具调用待执行
/// - 预算：maxSteps / token / 墙钟时间
/// - 用户取消（[AgentCancellationToken]）
/// - doom-loop（连续同参工具调用 ≥3）
/// - pre-step 拒绝 / 请求错误重试耗尽
///
/// abort 语义：取消/中断时为未配对的 tool call 补占位结果消息，
/// 保证 surface 的 tool_use/tool_result 配对合法（下轮重放不报错）。
class AgentRunner {
  AgentRunner({
    required AgentLlmGateway gateway,
    AgentToolPipeline? defaultPipeline,
    Logger? logger,
  })  : _gateway = gateway,
        _defaultPipeline = defaultPipeline ?? AgentToolPipeline(logger: logger),
        _logger = logger;

  final AgentLlmGateway _gateway;
  final AgentToolPipeline _defaultPipeline;
  final Logger? _logger;

  /// 执行一轮（阻塞至轮结束；取消通过 [AgentTurnSpec.cancellation]）
  Future<AgentTurnResult> runTurn(AgentTurnSpec spec) async {
    final stopwatch = Stopwatch()..start();
    final usage = AgentUsageAccumulator();
    final appended = <AgentMessage>[];
    final working = List<AgentMessage>.of(spec.surface);
    final toolMap = {for (final t in spec.tools) t.name: t};
    final doom = spec.doomLoopDetector ?? DoomLoopDetector();

    var steps = 0;
    var reason = AgentStopReason.completed;
    String? errorMessage;
    // error 停轮的原始异常（类型化错误码判定依据）
    Object? crashError;
    spec.events.emit(
      AgentTurnStarted(maxSteps: spec.budget.maxSteps),
    );

    try {
      final outcome = _TurnOutcome();
      await _runSteps(
        spec: spec,
        working: working,
        appended: appended,
        toolMap: toolMap,
        doom: doom,
        usage: usage,
        stopwatch: stopwatch,
        outcome: outcome,
      );
      reason = outcome.reason;
      errorMessage = outcome.message;
      steps = outcome.steps;
    } on AgentCancelledException catch (e) {
      reason = AgentStopReason.cancelled;
      errorMessage = e.reason;
      _pairTrailingToolCalls(
        working,
        appended,
        '本轮已中断，未执行',
        events: spec.events,
      );
    } catch (e, st) {
      reason = AgentStopReason.error;
      errorMessage = e.toString();
      crashError = e;
      _logger?.error('Agent turn crashed', detail: '$e\n$st');
      _pairTrailingToolCalls(
        working,
        appended,
        '本轮异常终止，未执行',
        events: spec.events,
      );
    } finally {
      stopwatch.stop();
    }

    final result = AgentTurnResult(
      reason: reason,
      steps: steps,
      appendedMessages: appended,
      usage: usage,
      errorMessage: errorMessage,
      // 异常对象随结果保留（类型化错误码判定依据）
      error: crashError,
    );
    spec.events.emit(
      AgentTurnFinished(
        reason: reason,
        steps: steps,
        usage: usage,
        errorMessage: errorMessage,
      ),
    );
    return result;
  }

  /// step 循环主体。停止原因与步数写入 [outcome]（Dart 无跨方法 labeled break）。
  Future<void> _runSteps({
    required AgentTurnSpec spec,
    required List<AgentMessage> working,
    required List<AgentMessage> appended,
    required Map<String, AgentTool> toolMap,
    required DoomLoopDetector doom,
    required AgentUsageAccumulator usage,
    required Stopwatch stopwatch,
    required _TurnOutcome outcome,
  }) async {
    while (true) {
      spec.cancellation.throwIfCancelled('step 边界');

      // ---- 预算检查（硬上限，安全停止并保留现场）----
      // ---- 预算软着陆（统一四触发）----
      // maxSteps 步数耗尽 / token 累计消耗达成本上限 / 墙钟时间耗尽 /
      // 上下文余量越限——首次触发不判整轮失败：注入最后通牒并停用工具，
      // 再给一次纯文本请求让模型用现有材料输出完整正文收尾——用户已看到
      // 的流式正文不得因预算耗尽而蒸发（审查 3.1 缺陷 2：此前 token/时长
      // 是硬停）。二次触发（软着陆后仍没收尾）才以触发原因真正停止。
      // maxSteps=0 表示不限步数（导演设置面板「无上限」），仅跳过步数
      // 触发，其余三触发与 doom-loop 检测照常保护。
      //  通牒走 workbench-reminder 包裹的 user 消息通道
      //（角色约定）——保住 recency 位且不打爆缓存前缀。
      (AgentStopReason, String)? budgetTrigger;
      if (spec.budget.maxSteps > 0 && outcome.steps >= spec.budget.maxSteps) {
        budgetTrigger = (
          AgentStopReason.maxSteps,
          '步数预算耗尽（${spec.budget.maxSteps}）',
        );
      }
      final tokenBudget = spec.budget.maxTotalTokens;
      if (budgetTrigger == null &&
          tokenBudget != null &&
          usage.totalTokens >= tokenBudget) {
        budgetTrigger = (
          AgentStopReason.budgetTokens,
          'token 累计消耗达上限（$tokenBudget）',
        );
      }
      final duration = spec.budget.maxDuration;
      if (budgetTrigger == null &&
          duration != null &&
          stopwatch.elapsed > duration) {
        budgetTrigger = (
          AgentStopReason.budgetDuration,
          '时间预算耗尽（${duration.inSeconds}s）',
        );
      }
      final contextWindow = spec.budget.contextWindowTokens;
      if (budgetTrigger == null && contextWindow != null) {
        // 余量触发线 = 窗口 × 0.85；占用口径 = 最近一次请求的
        // promptTokens + cacheReadTokens（审查收官 ：Anthropic
        // promptTokens 不含 cache 读，只看 prompt 会让缓存命中最重的会话
        // 守卫永不触发，装爆上下文退化为更贵的轮中溢出压缩），
        // >0 才参与判定（无 usage 数据的端点不误触发）
        final headroomLine = (contextWindow * 0.85).round();
        final lastPrompt = usage.lastPromptTokens + usage.lastCacheReadTokens;
        if (lastPrompt > 0 && lastPrompt >= headroomLine) {
          budgetTrigger = (
            AgentStopReason.contextHeadroom,
            '上下文余量越限（最近请求 $lastPrompt tokens ≥ 触发线 $headroomLine）',
          );
        }
      }
      if (budgetTrigger != null) {
        if (outcome.finalNoticeIssued) {
          outcome.done(
            budgetTrigger.$1,
            '${budgetTrigger.$2}，软着陆后仍未收尾',
          );
          return;
        }
        outcome.finalNoticeIssued = true;
        final notice = AgentMessage.user(
          wrapWorkbenchReminder(
            '$kPriorityObedienceClause${budgetTrigger.$2}。所有工具已停用。'
            '立即用你已掌握的材料直接输出完整的叙事正文文本收尾'
            '（系统会自动收录为正文），然后结束本轮。',
          ),
        );
        working.add(notice);
        appended.add(notice);
        //  补账：注入消息发事件（日志可重建每步实际发出的消息序列）
        spec.events.emit(
          AgentInjectedMessageEvent(
            message: notice,
            kind: AgentInjectedMessageKinds.budgetFinalNotice,
          ),
        );
        _logger?.warn(
          'Agent budget soft landing',
          detail: 'reason=${budgetTrigger.$1.name}, tools disabled',
        );
      }

      // ---- 尾部执笔重述（+ 契约 §7.3：≥3 步且全程未出现 finish_round
      // 调用时注入一次铁律 reminder——执笔=发起 finish_round，重述在它
      // 之前一锚）----
      //  角色约定：role=user + workbench-reminder 标记包裹（Anthropic
      // 端不上提，保住 recency 位）；触发条件与文案不动（快轮由每轮
      // 尾部契约/铁律覆盖，这里是 ≥3 步长轮的二次兜底）。
      final reminderText = spec.penReminderText;
      if (reminderText != null &&
          !outcome.penReminderIssued &&
          outcome.steps >= 3 &&
          !outcome.finishAttempted) {
        outcome.penReminderIssued = true;
        final reminder = AgentMessage.user(wrapWorkbenchReminder(reminderText));
        working.add(reminder);
        appended.add(reminder);
        spec.events.emit(
          AgentInjectedMessageEvent(
            message: reminder,
            kind: AgentInjectedMessageKinds.penReminder,
          ),
        );
      }

      // ---- pre-step 瀑布（拒/改写消息批）----
      final preDecision = await runAgentWaterfall<AgentPreStepDecision>(
        spec.hooks.preStep,
        AgentPreStepProceed(List.unmodifiable(working)),
        () async => AgentPreStepProceed(List.unmodifiable(working)),
      );
      List<AgentMessage> outgoing;
      switch (preDecision) {
        case AgentPreStepReject(:final reason):
          outcome.done(AgentStopReason.hookRejected, reason);
          return;
        case AgentPreStepProceed(:final messages):
          outgoing = messages;
      }

      // ---- request 瀑布（改调用配置，不动 messages）----
      final callConfig = await runAgentWaterfall<AgentCallConfig>(
        spec.hooks.request,
        spec.callConfig,
        () async => spec.callConfig,
      );

      // ---- 单个 LLM step（含 request-error 重试瀑布）----
      final response = await _completeWithRetry(
        spec: spec,
        outgoing: outgoing,
        working: working,
        callConfig: callConfig,
        stepIndex: outcome.steps,
        outcome: outcome,
      );
      if (response == null) return; // 已通过 outcome 回填失败原因

      outcome.steps++;
      usage.add(response.usage);

      // 正文追踪（契约 §7.3）：出现 finish_round 调用即视为已发起执笔
      if (response.toolCalls.any((c) => c.name == 'finish_round')) {
        outcome.finishAttempted = true;
      }

      // 长文本追踪（空响应 nudge 的判据：正文已流出则不干预弃疗救援）
      if (response.text.length >= 200) {
        outcome.hasEmittedProse = true;
      }

      // ---- assistant 消息入 surface ----
      final assistant = AgentMessage.assistant(
        text: response.text.isEmpty ? null : response.text,
        toolCalls: response.toolCalls.isEmpty ? null : response.toolCalls,
        reasoningContent: response.reasoningContent,
        thinkingBlocks: response.thinkingBlocks,
      );
      working.add(assistant);
      appended.add(assistant);
      spec.events.emit(
        AgentAssistantMessageEvent(
          stepIndex: outcome.steps,
          message: assistant,
        ),
      );

      for (final call in response.toolCalls) {
        spec.events.emit(
          AgentToolCallReceived(stepIndex: outcome.steps, call: call),
        );
      }

      spec.events.emit(
        AgentStepFinished(
          stepIndex: outcome.steps,
          stopKind: response.hasToolCalls
              ? AgentStepStopKind.toolCalls
              : response.text.isEmpty
                  ? AgentStepStopKind.empty
                  : AgentStepStopKind.textReply,
          promptTokens: response.usage?.promptTokens,
          completionTokens: response.usage?.completionTokens,
          totalTokens: response.usage?.totalTokens,
          // cache 分项随步事件上抛（durable 落库 → 聚合/回填）
          cacheReadTokens: response.usage?.cacheReadTokens,
          cacheCreationTokens: response.usage?.cacheCreationTokens,
        ),
      );

      // ---- 无工具调用：turn-stopping 串行检查点 ----
      if (!response.hasToolCalls) {
        // ---- 长度截断：直接报错，不自动重试 ----
        // finish_reason=length 且无正文 ≠ 模型弃疗：它在写，但推理把输出
        // 预算烧完了（SenseNova 等端点 max_tokens 含 reasoning）。自动提额
        // 重试会再消耗一轮 token 且常不改善，改为带诊断信息停止，
        // 交上层判可重试失败，由用户决定是否调大「输出上限」后手动重试。
        if (response.text.isEmpty && response.finishReason == 'length') {
          final current = callConfig.maxTokens;
          outcome.done(
            AgentStopReason.completed,
            '模型输出被长度上限截断（finish_reason=length'
            '${current != null && current > 0 ? '，输出上限 $current' : ''}）：'
            '推理占用了全部输出预算，没有余量输出正文。'
            '请在会话设置调大「输出上限」，或换用非推理模型。',
          );
          return;
        }
        // 空响应救援（弱模型在工具失败信封后弃疗的常见形态）：全轮尚无
        // 正文时收到空响应，注入一次续跑提示再给模型一次机会，而不是把
        // 空轮当作正常完成交给上层。每轮只救一次，正文已流出则不干预。
        if (response.text.isEmpty &&
            !outcome.hasEmittedProse &&
            !outcome.emptyStopNudgeIssued &&
            // 审查收官 ：软着陆后不再 nudge——通牒后的空响应会在
            // 下次循环顶二次触发停轮，nudge 注入了也永远发不出去（幽灵消息落账）
            !outcome.finalNoticeIssued) {
          outcome.emptyStopNudgeIssued = true;
          //  同 maxSteps 通牒，走 user 通道保 recency 位
          final nudge =
              AgentMessage.user(wrapWorkbenchReminder(kEmptyStopNudge));
          working.add(nudge);
          appended.add(nudge);
          spec.events.emit(
            AgentInjectedMessageEvent(
              message: nudge,
              kind: AgentInjectedMessageKinds.emptyStopNudge,
            ),
          );
          _logger?.warn(
            'Agent empty stop rescued by nudge',
            detail: 'steps=${outcome.steps}',
          );
          continue;
        }
        outcome.done(AgentStopReason.completed, null);
        return;
      }

      // ---- doom-loop 检测（执行前拦截）----
      // 契约 §7.2：finish_round 不进 doom 登记——闸门连拒后的
      // 同参重提交是正常纠错流程（拒→修→过），误杀整轮；其循环防线由
      // finish_round 失败软上限（§2.5）接管。未注册工具（含被 deny 的
      // 工具名）照旧登记。
      // 审查收官 ：豁免按名不按档——spawn/ask_user 同为 control
      // 档，按档豁免会让同参 brief 反复 spawn 无递进提醒无 doom 拦截
      //（ask_user 有每轮 2 次自身上限到不了阈值；spawn 无上限必须受管）。
      // 阈值前的递进提醒——同参连调 3/5 次注入确定性提醒
      //（workbench-reminder 包裹，不唤醒不中断），给模型自行纠错的机会。
      // 注入时机在本轮全部工具结果之后（见下方注入点）：OpenAI 兼容端点
      // 要求 tool 消息紧跟带 tool_calls 的 assistant 消息，夹在中间会 400。
      var doomed = false;
      final deferredReminders = <AgentMessage>[];
      for (final call in response.toolCalls) {
        // 已注册的 finish_round 豁免（闸门纠错流程）；被 deny 的
        // finish_round 名（未注册）照旧登记——无视禁用信封反复调用
        // 正是 doom 要拦的形态
        if (call.name == 'finish_round' && toolMap.containsKey(call.name)) {
          continue;
        }
        if (doom.register(call)) {
          doomed = true;
        } else if (!outcome.finalNoticeIssued &&
            _repeatReminderStreaks.contains(doom.currentStreak)) {
          deferredReminders.add(
            AgentMessage.user(
              wrapWorkbenchReminder(
                '你已连续 ${doom.currentStreak} 次以完全相同的参数调用 '
                '${doom.lastToolName}，结果不会改变。改换参数、换用其他工具，'
                '或直接用已有材料继续。',
              ),
            ),
          );
        }
      }
      if (doomed) {
        spec.events.emit(
          AgentDoomLoopDetected(
            toolName: doom.lastToolName ?? response.toolCalls.first.name,
            consecutiveCalls: doom.currentStreak,
          ),
        );
        _pairTrailingToolCalls(
          working,
          appended,
          '循环保护拦截：同参数重复调用',
          events: spec.events,
        );
        outcome.done(
          AgentStopReason.doomLoop,
          '连续 ${doom.currentStreak} 次相同参数调用 '
          '${doom.lastToolName ?? '(未知工具)'}，已暂停',
        );
        return;
      }

      // ---- 执行工具（串行；故事工具多为有序操作）----
      var terminal = false;
      final pipeline = spec.pipeline ?? _defaultPipeline;
      for (final call in response.toolCalls) {
        spec.cancellation.throwIfCancelled('工具执行前');

        final tool = toolMap[call.name];
        final pipelineOutcome = await _executeToolCall(
          spec: spec,
          pipeline: pipeline,
          tool: tool,
          call: call,
          stepIndex: outcome.steps,
          toolsDisabled: outcome.finalNoticeIssued,
          finishReason: response.finishReason,
          usage: usage,
        );
        if (pipelineOutcome == null) {
          return; // 取消时由外层 AgentCancelledException 路径处理（防御分支）
        }

        final toolMessage = AgentMessage.toolResult(
          toolCallId: call.id,
          content: pipelineOutcome.result.output,
        );
        working.add(toolMessage);
        appended.add(toolMessage);

        if (pipelineOutcome.result.terminal) {
          terminal = true;
        }

        // finish_round 失败软上限（契约 §2.5）：豁免 doom 后的循环防线。
        // 连续失败（提交异常/守卫信封/闸门拒）≥5 次判 error 停轮；非 error
        // 结果清零。正常闸门流程（拒→修→过）2-4 次内闭环，不会触顶。
        if (call.name == 'finish_round') {
          if (pipelineOutcome.result.isError) {
            outcome.finishAttempts++;
            if (outcome.finishAttempts >= _maxFinishRoundAttempts) {
              _pairTrailingToolCalls(
                working,
                appended,
                'finish_round 反复失败，本轮停止',
                events: spec.events,
              );
              outcome.done(
                AgentStopReason.error,
                'finish_round 连续失败 ${outcome.finishAttempts} 次（守卫/闸门/提交反复被拒），已停止本轮',
              );
              return;
            }
          } else {
            outcome.finishAttempts = 0;
          }
        }
      }

      if (terminal) {
        outcome.done(AgentStopReason.completedByTool, null);
        return;
      }

      // 递进提醒注入点：本轮全部工具结果之后（doomed/终局路径直接返回，
      // 队列随之丢弃——没有下一次请求，提醒无意义）。
      for (final reminder in deferredReminders) {
        working.add(reminder);
        appended.add(reminder);
        spec.events.emit(
          AgentInjectedMessageEvent(
            message: reminder,
            kind: AgentInjectedMessageKinds.repeatToolReminder,
          ),
        );
      }
    }
  }

  /// 带 request-error 重试瀑布的单步请求；失败时通过 [outcome] 回填并返回 null
  ///
  ///  [working] 是本轮工作消息列表（可变）——上下文超限
  /// 时默认策略先经 [AgentTurnSpec.overflowCompactor] 压缩并就地重建
  /// working/outgoing，重试同一 step 一次；压缩不可用或二次仍超限则停轮。
  Future<AgentStepResponse?> _completeWithRetry({
    required AgentTurnSpec spec,
    required List<AgentMessage> outgoing,
    required List<AgentMessage> working,
    required AgentCallConfig callConfig,
    required int stepIndex,
    required _TurnOutcome outcome,
  }) async {
    final wireOptions = AgentWireOptions.forProtocolName(
      spec.endpoint.protocol,
    );
    var requestMessages = outgoing;
    var attempt = 0;
    while (true) {
      try {
        spec.events
            .emit(AgentStepStarted(stepIndex: stepIndex, attempt: attempt));
        return await _gateway.completeStep(
          endpoint: spec.endpoint,
          request: AgentStepRequest(
            messages: requestMessages
                .map((m) => m.toRequestMap(wireOptions))
                .toList(),
            // 软着陆后工具停用（纯文本收尾请求）
            tools: outcome.finalNoticeIssued
                ? const []
                : agentToolsToDefinitions(spec.tools),
            config: callConfig,
          ),
          cancellation: spec.cancellation,
          onTextDelta: (delta) => spec.events.emit(
            AgentTextDeltaEvent(stepIndex: stepIndex, delta: delta),
          ),
          onThinkingDelta: (delta) => spec.events.emit(
            AgentThinkingDeltaEvent(stepIndex: stepIndex, delta: delta),
          ),
          onToolArgDelta: spec.onToolArgDelta,
        );
      } on AgentCancelledException {
        rethrow;
      } on AgentLlmException catch (e) {
        // 用户取消经网关会以可重试 AgentLlmException
        // 落到本瀑布——入口先查取消，避免「停止」先闪限流等待条、再等退避
        //（Retry-After 封顶 60s）才生效。
        if (spec.cancellation.isCancelled) {
          outcome.done(AgentStopReason.cancelled, '取消');
          return null;
        }
        // request-error 瀑布：失败 step 关闭后的恢复点。
        // 默认策略 = 溢出压缩自愈+ runner 自身的重试预算（可重试错误
        // 重试至 maxRequestRetries），钩子可观察默认决策并接管
        //（退避 / 直接放弃）。
        final isOverflow = e.semantic == AgentLlmErrorSemantic.contextOverflow;
        final message = '${e.message}${e.code == null ? '' : ' (${e.code})'}';

        // 溢出自愈（每轮一次）：压缩 → 重建 working/outgoing → 重试同 step。
        // 压缩失败/无压缩器 → 落到默认策略（overflow 直接停轮，不空转重发）。
        if (isOverflow &&
            spec.overflowCompactor != null &&
            !outcome.overflowCompacted) {
          List<AgentMessage>? compacted;
          try {
            compacted = await spec.overflowCompactor!.compact(working);
          } catch (err) {
            _logger?.warn(
              'Agent overflow compaction failed',
              detail: '$err',
            );
          }
          if (compacted != null && compacted.isNotEmpty) {
            outcome.overflowCompacted = true;
            if (spec.cancellation.isCancelled) {
              outcome.done(AgentStopReason.cancelled, '取消');
              return null;
            }
            // 压缩结果落日志（surface/replace，整面替换——投影坐标
            // 是全会话累积的，轮内消息数无法换算），deriveAgentSurface
            // 从此可反映压缩后的真实请求序列
            spec.events.emit(
              AgentSurfaceReplaced(
                messages: List.unmodifiable(compacted),
                replaceEnd: kAgentSurfaceReplaceToEnd,
              ),
            );
            working
              ..clear()
              ..addAll(compacted);
            // 重建重试消息批：压缩已替换 pre-step 快照，不再重放旧钩子产物
            requestMessages = List.unmodifiable(compacted);
            attempt++;
            // request 瀑布（含 durable flush）不随自愈重跑，此处
            // 补一次检查点——surface/replace 事件先落库再发重试请求，
            // 崩溃窗口内投影不与真实请求分叉
            for (final hook in spec.hooks.selfHealRetry) {
              await hook();
            }
            _logger?.warn(
              'Agent overflow self-healed, retrying step',
              detail: 'stepIndex=$stepIndex, messages=${compacted.length}',
            );
            continue;
          }
        }

        Future<AgentRequestErrorDecision> defaultPolicy() async {
          if (isOverflow) {
            // 上下文超限重发同一请求必然再超限：无自愈路径时直接停轮
            //（与修复前 400 不可重试的行为一致，但带上归一后的明确原因）
            return AgentRequestErrorAbort('$message（上下文超限，已无法继续）');
          }
          if (!e.retryable) {
            return AgentRequestErrorAbort('$message（不可重试错误）');
          }
          if (attempt >= spec.budget.maxRequestRetries) {
            return AgentRequestErrorAbort('$message（已重试 $attempt 次）');
          }
          return const AgentRequestErrorRetry();
        }

        final decision = await runAgentWaterfall<AgentRequestErrorDecision>(
          spec.hooks.requestError,
          await defaultPolicy(),
          defaultPolicy,
        );
        switch (decision) {
          case AgentRequestErrorRetry():
            attempt++;
            //  修复：请求错误重试加指数退避——此前立即重发，
            // 429/限流场景大概率再撞，徒增失败步与 token 消耗。
            // 优先尊重服务端 Retry-After 冷却指示（封顶 60s）；无指示时
            // 指数退避（500ms 起翻倍封顶 4s）+ ±25% jitter。等待期间尊重取消。
            final delay = retryDelayFor(e, attempt);
            if (delay > Duration.zero) {
              // 重试等待可视化——等待开始前
              // 上抛事件，UI 以到达时刻为锚渲染倒计时状态条
              spec.events.emit(
                AgentRetryScheduled(
                  waitMs: delay.inMilliseconds,
                  attempt: attempt,
                ),
              );
              // 退避期可被打断——取消经 whenCancelled
              // 竞速提前返回，不必等 Retry-After 冷却（封顶 60s）走完
              await Future.any(<Future<void>>[
                Future<void>.delayed(delay),
                spec.cancellation.whenCancelled,
              ]);
            }
            if (spec.cancellation.isCancelled) {
              outcome.done(AgentStopReason.cancelled, '取消');
              return null;
            }
            _logger?.warn(
              'Agent step request failed, retrying',
              detail: 'attempt=$attempt, backoff=${delay.inMilliseconds}ms, '
                  'error=${e.message}',
            );
            continue;
          case AgentRequestErrorAbort(:final reason):
            outcome.done(AgentStopReason.error, reason);
            return null;
        }
      }
    }
  }

  Future<ToolPipelineOutcome?> _executeToolCall({
    required AgentTurnSpec spec,
    required AgentToolPipeline pipeline,
    required AgentTool? tool,
    required AgentToolCall call,
    required int stepIndex,
    bool toolsDisabled = false,
    String? finishReason,
    AgentUsageAccumulator? usage,
  }) async {
    final argsPreview = call.arguments.toString();
    spec.events.emit(
      AgentToolExecutionStarted(
        callId: call.id,
        toolName: call.name,
        argsPreview: argsPreview.length > 120
            ? '${argsPreview.substring(0, 120)}…'
            : argsPreview,
      ),
    );
    final stopwatch = Stopwatch()..start();

    ToolPipelineOutcome outcome;
    if (toolsDisabled) {
      // 软着陆后模型仍幻觉工具调用：返回可行动的停用信封（不中断轮）
      outcome = ToolPipelineOutcome(
        wasDenied: true,
        result: AgentToolResult.failure(
          title: '工具已停用',
          output: kMaxStepsFinalNotice,
        ),
      );
    } else if (tool == null) {
      // 区分「被禁用」与「不存在」——禁用的工具列可用清单没用
      //（模型明知它在清单里才会去调），改报禁用事实。
      final isDenied = spec.deniedTools.contains(call.name);
      outcome = ToolPipelineOutcome(
        wasDenied: true,
        result: AgentToolResult.failure(
          title: isDenied ? '工具已被禁用' : '未知工具',
          output: isDenied
              ? '工具 `${call.name}` 已被导演禁用，本轮不可用。请改用其他工具或直接用已有材料继续。'
              : '工具 `${call.name}` 不存在。可用工具：'
                  '${spec.tools.map((t) => t.name).join('、')}。'
                  '请改用列出的工具。',
        ),
      );
    } else {
      outcome = await pipeline.execute(
        tool: tool,
        callId: call.id,
        stepIndex: stepIndex,
        sessionId: spec.sessionId,
        cancellation: spec.cancellation,
        arguments: call.arguments,
        // 监督模式只拦"写入"（update_facts/update_story_anchor）；
        // finish_round 是草稿提交、ask_user 本身就是问用户，不重复审批。
        //  起导演侧经 approvalRequiredFor 逐工具判定（ask 态才拦）。
        approvalRequired: spec.approvalRequiredFor != null
            ? spec.approvalRequiredFor!(tool)
            : spec.watchMode && tool.permission == AgentToolPermission.write,
        //  修复：进度提示桥接到调用方（此前管线内空操作）
        onProgress: spec.onToolProgress == null
            ? null
            : (message) => spec.onToolProgress!(call.id, message),
        // 正文交付契约 §2.4：finish_reason 交给工具体（finish_round 截断诊断）
        finishReason: finishReason,
        // 父轮 usage 累计器（spawn 工具把子代理消耗并账进预算）
        turnUsage: usage,
      );
    }

    stopwatch.stop();
    spec.events.emit(
      AgentToolExecutionFinished(
        callId: call.id,
        toolName: call.name,
        title: outcome.result.title,
        output: outcome.result.output,
        isError: outcome.result.isError,
        duration: stopwatch.elapsed,
      ),
    );
    return outcome;
  }

  /// 为 surface 末尾未配对的 tool call 补占位结果消息（协议配对合法性）
  void _pairTrailingToolCalls(
    List<AgentMessage> working,
    List<AgentMessage> appended,
    String placeholder, {
    AgentEventSink? events,
  }) {
    // 向前找最近一条 assistant 消息，检查其后的 tool 结果是否齐全
    for (var i = working.length - 1; i >= 0; i--) {
      final msg = working[i];
      if (msg.role == 'tool') continue; // 已有结果
      if (msg.role != 'assistant') break; // 没有悬空调用
      final calls = msg.toolCalls;
      if (calls == null || calls.isEmpty) continue; // 纯文本，继续向前
      final answered = <String>{};
      for (var j = i + 1; j < working.length; j++) {
        final later = working[j];
        if (later.role == 'assistant') break;
        if (later.role == 'tool' && later.toolCallId != null) {
          answered.add(later.toolCallId!);
        }
      }
      for (final call in calls) {
        if (answered.contains(call.id)) continue;
        final placeholderMsg = AgentMessage.toolResult(
          toolCallId: call.id,
          content: '（$placeholder）',
        );
        working.add(placeholderMsg);
        appended.add(placeholderMsg);
        events?.emit(
          AgentToolExecutionFinished(
            callId: call.id,
            toolName: call.name,
            title: '占位补齐',
            output: '（$placeholder）',
            isError: true,
            duration: Duration.zero,
            synthetic: true,
          ),
        );
      }
      break; // 只处理最近一条带调用的 assistant 消息
    }
  }
}

extension AgentToolResultPreview on AgentToolResult {
  /// 事件展示用预览
  String preview([int max = 160]) {
    if (output.length <= max) return output;
    return '${output.substring(0, max)}…';
  }
}

/// 轮内可变结果容器（循环体与重试逻辑跨方法回填停止原因/步数）
class _TurnOutcome {
  AgentStopReason reason = AgentStopReason.completed;
  String? message;
  int steps = 0;

  /// maxSteps 软着陆已注入最后通牒（二次到达上限才判停止）
  bool finalNoticeIssued = false;

  /// 全程已出现 finish_round 调用（契约 §7.3：尾部执笔重述的判定依据——
  /// 执笔=发起 finish_round，与长文本判定解耦）
  bool finishAttempted = false;

  /// 已输出 ≥200 字长文本（空响应 nudge 的判定依据）
  bool hasEmittedProse = false;

  /// 尾部执笔重述已注入（每轮一次）
  bool penReminderIssued = false;

  /// finish_round 连续失败计数（契约 §2.5 软上限；非 error 结果清零）
  int finishAttempts = 0;

  /// 空响应续跑提示已注入（每轮一次）
  bool emptyStopNudgeIssued = false;

  /// 溢出压缩自愈已用过（每轮一次，防压缩-重试循环）
  bool overflowCompacted = false;

  void done(AgentStopReason reason, String? message) {
    this.reason = reason;
    this.message = message;
  }
}

/// maxSteps 软着陆最后通牒（正文交付契约 §3.3-⑤；软着陆后工具停用，
/// 纯文本收尾即通道 C——文本回退）。
///
/// 句首 [kPriorityObedienceClause] 服从强化（位置无关；详见契约设计
/// 文档「协议差异声明」）。
const String kMaxStepsFinalNotice = '$kPriorityObedienceClause'
    '步数预算已用尽，所有工具已停用。立即用你已掌握的材料直接输出完整的叙事正文文本收尾（系统会自动收录为正文），然后结束本轮。';

/// 空响应续跑提示（正文交付契约 §3.3-⑥；每轮一次，弱模型弃疗的救援）
const String kEmptyStopNudge =
    '你刚才的回复是空的，本轮尚未交付正文。立即调用 finish_round 并把完整正文写入 prose 参数；若工具不可用，直接输出完整正文文本收尾（系统会自动收录）。不要再次返回空回复。';

/// 尾部执笔重述默认文案（正文交付契约 §3.3-④；文风铁律 + 交付锚定）。
///
/// 标签后接 [kPriorityObedienceClause] 服从强化（位置无关）。
const String kDefaultPenReminderText = '【执笔提醒】$kPriorityObedienceClause'
    '即将进入正文。铁律：禁破折号；禁"不是A，而是B"式虚假对仗；禁凑三连排比；句长错落；允许毛边；直接以正文开始。正文完整写入 finish_round 的 prose 参数，回复文本只留一句过场。';

/// finish_round 失败软上限（契约 §2.5）：连续失败达到此次数判 error 停轮
const int _maxFinishRoundAttempts = 5;

/// repeat-tool 递进提醒触发 streak（：doom 阈值前的两次纠错机会；
/// 默认 doom 阈值 8 → 提醒落在 3/5 次）
const Set<int> _repeatReminderStreaks = {3, 5};

/// 请求错误重试的指数退避毫秒数（修复 2026-08-23）
///
/// 500ms 起翻倍，封顶 4s：attempt=1→500，2→1000，3→2000，≥4→4000。
int _retryBackoffMs(int attempt) {
  var ms = 500;
  for (var i = 1; i < attempt && ms < 4000; i++) {
    ms *= 2;
  }
  return ms > 4000 ? 4000 : ms;
}

/// Retry-After 冷却封顶（：尊重长冷却但不无限等待）
const Duration _maxRetryAfterDelay = Duration(seconds: 60);

/// 请求错误重试延迟
///
/// 优先 [AgentLlmException.retryAfter]（服务端限流冷却指示，封顶 60s）；
/// 无指示时指数退避 + ±25% jitter（隐藏真实重试节奏，避免同批客户端
/// 同步重发）。[roll] ∈ [0,1) 可注入（测试确定性），缺省随机。
Duration retryDelayFor(AgentLlmException e, int attempt, {double? roll}) {
  final retryAfter = e.retryAfter;
  if (retryAfter != null) {
    return retryAfter > _maxRetryAfterDelay ? _maxRetryAfterDelay : retryAfter;
  }
  return jitteredDelay(
    Duration(milliseconds: _retryBackoffMs(attempt)),
    roll ?? _retryJitterRandom.nextDouble(),
  );
}

final Random _retryJitterRandom = Random();
