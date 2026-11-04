import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/shared/components/panel_heading.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_layout.dart';
import 'package:lmstory/core/theme/system/lm_narrative_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/advanced/domain/services/agent_session_stats.dart';
import 'package:lmstory/features/advanced/presentation/controllers/agent_loop_diagnostics_controller.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// Agent Loop 诊断页（开发者自检入口，非产品 UI）
///
/// 用全局默认对话模型跑一轮最小工具循环（echo → get_current_time →
/// finish_demo），实时展示 turn/step/工具事件时间线，验证：
/// 流式 tool-call 增量、多步循环、预算上限、取消、协议能力降级。
class AgentLoopDiagnosticsPage extends ConsumerStatefulWidget {
  const AgentLoopDiagnosticsPage({super.key});

  @override
  ConsumerState<AgentLoopDiagnosticsPage> createState() =>
      _AgentLoopDiagnosticsPageState();
}

class _AgentLoopDiagnosticsPageState
    extends ConsumerState<AgentLoopDiagnosticsPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => ref.read(agentLoopDiagnosticsControllerProvider.notifier).load(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final state = ref.watch(agentLoopDiagnosticsControllerProvider);
    final colors = context.lm.palette;

    return Scaffold(
      appBar: context.lmUi
          .appBar(context, title: t.settings.diagnostics.agentLoop.title),
      body: LmMeasure(
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(SimpleSpacing.sLg),
                    child: _InfoCard(
                      colors: colors,
                      modelLabel: state.modelLabel,
                      resolveError: state.resolveError,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: SimpleSpacing.sLg,
                    ),
                    child: Wrap(
                      spacing: SimpleSpacing.sSm,
                      runSpacing: SimpleSpacing.sXs,
                      children: [
                        FilledButton.icon(
                          onPressed:
                              state.isRunning || state.resolveError != null
                                  ? null
                                  : () => ref
                                      .read(
                                        agentLoopDiagnosticsControllerProvider
                                            .notifier,
                                      )
                                      .run(),
                          icon: const Icon(Icons.play_arrow),
                          label: Text(t.settings.diagnostics.agentLoop.run),
                        ),
                        OutlinedButton.icon(
                          onPressed: state.isRunning
                              ? () => ref
                                  .read(
                                    agentLoopDiagnosticsControllerProvider
                                        .notifier,
                                  )
                                  .cancel()
                              : null,
                          icon: const Icon(Icons.stop),
                          label: Text(t.settings.diagnostics.agentLoop.cancel),
                        ),
                      ],
                    ),
                  ),
                  if (state.summary != null)
                    Padding(
                      padding: const EdgeInsets.all(SimpleSpacing.sLg),
                      child: _SummaryCard(
                        colors: colors,
                        summary: state.summary!,
                      ),
                    ),
                  // 会话级聚合卡（durable 事件流懒计算；状态文案入 slang，
                  // 密集遥测统计行保留英文字面量）
                  const _SessionAggregateCard(),
                ],
              ),
            ),
            if (state.entries.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Padding(
                  padding: const EdgeInsets.all(SimpleSpacing.sLg),
                  child: Center(
                    child: Text(
                      state.isRunning
                          ? t.settings.diagnostics.agentLoop.running
                          : t.settings.diagnostics.agentLoop.empty,
                      style:
                          SimpleTextStyles.bodySm.copyWith(color: colors.muted),
                    ),
                  ),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.all(SimpleSpacing.sLg),
                sliver: SliverList.builder(
                  itemCount: state.entries.length,
                  itemBuilder: (context, index) =>
                      _EventRow(colors: colors, entry: state.entries[index]),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.colors,
    required this.modelLabel,
    required this.resolveError,
  });

  final LmPalette colors;
  final String modelLabel;
  final String? resolveError;

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    return context.lmUi.card(
      context,
      padding: const EdgeInsets.all(SimpleSpacing.sMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PanelHeading(title: t.settings.diagnostics.agentLoop.descTitle),
          const SizedBox(height: SimpleSpacing.sXs),
          Text(
            t.settings.diagnostics.agentLoop.desc,
            style: SimpleTextStyles.bodySm.copyWith(color: colors.muted),
          ),
          const SizedBox(height: SimpleSpacing.sSm),
          Text(
            resolveError ??
                (modelLabel.isEmpty
                    ? t.settings.diagnostics.agentLoop.loading
                    : '${t.settings.diagnostics.agentLoop.model}: $modelLabel'),
            style: SimpleTextStyles.bodySm.copyWith(
              color: resolveError != null ? colors.error : null,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.colors, required this.summary});

  final LmPalette colors;
  final String summary;

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(SimpleSpacing.sMd),
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
      ),
      child: Text(
        '${t.settings.diagnostics.agentLoop.summary}: $summary',
        style: SimpleTextStyles.bodySm,
      ),
    );
  }
}

///  会话级聚合卡：选一个导演会话 → 读 durable 事件 → 懒计算聚合
///
/// 步数分布 / 工具失败率（按工具分）/ token 分布 / 缓存命中率趋势。
/// 数据与轮轨迹页同源（agent_event_log_repository.readEvents）。
class _SessionAggregateCard extends ConsumerStatefulWidget {
  const _SessionAggregateCard();

  @override
  ConsumerState<_SessionAggregateCard> createState() =>
      _SessionAggregateCardState();
}

class _SessionAggregateCardState extends ConsumerState<_SessionAggregateCard> {
  List<ChatSession>? _sessions;
  ChatSession? _selected;
  AgentSessionStats? _stats;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadSessions());
  }

  Future<void> _loadSessions() async {
    try {
      final sessions = await ref.read(chatRepositoryProvider).getAllSessions();
      if (!mounted) return;
      setState(() {
        _sessions = sessions.where((s) => s.mode == 'advanced').toList()
          ..sort((a, b) => b.lastActiveAt.compareTo(a.lastActiveAt));
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sessions = const [];
        _error = '$e';
      });
    }
  }

  Future<void> _aggregate(ChatSession session) async {
    setState(() {
      _selected = session;
      _loading = true;
      _error = null;
      _stats = null;
    });
    try {
      // 散建收口——统一读组合根 provider
      final events = await ref
          .read(agentEventLogRepositoryProvider)
          .readEvents(session.sessionId);
      if (!mounted) return;
      setState(() {
        _stats = agentSessionStatsFrom(events);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;
    final sessions = _sessions;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SimpleSpacing.sLg,
        SimpleSpacing.sSm,
        SimpleSpacing.sLg,
        SimpleSpacing.sSm,
      ),
      child: context.lmUi.card(
        context,
        padding: const EdgeInsets.all(SimpleSpacing.sMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            PanelHeading(
              title: t.settings.diagnostics.agentLoop.sessionAggregate,
            ),
            const SizedBox(height: SimpleSpacing.sXs),
            if (sessions == null)
              Text(
                t.settings.diagnostics.agentLoop.loadingSessions,
                style: SimpleTextStyles.bodySm.copyWith(color: colors.muted),
              )
            else if (sessions.isEmpty)
              Text(
                t.settings.diagnostics.agentLoop.noSessions,
                style: SimpleTextStyles.bodySm.copyWith(color: colors.muted),
              )
            else
              DropdownButton<ChatSession>(
                isExpanded: true,
                itemHeight: null,
                style: DefaultTextStyle.of(context).style.merge(
                      LmNarrativeTextStyles.bodyUi.copyWith(color: colors.ink),
                    ),
                value: _selected != null && sessions.contains(_selected)
                    ? _selected
                    : null,
                hint: Text(t.settings.diagnostics.agentLoop.selectSessionHint),
                items: [
                  for (final session in sessions)
                    DropdownMenuItem(
                      value: session,
                      child: Text(
                        session.title.isEmpty
                            ? session.sessionId.substring(
                                0,
                                session.sessionId.length.clamp(0, 12),
                              )
                            : session.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (session) {
                  if (session != null) _aggregate(session);
                },
              ),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(SimpleSpacing.sSm),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (_error != null)
              Text(
                t.settings.diagnostics.agentLoop.errorLine(error: _error!),
                style: SimpleTextStyles.bodySm.copyWith(color: colors.error),
              ),
            if (_stats != null) _StatsBody(colors: colors, stats: _stats!),
          ],
        ),
      ),
    );
  }
}

class _StatsBody extends StatelessWidget {
  const _StatsBody({required this.colors, required this.stats});

  final LmPalette colors;
  final AgentSessionStats stats;

  @override
  Widget build(BuildContext context) {
    final stepsLine = stats.stepsByTurn.isEmpty
        ? '-'
        : stats.stepsByTurn.entries
            .map((e) => 'T${e.key}:${e.value}')
            .join('  ');
    final toolLines = stats.toolStats.isEmpty
        ? const <Widget>[]
        : [
            for (final entry in stats.toolStats.entries)
              Text(
                '${entry.key}: ${entry.value.calls} calls'
                '${entry.value.errors > 0 ? ' · ${entry.value.errors} failed (${(entry.value.failureRate * 100).toStringAsFixed(0)}%)' : ''}',
                style: SimpleTextStyles.bodySm.copyWith(color: colors.ink),
              ),
          ];
    final hitRate = stats.weightedCacheHitRate;
    String percent(double? rate, int fractionDigits) =>
        rate == null ? '-' : '${(rate * 100).toStringAsFixed(fractionDigits)}%';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: SimpleSpacing.sMd),
        Text(
          'turns: ${stats.turns} · steps: ${stats.steps}',
          style: SimpleTextStyles.bodySm.copyWith(color: colors.ink),
        ),
        const SizedBox(height: SimpleSpacing.sXs),
        Text(
          'steps/turn: $stepsLine',
          style: SimpleTextStyles.bodySm.copyWith(color: colors.muted),
        ),
        const SizedBox(height: SimpleSpacing.sXs),
        Text(
          'tokens: prompt ${stats.promptTokens} · completion ${stats.completionTokens}'
          ' · cacheRead ${stats.cacheReadTokens} · cacheCreation ${stats.cacheCreationTokens}',
          style: SimpleTextStyles.bodySm.copyWith(color: colors.muted),
        ),
        const SizedBox(height: SimpleSpacing.sXs),
        Text(
          'cache hit: ${hitRate == null ? 'n/a' : percent(hitRate, 1)}',
          style: SimpleTextStyles.bodySm.copyWith(color: colors.ink),
        ),
        if (stats.cacheTrend.isNotEmpty) ...[
          const SizedBox(height: SimpleSpacing.sXs),
          Text(
            'cache trend: ${stats.cacheTrend.map((p) => 'T${p.turn} ${percent(p.hitRate, 0)}').join('  ')}',
            style: SimpleTextStyles.bodySm.copyWith(color: colors.muted),
          ),
        ],
        if (toolLines.isNotEmpty) ...[
          const SizedBox(height: SimpleSpacing.sSm),
          Text(
            Translations.of(
              context,
            ).settings.diagnostics.agentLoop.toolsLabel,
            style: SimpleTextStyles.bodySm,
          ),
          ...toolLines,
        ],
      ],
    );
  }
}

class _EventRow extends StatelessWidget {
  const _EventRow({required this.colors, required this.entry});

  final LmPalette colors;
  final AgentDiagnosticEntry entry;

  @override
  Widget build(BuildContext context) {
    const styles = SimpleTextStyles.bodySm;
    final isError = entry.isError;
    return Container(
      margin: const EdgeInsets.only(bottom: SimpleSpacing.sXs),
      padding: const EdgeInsets.all(SimpleSpacing.sSm),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
        border: Border.all(
          color: isError ? colors.error.withValues(alpha: 0.5) : colors.divider,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            entry.text,
            style: styles.copyWith(
              fontWeight: FontWeight.w600,
              color: isError ? colors.error : colors.ink,
            ),
          ),
          if (entry.detail != null && entry.detail!.isNotEmpty) ...[
            const SizedBox(height: SimpleSpacing.sXs),
            Text(
              entry.detail!,
              style: styles.copyWith(
                fontFamily: 'LMMono',
                fontSize: 13,
                height: 1.6,
                color: colors.muted,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}
