import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_spacing.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_text_styles.dart';
import 'package:lmstory/core/theme/shared/components/lm_activity_dots.dart';
import 'package:lmstory/core/theme/shared/components/lm_state_transition.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_work_step.dart';
import 'package:lmstory/features/advanced/presentation/widgets/director_tool_card.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 导演模式 L1 过程汇总行（体验重构 §4.3.1，剧场语言为表）
///
/// 一轮一条，置于该轮正文块上方。收起态一行 muted caption：
/// - 进行中（live）：`正在翻阅前情… · 第 3 步`（随最新 running 步骤原地更新）
/// - 已完成：`幕后 6 步 · 翻阅前情、修订设定集 · 12s`
/// 点击展开 L2 审计层（逐步 [DirectorToolCard]）。
///
/// 例外：error 步骤不折叠——收起态下失败步骤卡直接平铺在汇总行下方
/// 常显（opencode"隐藏成功工具，只留失败与进行中"）。
///
/// 展开动画：历史轮（内容已固定）用 200ms ease-out-quart 高度动画；
/// 进行中轮不做高度动画（步骤追加时布局原地增长，避免流式态抖动）。
class DirectorProcessRow extends StatefulWidget {
  const DirectorProcessRow({
    required this.steps,
    this.summary,
    this.live = false,
    super.key,
  });

  final List<AgentWorkStep> steps;

  /// 历史轮工作摘要（步数/token/总时长）；live 轮为 null
  final AgentWorkSummary? summary;

  /// 是否进行中轮（控制进行中文案与展开动画策略）
  final bool live;

  @override
  State<DirectorProcessRow> createState() => _DirectorProcessRowState();
}

class _DirectorProcessRowState extends State<DirectorProcessRow> {
  var _expanded = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    final steps = widget.steps;
    if (steps.isEmpty) return const SizedBox.shrink();

    final hasError = steps.any((s) => s.isError);
    final hasWarning = steps.any((s) => s.isWarning);
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
                LmStateTransition(
                  stateKey: (widget.live, steps.last.status),
                  child: widget.live
                      ? LmActivityDots(color: colors.primary, dotSize: 4)
                      : Icon(
                          _expanded ? Icons.tungsten : Icons.tungsten_outlined,
                          size: 14,
                          color: iconColor,
                        ),
                ),
                const SizedBox(width: IntermediateSpacing.sSm),
                Expanded(
                  child: LmStateTransition(
                    stateKey: (
                      widget.live,
                      steps.last.callId,
                      steps.last.status
                    ),
                    child: Text(
                      _headline(steps, widget.summary, widget.live, t),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: IntermediateTextStyles.caption.copyWith(
                        color: colors.muted,
                      ),
                    ),
                  ),
                ),
                Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: 16,
                  color: colors.faint,
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
                  for (final step in steps) DirectorToolCard(step: step),
                ],
              ),
            ),
          )
        else
          // 收起态：失败步骤常显（不藏进 L2）
          Padding(
            padding: const EdgeInsets.only(top: IntermediateSpacing.s2xs),
            child: RepaintBoundary(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final step in steps)
                    if (step.isError || step.isWarning)
                      DirectorToolCard(step: step),
                ],
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

  String _headline(
    List<AgentWorkStep> steps,
    AgentWorkSummary? summary,
    bool live,
    Translations t,
  ) {
    if (live) {
      // 进行中：以最新的 running（或最后一步）动词为准，原地更新不跳动。
      //  修复：running 步骤带进度文本（工具 onProgress）时
      // 优先展示——"正在检索「xxx」… · 第 N 步"。
      final runningIndex = steps.lastIndexWhere((s) => s.isRunning);
      final anchorIndex = runningIndex >= 0 ? runningIndex : steps.length - 1;
      final anchor = steps[anchorIndex];
      final verb = anchor.isRunning && anchor.title.isNotEmpty
          ? anchor.title
          : stageVerbOf(anchor.toolName, t);
      if (runningIndex >= 0) {
        return t.advanced.process.workingStep(
          verb: verb,
          step: runningIndex + 1,
        );
      }
      return t.advanced.process.working(verb: verb);
    }

    final verbs = _verbSummary(steps, t);
    final seconds = summary != null && summary.durationMs >= 1000
        ? (summary.durationMs / 1000).round()
        : null;
    if (seconds == null) {
      return t.advanced.process.idle(steps: steps.length, verbs: verbs);
    }
    return t.advanced.process.idleWithTime(
      steps: steps.length,
      verbs: verbs,
      seconds: seconds,
    );
  }

  /// 舞台动词串（相邻去重保序，超长截断）
  String _verbSummary(List<AgentWorkStep> steps, Translations t) {
    final verbs = <String>[];
    for (final step in steps) {
      final verb = stageVerbOf(step.toolName, t);
      if (verbs.isEmpty || verbs.last != verb) verbs.add(verb);
    }
    final joined = verbs.join('、');
    if (joined.length > 16) return '${joined.substring(0, 16)}…';
    return joined;
  }
}
