import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/agent/agent_message.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/shared/components/labeled_value.dart';
import 'package:lmstory/core/theme/shared/components/panel_heading.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/system/lm_layout.dart';
import 'package:lmstory/core/theme/system/lm_narrative_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/advanced/presentation/controllers/agent_round_trace_controller.dart';
import 'package:lmstory/features/advanced/presentation/widgets/director_tool_card.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 导演轮轨迹页
///
/// 按会话+轮从事件日志重建三层视图：
/// ①轮摘要（结果/步数/token/结束原因）②步时间线（工具/耗时/成败）
/// ③单步点开展开完整请求消息序列与响应全文（点击才计算）。
/// 纯只读，不改任何会话状态。
///
/// 技术遥测标签为英文字面量（同控制器的既定取舍），页面级文案入
/// slang；：事件日志被滚动保留裁剪后，页头加裁剪标注（slang：
/// advanced.roundTrace.trimmedNotice），说明更早轮的重建请求不完整。
class AgentRoundTracePage extends ConsumerWidget {
  const AgentRoundTracePage({
    required this.sessionId,
    required this.turnNumber,
    super.key,
  });

  final String sessionId;
  final int turnNumber;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Translations.of(context);
    final state = ref.watch(
      agentRoundTraceControllerProvider(
        (sessionId: sessionId, turnNumber: turnNumber),
      ),
    );

    return Scaffold(
      backgroundColor: context.scaffoldBgOf(context.lm.palette.bg),
      appBar: context.lmUi.appBar(
        context,
        title: t.settings.diagnostics.roundTrace.title(turnNumber: turnNumber),
      ),
      body: LmMeasure(
        child: state.isLoading
            ? const Center(child: CircularProgressIndicator())
            : state.error != null
                ? _ErrorView(error: state.error!)
                : ListView(
                    padding: const EdgeInsets.all(SimpleSpacing.sLg),
                    children: [
                      // 日志起点晚于轮 1 = 早期轮已被保留策略裁掉，
                      // 重建请求序列对早期 kept 轮会短于真实请求，必须明示
                      if ((state.firstAvailableTurn ?? 1) > 1)
                        Padding(
                          padding: const EdgeInsets.only(
                            bottom: SimpleSpacing.sMd,
                          ),
                          child: _TrimNotice(
                            firstTurn: state.firstAvailableTurn!,
                          ),
                        ),
                      if (state.summary != null)
                        _SummaryCard(summary: state.summary!)
                      else
                        const _EmptyView(),
                      const SizedBox(height: SimpleSpacing.sMd),
                      for (final step in state.steps)
                        Padding(
                          padding: const EdgeInsets.only(
                            bottom: SimpleSpacing.sSm,
                          ),
                          child: _StepCard(
                            step: step,
                            state: state,
                            sessionId: sessionId,
                            turnNumber: turnNumber,
                          ),
                        ),
                      const SizedBox(height: SimpleSpacing.sXl),
                    ],
                  ),
      ),
    );
  }
}

/// 事件日志裁剪标注（保留窗外的轮不再出现在日志中）
class _TrimNotice extends StatelessWidget {
  const _TrimNotice({required this.firstTurn});

  final int firstTurn;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    return context.lmUi.card(
      context,
      padding: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(SimpleSpacing.sMd),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.history_toggle_off, size: 16, color: colors.muted),
            const SizedBox(width: SimpleSpacing.sSm),
            Expanded(
              child: Text(
                Translations.of(context)
                    .advanced
                    .roundTrace
                    .trimmedNotice(count: firstTurn),
                style: TextStyle(fontSize: 14, color: colors.muted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyView extends StatelessWidget {
  const _EmptyView();

  @override
  Widget build(BuildContext context) {
    return context.lmUi.card(
      context,
      padding: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(SimpleSpacing.sLg),
        child: Text(
          Translations.of(context).settings.diagnostics.roundTrace.noEvents,
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error});

  final String error;

  @override
  Widget build(BuildContext context) {
    return context.lmUi.card(
      context,
      padding: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(SimpleSpacing.sLg),
        child: Text(
          Translations.of(
            context,
          ).settings.diagnostics.roundTrace.loadFailed(error: error),
        ),
      ),
    );
  }
}

/// ①轮摘要
class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.summary});

  final AgentTurnTraceSummary summary;

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;
    final duration = summary.durationMs;
    return context.lmUi.card(
      context,
      padding: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(SimpleSpacing.sLg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            PanelHeading(title: t.settings.diagnostics.roundTrace.turnSummary),
            const SizedBox(height: SimpleSpacing.sSm),
            _kv('reason', summary.reason ?? 'unknown'),
            _kv('steps', '${summary.steps}'),
            _kv(
              'tokens',
              // ignore: no_adjacent_strings_in_list, 三段拼一行统计
              '${summary.promptTokens} in / '
                  '${summary.completionTokens} out '
                  '(${summary.totalTokens} total)',
            ),
            if (duration != null) _kv('duration', '${duration}ms'),
            if (summary.errorMessage != null)
              Padding(
                padding: const EdgeInsets.only(top: SimpleSpacing.sSm),
                child: Text(
                  summary.errorMessage!,
                  style: TextStyle(color: colors.error, fontSize: 14),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _kv(String key, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: SimpleSpacing.sXs),
      child: LabeledValue(label: key, value: value),
    );
  }
}

/// ②步时间线 + ③点开详情
class _StepCard extends ConsumerWidget {
  const _StepCard({
    required this.step,
    required this.state,
    required this.sessionId,
    required this.turnNumber,
  });

  final AgentStepTrace step;
  final AgentRoundTraceState state;
  final String sessionId;
  final int turnNumber;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Translations.of(context);
    final colors = context.lm.palette;
    final detail = state.stepDetails[step.stepIndex];
    final elapsed = step.endMs != null ? step.endMs! - step.beginMs : null;

    return context.lmUi.card(
      context,
      padding: EdgeInsets.zero,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding:
              const EdgeInsets.symmetric(horizontal: SimpleSpacing.sMd),
          childrenPadding: const EdgeInsets.fromLTRB(
            SimpleSpacing.sMd,
            0,
            SimpleSpacing.sMd,
            SimpleSpacing.sMd,
          ),
          title: Text(
            step.label ??
                'Step ${step.stepIndex + 1}'
                    '${step.stopKind != null ? ' · ${step.stopKind}' : ''}'
                    '${elapsed != null ? ' · ${elapsed}ms' : ''}',
            style: LmNarrativeTextStyles.bodyUi,
          ),
          subtitle: (step.tools.isEmpty && step.toolCalls.isEmpty)
              ? null
              : Text(
                  [
                    for (final tool in step.tools)
                      // ignore: no_adjacent_strings_in_list, 两段拼一行工具摘要
                      '${tool.isError ? 'x' : 'ok'} ${tool.toolName}'
                          '${tool.durationMs != null ? ' ${tool.durationMs}ms' : ''}',
                  ].join('  '),
                  style: TextStyle(fontSize: 13, color: colors.muted),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
          onExpansionChanged: (open) {
            if (open) {
              ref
                  .read(
                    agentRoundTraceControllerProvider(
                      (sessionId: sessionId, turnNumber: turnNumber),
                    ).notifier,
                  )
                  .loadStepDetail(step.stepIndex);
            }
          },
          children: [
            if (detail == null)
              const Padding(
                padding: EdgeInsets.all(SimpleSpacing.sSm),
                child: SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else ...[
              _DetailSection(
                title: 'Request (${detail.requestMessages.length} messages)',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var i = 0; i < detail.requestMessages.length; i++)
                      _MessageLine(message: detail.requestMessages[i]),
                  ],
                ),
              ),
              const SizedBox(height: SimpleSpacing.sSm),
              _DetailSection(
                title: 'Response',
                child: SelectableText(
                  detail.responseText.trim().isEmpty
                      ? '(empty)'
                      : detail.responseText.trim(),
                  style: LmNarrativeTextStyles.bodyUi,
                ),
              ),
              for (final tool in detail.toolResults) ...[
                const SizedBox(height: SimpleSpacing.sSm),
                _DetailSection(
                  title:
                      'Tool result · ${tool.toolName}${tool.isError ? ' (error)' : ''}',
                  child: SelectableText(
                    tool.output.isEmpty
                        ? '(empty)'
                        : DirectorToolCard.localizedOutput(tool.output, t),
                    style: TextStyle(
                      fontSize: 13,
                      color: tool.isError ? colors.error : null,
                    ),
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _MessageLine extends StatelessWidget {
  const _MessageLine({required this.message});

  final AgentMessage message;

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;
    final raw = (message.content ?? '').replaceAll('\n', ' ').trim();
    final localized = DirectorToolCard.localizedOutput(raw, t);
    final shown = localized.length > 120
        ? '${localized.substring(0, 120)}…'
        : (localized.isEmpty
            ? message.hasToolCalls
                ? '[${message.toolCalls!.length} tool calls]'
                : '(no text)'
            : localized);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '[${message.role}] ',
              style: TextStyle(
                color: colors.muted,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            TextSpan(
              text: shown,
              style: LmNarrativeTextStyles.bodyUi,
            ),
          ],
        ),
      ),
    );
  }
}

class _DetailSection extends StatelessWidget {
  const _DetailSection({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: LmNarrativeTextStyles.label
              .copyWith(color: context.lm.palette.muted),
        ),
        const SizedBox(height: SimpleSpacing.sXs),
        child,
      ],
    );
  }
}
