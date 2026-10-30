import 'dart:async';
import 'package:flutter/material.dart';
import 'package:lmstory/core/network/retry_policy.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_spacing.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_text_styles.dart';
import 'package:lmstory/core/theme/shared/components/lm_activity_dots.dart';
import 'package:lmstory/core/theme/shared/components/lm_state_transition.dart';
import 'package:lmstory/core/theme/shared/components/streaming_fade_text.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/advanced/domain/entities/advanced_chat_state.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_timeline_block.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_work_step.dart';
import 'package:lmstory/features/advanced/presentation/widgets/director_tool_card.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 导演模式幕后工作折叠组（对话流计划 §5.1，由 DirectorProcessRow 演进）
///
/// 吃统一轮时间线（live 态吃 AgentTimelineAssembler 现算装配、历史态吃
/// artifacts.agentTimeline 反序列化），组内按真实发生顺序交错渲染：
/// 思考块（时长标题折叠行）→ 动作卡（[DirectorToolCard] 组件不动）→
/// 播报行（无框裸文本，字体与正文一致）。
///
/// 标题行由元数据算出：`幕后 N 步 · 思考 M 段 · Xs`；错误时
/// 图标转红。live 态沿用「正在 X… · 第 N 步」原地更新（修复保留）。
///
/// 保留项（与 DirectorProcessRow 一致）：error 动作卡收起态常显；历史轮
/// 展开/收起 200ms 高度动画（live 不做高度动画）；会话成本行留组底。
/// 旧会话（无 agentTimeline）不走本组件，回退 DirectorProcessRow。
class DirectorWorkGroup extends StatefulWidget {
  const DirectorWorkGroup({
    required this.timeline,
    this.live = false,
    this.textStreaming = false,
    this.summary,
    this.progress,
    super.key,
  });

  final List<AgentTimelineBlock> timeline;

  /// 是否进行中轮（控制进行中文案与展开动画策略）
  final bool live;

  /// 正文是否正在稿件卡流式（升格出组的末个文本段）
  ///
  /// true 时思考块不再视为"直播末块"（正文接管直播焦点），末段思考行
  /// 自动收起——与旧直播行为一致（思考后有正文到达即收起）。
  final bool textStreaming;

  /// 历史轮工作摘要（步数/token/总时长）；live 轮为 null
  final AgentWorkSummary? summary;

  /// 轮中预算进度（live 轮标题数据源；null = 无数据走旧口径）
  ///
  /// 提供时 live 标题升级为「第 N/M 步 · 已用 X:XX · 正在…」，预算占用
  /// ≥80% 时标题文本转警示色；maxSteps=0（无上限）不显示分母。
  final AgentRoundProgress? progress;

  @override
  State<DirectorWorkGroup> createState() => _DirectorWorkGroupState();
}

class _DirectorWorkGroupState extends State<DirectorWorkGroup> {
  var _expanded = false;

  // ── ：用时计时（tick 计数驱动，widget 测试 fake clock 可推进）──
  Timer? _elapsedTicker;
  int _elapsedTicks = 0;

  /// 首帧时刻与轮开始锚点的时差（真实时钟只在起表时读一次）
  int _elapsedLagMs = 0;

  @override
  void initState() {
    super.initState();
    // 直播中默认展开：时间线原样直播（§2.3）；历史/收工形态默认折叠
    _expanded = widget.live;
    _syncElapsedTicker();
  }

  @override
  void didUpdateWidget(DirectorWorkGroup oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 收工（live→false）自动收起为汇总行（§2.1 收工默认折叠）；
    // 用户手动收起/展开不干预
    if (oldWidget.live && !widget.live && _expanded) {
      _expanded = false;
    }
    // 换轮（新锚点）重置用时；其余情况由 _syncElapsedTicker 幂等处理
    final oldAnchor = oldWidget.progress?.startedAtMs;
    final newAnchor = widget.progress?.startedAtMs;
    if (oldAnchor != newAnchor) {
      _elapsedTicks = 0;
    }
    _syncElapsedTicker();
  }

  @override
  void dispose() {
    _elapsedTicker?.cancel();
    super.dispose();
  }

  /// live 且有预算数据时起 1s 计时表，否则停表（幂等）
  void _syncElapsedTicker() {
    if (widget.live && widget.progress != null) {
      if (_elapsedTicker == null) {
        final lag = DateTime.now().millisecondsSinceEpoch -
            widget.progress!.startedAtMs;
        _elapsedLagMs = lag > 0 ? lag : 0;
        _elapsedTicker = Timer.periodic(const Duration(seconds: 1), (_) {
          if (!mounted) return;
          _elapsedTicks++;
          setState(() {});
        });
      }
    } else {
      _elapsedTicker?.cancel();
      _elapsedTicker = null;
    }
  }

  /// 当前已用秒数（锚点时差 + tick 计数；测试 fake clock 只走 Timer）
  int get _elapsedSeconds =>
      ((_elapsedLagMs + _elapsedTicks * 1000) / 1000).floor();

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    final timeline = widget.timeline;
    if (timeline.isEmpty) return const SizedBox.shrink();

    final actions = [
      for (final block in timeline)
        if (block.isAction) block.action!,
    ];
    final thinkingSegments =
        timeline.where((b) => b.kind == AgentTimelineKind.thinking).length;
    final hasError = actions.any((s) => s.isError);
    final hasWarning = actions.any((s) => s.isWarning);
    final iconColor = hasError
        ? colors.error
        : hasWarning
            ? colors.warning
            : colors.faint;

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          borderRadius: BorderRadius.circular(6),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 40),
            child: Row(
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: LmStateTransition(
                    stateKey: (widget.live, hasError, hasWarning),
                    alignment: Alignment.center,
                    child: widget.live
                        ? LmActivityDots(color: iconColor, dotSize: 2)
                        : Icon(
                            _expanded
                                ? Icons.tungsten
                                : Icons.tungsten_outlined,
                            size: 14,
                            color: iconColor,
                          ),
                  ),
                ),
                const SizedBox(width: IntermediateSpacing.sSm),
                Expanded(
                  child: Text(
                    _headline(actions, thinkingSegments, t),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: IntermediateTextStyles.caption.copyWith(
                      // 预算占用 ≥80% 标题转警示色
                      color: _headlineColor(colors),
                    ),
                  ),
                ),
                AnimatedRotation(
                  turns: _expanded ? 0.5 : 0,
                  duration: LmMotion.durationFor(context, LmMotion.fold),
                  curve: LmMotion.easeSnap,
                  child: Icon(
                    Icons.expand_more,
                    size: 16,
                    color: colors.faint,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_expanded)
          Padding(
            padding: const EdgeInsets.only(
              top: IntermediateSpacing.s2xs,
              bottom: IntermediateSpacing.sXs,
            ),
            child: RepaintBoundary(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ..._interleavedChildren(timeline),
                ],
              ),
            ),
          )
        else
          // 收起态：失败动作卡常显（不藏进组内）
          Padding(
            padding: const EdgeInsets.only(top: IntermediateSpacing.s2xs),
            child: RepaintBoundary(
              child: Builder(
                builder: (context) {
                  final occurrence = <String, int>{};
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final block in timeline)
                        if (block.isAction &&
                            (block.action!.isError || block.action!.isWarning))
                          DirectorToolCard(
                            key: _blockKey(block, occurrence),
                            step: block.action!,
                          ),
                    ],
                  );
                },
              ),
            ),
          ),
      ],
    );

    if (widget.live) return body;

    // 历史轮：展开/收起做一次固定时长的高度动画（内容固定，无抖动风险）
    return AnimatedSize(
      duration: LmMotion.reducedMotion(context) ? Duration.zero : LmMotion.base,
      curve: LmMotion.easeSnap,
      alignment: Alignment.topCenter,
      child: body,
    );
  }

  /// 组内交错子项（思考块 / 动作卡 / 播报行 / 聚合行，按时间线顺序）
  ///
  /// 键含同类同 step 块的出现序号：交错重组时块位移，Element 状态
  /// （思考展开态/动作卡展开态）跟随键迁移不重置。
  ///
  /// 连续同工具动作 >3 聚合为一行
  /// 「动词 ×N」（opencode ContextToolGroup 式），点开逐卡；含错误步骤的
  /// 段不聚合（错误保持逐卡可见）。
  List<Widget> _interleavedChildren(List<AgentTimelineBlock> timeline) {
    final children = <Widget>[];
    final occurrence = <String, int>{};
    var i = 0;
    while (i < timeline.length) {
      final block = timeline[i];
      if (block.isAction) {
        // 收集连续同工具动作段
        var j = i;
        while (j < timeline.length &&
            timeline[j].isAction &&
            timeline[j].action!.toolName == block.action!.toolName) {
          j++;
        }
        final run = timeline.sublist(i, j);
        // 含失败（红/黄）的段不聚合——失败保持逐卡可见（DD2：可恢复失败
        // 也不该被折叠进「动词 ×N」里）。
        final hasFailure = run.any(
          (b) => b.action!.isError || b.action!.isWarning,
        );
        if (run.length > 3 && !hasFailure) {
          children.add(
            _AggregatedActionsRow(
              key: _runKey(run, occurrence),
              steps: [for (final b in run) b.action!],
            ),
          );
        } else {
          for (final b in run) {
            children.add(
              DirectorToolCard(key: _blockKey(b, occurrence), step: b.action!),
            );
          }
        }
        i = j;
        continue;
      }
      final child = switch (block.kind) {
        AgentTimelineKind.thinking => _GroupThinkingToggle(
            key: _blockKey(block, occurrence),
            content: block.text,
            duration: block.duration,
            // 末块直播中且正文未接管流式焦点：默认展开，流结束自动收起
            live: widget.live &&
                !widget.textStreaming &&
                i == timeline.length - 1,
          ),
        AgentTimelineKind.action => DirectorToolCard(
            key: _blockKey(block, occurrence),
            step: block.action!,
          ),
        AgentTimelineKind.narration => _NarrationLine(
            key: _blockKey(block, occurrence),
            text: block.text,
          ),
      };
      children.add(child);
      i++;
    }
    return children;
  }

  /// 聚合行键：首块键 + 出现序（同段重建时状态迁移）。
  /// ②：键不含段长——live 期间同工具第 5 次调用到达
  /// 使段 4→5，旧键随段长变化导致 Element 重建、用户刚展开的态被重置。
  Key _runKey(List<AgentTimelineBlock> run, Map<String, int> occurrence) {
    final first = run.first;
    final base = first.action!.callId.isNotEmpty
        ? 'agg-${first.action!.toolName}-${first.action!.callId}'
        : 'agg-${first.action!.toolName}-${first.stepIndex}';
    final nth = occurrence.putIfAbsent(base, () => 0);
    occurrence[base] = nth + 1;
    return ValueKey('$base-$nth');
  }

  /// 交错时间线的稳定键：动作卡用 callId（同轮唯一）；文本/思考块用
  /// kind + stepIndex + 同键出现序
  Key _blockKey(AgentTimelineBlock block, Map<String, int> occurrence) {
    if (block.isAction && block.action!.callId.isNotEmpty) {
      return ValueKey('tool-${block.action!.callId}');
    }
    final base = '${block.kind.name}-${block.stepIndex}';
    final nth = occurrence.putIfAbsent(base, () => 0);
    occurrence[base] = nth + 1;
    return ValueKey('$base-$nth');
  }

  /// 标题文本色：预算占用 ≥80%（且 live 有预算数据）转警示色，否则 muted
  Color _headlineColor(LmPalette colors) {
    final progress = widget.progress;
    if (widget.live && progress != null && progress.budgetRatio >= 0.8) {
      return colors.warning;
    }
    return colors.muted;
  }

  /// 秒数 → m:ss（≥1h 转_h:mm:ss）
  static String _formatClock(int totalSeconds) {
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    final mm = minutes.toString().padLeft(2, '0');
    final ss = seconds.toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$mm:$ss' : '$minutes:$ss';
  }

  String _headline(
    List<AgentWorkStep> actions,
    int thinkingSegments,
    Translations t,
  ) {
    if (widget.live) {
      // 纯思考直播（尚无动作块）：用心跳文案占位（对齐空态呼吸标签口径）
      if (actions.isEmpty) {
        return t.advanced.heartbeat.composing;
      }
      // 进行中：以最新的 running（或最后一步）动词为准，原地更新不跳动
      //（修复保留：running 步骤带进度文本时优先展示）
      final runningIndex = actions.lastIndexWhere((s) => s.isRunning);
      final anchorIndex = runningIndex >= 0 ? runningIndex : actions.length - 1;
      final anchor = actions[anchorIndex];
      final verb = anchor.isRunning && anchor.title.isNotEmpty
          ? anchor.title
          : stageVerbOf(anchor.toolName, t);
      // 有预算快照时升级为「第 N/M 步 · 已用 X:XX · 正在…」
      //（步号与 maxSteps 同为 LLM 循环步单位；无数据走旧口径兼容）
      final progress = widget.progress;
      if (progress != null) {
        final elapsed = _formatClock(_elapsedSeconds);
        if (progress.maxSteps > 0) {
          return t.advanced.process.workingStepBudget(
            step: progress.currentStep,
            maxSteps: progress.maxSteps,
            elapsed: elapsed,
            verb: verb,
          );
        }
        return t.advanced.process.workingStepElapsed(
          step: progress.currentStep,
          elapsed: elapsed,
          verb: verb,
        );
      }
      if (runningIndex >= 0) {
        return t.advanced.process.workingStep(
          verb: verb,
          step: runningIndex + 1,
        );
      }
      return t.advanced.process.working(verb: verb);
    }

    final summary = widget.summary;
    final seconds = summary != null && summary.durationMs >= 1000
        ? (summary.durationMs / 1000).round()
        : null;
    if (seconds == null) {
      return t.advanced.process.groupIdle(
        steps: actions.length,
        segments: thinkingSegments,
      );
    }
    return t.advanced.process.groupIdleWithTime(
      steps: actions.length,
      segments: thinkingSegments,
      seconds: seconds,
    );
  }
}

/// 同类动作聚合行——连续同工具 >3 折叠为一行「动词 ×N」
///
/// 收起态单行 caption（点击展开逐卡）；展开态渲染原样 [DirectorToolCard]
/// 列表。错误步骤不进聚合（由调用方保证），聚合行恒为成功/混合成功段。
class _AggregatedActionsRow extends StatefulWidget {
  const _AggregatedActionsRow({required this.steps, super.key});

  final List<AgentWorkStep> steps;

  @override
  State<_AggregatedActionsRow> createState() => _AggregatedActionsRowState();
}

class _AggregatedActionsRowState extends State<_AggregatedActionsRow> {
  var _expanded = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    if (_expanded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ①：补收起行——此前展开后无收起钮，只能
          // 收整个幕后组。
          InkWell(
            key: const ValueKey('aggregated-actions-collapse'),
            onTap: () => setState(() => _expanded = false),
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.only(bottom: IntermediateSpacing.sXs),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.layers_outlined, size: 13, color: colors.faint),
                  const SizedBox(width: IntermediateSpacing.sXs),
                  Text(
                    t.advanced.process.aggregatedActions(
                      verb: stageVerbOf(widget.steps.first.toolName, t),
                      count: widget.steps.length,
                    ),
                    style: IntermediateTextStyles.caption.copyWith(
                      color: colors.muted,
                    ),
                  ),
                  Icon(Icons.expand_less, size: 14, color: colors.faint),
                ],
              ),
            ),
          ),
          for (final (i, step) in widget.steps.indexed)
            // ③：system 留痕步 callId 默认 ''，同段
            // >3 个空 callId 展开时构成重复键（Flutter 断言/元素错配）——
            // 空 callId 回退序号键。
            DirectorToolCard(
              key: step.callId.isNotEmpty
                  ? ValueKey(step.callId)
                  : ValueKey('agg-step-${step.stepIndex}-$i'),
              step: step,
            ),
        ],
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: IntermediateSpacing.sSm),
      child: InkWell(
        key: const ValueKey('aggregated-actions-toggle'),
        onTap: () => setState(() => _expanded = true),
        borderRadius: BorderRadius.circular(6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.layers_outlined, size: 13, color: colors.faint),
            const SizedBox(width: IntermediateSpacing.sXs),
            Text(
              t.advanced.process.aggregatedActions(
                verb: stageVerbOf(widget.steps.first.toolName, t),
                count: widget.steps.length,
              ),
              style: IntermediateTextStyles.caption.copyWith(
                color: colors.muted,
              ),
            ),
            Icon(Icons.expand_more, size: 14, color: colors.faint),
          ],
        ),
      ),
    );
  }
}

/// 思考块折叠行（时长标题口径：「思考 · 持续 N 秒」，无起止数据回退字数）
///
/// 收起态一行 caption；展开显示内容。live = 正在流式的末块：默认展开，
/// 流结束（live→false）自动收起一次；用户手动展开后不再干预（同既有
/// 直播思考行行为）。
class _GroupThinkingToggle extends StatefulWidget {
  const _GroupThinkingToggle({
    required this.content,
    this.duration,
    this.live = false,
    super.key,
  });

  final String content;
  final Duration? duration;
  final bool live;

  @override
  State<_GroupThinkingToggle> createState() => _GroupThinkingToggleState();
}

class _GroupThinkingToggleState extends State<_GroupThinkingToggle> {
  var _expanded = false;
  var _autoCollapsePending = false;

  @override
  void initState() {
    super.initState();
    _expanded = widget.live && widget.content.isNotEmpty;
    _autoCollapsePending = widget.live;
  }

  @override
  void didUpdateWidget(_GroupThinkingToggle oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.live && widget.live) {
      // 新一段思考开始直播：重新默认展开
      _expanded = true;
      _autoCollapsePending = true;
    } else if (oldWidget.live &&
        !widget.live &&
        _autoCollapsePending &&
        _expanded) {
      _expanded = false;
      _autoCollapsePending = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    final title = widget.duration != null && widget.duration!.inSeconds > 0
        ? t.advanced.process.thinkingDuration(
            seconds: widget.duration!.inSeconds,
          )
        : t.advanced.live.thinkingCount(count: widget.content.length);
    return Padding(
      padding: const EdgeInsets.only(bottom: IntermediateSpacing.sSm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _expanded ? Icons.expand_more : Icons.chevron_right,
                  size: 14,
                  color: colors.faint,
                ),
                const SizedBox(width: IntermediateSpacing.s2xs),
                Text(
                  title,
                  style: IntermediateTextStyles.caption.copyWith(
                    color: colors.faint,
                  ),
                ),
              ],
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.only(
                left: IntermediateSpacing.sLg,
                top: IntermediateSpacing.s2xs,
              ),
              // （R1）：思考流式增长文本接共享淡入载体
              // pace：直连载体的流式面自行配速。
              child: StreamingFadeText(
                data: widget.content,
                pace: true,
                style: IntermediateTextStyles.caption.copyWith(
                  color: colors.muted,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 播报行（导演对用户说的话）：无框弱化呈现
///
/// （区分只在容器）→ 升级：
/// 播报与正文同字体同字号在长稿件流里难以一眼分辨，改为小一号（fontScale
/// 0.875）+ 左侧细竖线 + 前缀图标；「常显不折叠」语义不变，折叠组整体
/// 收起时随组收起。渲染仍复用正文 Markdown 组件（星号等标记行为一致）。
class _NarrationLine extends StatelessWidget {
  const _NarrationLine({required this.text, super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: IntermediateSpacing.sSm),
      child: Semantics(
        label: t.advanced.process.narrationLabel,
        child: Container(
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: colors.divider, width: 2),
            ),
          ),
          padding: const EdgeInsets.only(left: IntermediateSpacing.sSm),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(
                  Icons.record_voice_over_outlined,
                  size: 12,
                  color: colors.faint,
                ),
              ),
              const SizedBox(width: IntermediateSpacing.sXs),
              Expanded(
                child: context.lmUi.markdownBody(
                  context,
                  narrative: true,
                  data: text,
                  fontScale: 0.875,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 请求重试等待状态条
///
/// agent_runner 退避/Retry-After 等待期间渲染于幕后折叠组上方：单行
/// 「限流等待中 · Ns 后第 k 次重试」，倒计时部分微光扫过（reduced-motion
/// 下静止）。倒计时以事件到达时刻为锚（[AgentRetryWait.scheduledAtMs]），
/// 不自行起表；等待结束由下一个 AgentStepStarted 撤下本行。
class AgentRetryWaitRow extends StatefulWidget {
  const AgentRetryWaitRow({required this.wait, super.key});

  final AgentRetryWait wait;

  @override
  State<AgentRetryWaitRow> createState() => _AgentRetryWaitRowState();
}

class _AgentRetryWaitRowState extends State<AgentRetryWaitRow> {
  Timer? _ticker;

  /// 首帧时刻与事件到达锚点的时差（真实时钟只在 initState 读一次；
  /// 倒计时推进由 tick 计数驱动——widget 测试的 fake clock 只走 Timer，
  /// build 期读 DateTime.now() 拿不到推进后的时间）。
  late final int _anchorLagMs;

  int _ticks = 0;

  @override
  void initState() {
    super.initState();
    final lag =
        DateTime.now().millisecondsSinceEpoch - widget.wait.scheduledAtMs;
    _anchorLagMs = lag > 0 ? lag : 0;
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      // 剩余归零后停表：等待结束行即被撤下，防御事件时序偏差下的常驻滴答
      if (_remainingMs() <= 0) {
        _ticker?.cancel();
        return;
      }
      _ticks++;
      setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  /// 以事件锚点 + 首帧时差 + tick 计数推算当前剩余毫秒
  int _remainingMs() => widget.wait
      .remainingMs(widget.wait.scheduledAtMs + _anchorLagMs + _ticks * 1000);

  /// 语义码 → 人话原因词（批 F；映射源 RetryWaitReason）
  static String _reasonText(String? cause, Translations t) {
    switch (RetryWaitReason.of(cause)) {
      case RetryWaitReason.rateLimited:
        return t.advanced.retryReasonRateLimited;
      case RetryWaitReason.serverError:
        return t.advanced.retryReasonServer;
      case RetryWaitReason.timeout:
        return t.advanced.retryReasonTimeout;
      case RetryWaitReason.streamInterrupted:
        return t.advanced.retryReasonStream;
      case RetryWaitReason.badResponse:
        return t.advanced.retryReasonBadResponse;
      case RetryWaitReason.unknown:
        return t.advanced.retryWaitingBadge;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    final remainingSeconds = (_remainingMs() / 1000).ceil();
    final caption = IntermediateTextStyles.caption.copyWith(
      color: colors.muted,
    );
    final max = widget.wait.maxAttempts;
    // 批 F：「原因 · Xs 后第 k/N 次」——maxAttempts 未知时退回旧两段式
    final progress = max != null
        ? t.advanced.retryWaitingProgress(
            reason: _reasonText(widget.wait.cause, t),
            attempt: widget.wait.attempt,
            max: max,
            seconds: remainingSeconds,
          )
        : t.advanced.retryWaitingCountdown(
            seconds: remainingSeconds,
            attempt: widget.wait.attempt,
          );
    return Semantics(
      liveRegion: true,
      child: Row(
        children: [
          Icon(Icons.hourglass_top, size: 14, color: colors.muted),
          const SizedBox(width: IntermediateSpacing.sXs),
          Expanded(
            child: ShimmerText(progress, style: caption),
          ),
        ],
      ),
    );
  }
}
