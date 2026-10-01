import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/intermediate/components/facts_change_detail_dialog.dart';
import 'package:lmstory/core/theme/intermediate/components/history_panel_shell.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_spacing.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/memory/domain/entities/facts_change_record.dart';
import 'package:lmstory/features/memory/domain/entities/facts_delta.dart';
import 'package:lmstory/features/memory/domain/services/fact_context_builder.dart';
import 'package:lmstory/features/story_runtime/domain/entities/round_artifacts.dart';
import 'package:lmstory/features/story_runtime/domain/entities/story_phase_models.dart';
import 'package:lmstory/features/story_runtime/presentation/pages/memory_browser_page.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 事实层变更小窗（DOC-11 §4 配套，2026-08-13 新增）。
///
/// 位于「本轮摘要小窗」之后，展示本轮事实层的新增/更新/追加/移除/别名/归档。
/// 与 SummarizePanel 同级样式（surfaceElevated 底、rMd 圆角、muted 箭头）。
///
/// 状态映射：
/// - summarizing：加载提示「正在更新事实...」（事实与摘要同在 summarizing
///   阶段产出，此时 oldValue 未知，显示「应用中」）
/// - 完成（idle/persisting）：折叠行「事实已更新 · N 项」，展开后逐条变更；
///   点击单条弹出 [FactsChangeDetailDialog] 查看变更前/变更后
/// - 空列表：明确无事实变更时显示「本轮无事实变更」占位（不隐藏卡片，
///   区别于摘要小窗的无数据即隐藏）
/// - 失败：灰度滤镜（与 SummarizePanel 失败态一致）
/// - 历史态（[artifacts] != null）：用 [HistoryPanelShell] 渲染
///
/// 数据源：实时态从 [factsChanges]（state.currentFactsChanges，oldValue 为 null
/// 的「应用中」预览）读取；历史/完成态从 `artifacts.factsChanges`（含完整
/// 变更前/变更后）读取。
class FactsChangePanel extends StatefulWidget {
  const FactsChangePanel({
    required this.phase,
    required this.failureContext,
    required this.factsChanges,
    this.foldDelayMs = 1000,
    this.artifacts,
    this.similarNameCandidates,
    this.session,
    super.key,
  });

  final IntermediatePhase phase;
  final FailureContext? failureContext;

  /// 实时态数据源（state.currentFactsChanges）。历史态忽略。
  final List<FactsChangeRecord>? factsChanges;

  /// 自动折叠延迟（与 SummarizePanel 共用时序）。
  final int foldDelayMs;

  /// 历史快照（非 null 时进入历史态，从 artifacts.factsChanges 读取）。
  final StoryRoundArtifacts? artifacts;

  /// 本轮 create_entity 的疑似重复候选（实时态专用，
  /// 展开后逐条「疑似重复」行，点击进记忆库归并预选）
  final List<SimilarNameCandidate>? similarNameCandidates;

  /// 疑似重复跳转记忆库所需的会话（null = 不提供跳转）
  final ChatSession? session;

  @override
  State<FactsChangePanel> createState() => _FactsChangePanelState();
}

class _FactsChangePanelState extends State<FactsChangePanel> {
  bool _expanded = false;
  Timer? _autoFoldTimer;
  bool _hasAutoFolded = false;
  int _foldRetryCount = 0;
  static const int _maxFoldRetries = 2;

  bool get _isApplying =>
      widget.phase == IntermediatePhase.summarizing ||
      widget.phase == IntermediatePhase.summarizingRetry;
  bool get _isFailed =>
      widget.phase == IntermediatePhase.failed &&
      widget.failureContext?.failedPhase == IntermediatePhase.summarizing;
  bool get _isCompleted => !_isApplying && !_isFailed;

  /// 当前数据源（历史态优先 artifacts，否则实时 factsChanges）
  List<FactsChangeRecord> get _changes {
    if (widget.artifacts != null) return widget.artifacts!.factsChanges;
    return widget.factsChanges ?? const [];
  }

  @override
  void didUpdateWidget(covariant FactsChangePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final wasIdleOrFailed = oldWidget.phase == IntermediatePhase.idle ||
        oldWidget.phase == IntermediatePhase.failed;
    if (wasIdleOrFailed && _isApplying) {
      _hasAutoFolded = false;
      _expanded = false;
      _autoFoldTimer?.cancel();
      _autoFoldTimer = null;
    }
    final wasApplying = oldWidget.phase == IntermediatePhase.summarizing ||
        oldWidget.phase == IntermediatePhase.summarizingRetry;
    if (wasApplying && _isCompleted && !_hasAutoFolded && _changes.isNotEmpty) {
      _expanded = true;
      _foldRetryCount = 0;
      _autoFoldTimer?.cancel();
      if (widget.foldDelayMs <= 0) {
        _hasAutoFolded = true;
        _expanded = false;
      } else if (widget.phase == IntermediatePhase.idle) {
        _autoFoldTimer = Timer(
          Duration(milliseconds: widget.foldDelayMs),
          _doAutoFold,
        );
      }
    }
  }

  void _doAutoFold() {
    if (mounted) {
      if (_isVisibleInViewport() && _foldRetryCount < _maxFoldRetries) {
        _foldRetryCount++;
        _autoFoldTimer = Timer(
          Duration(milliseconds: widget.foldDelayMs),
          _doAutoFold,
        );
        return;
      }
      setState(() {
        _expanded = false;
        _hasAutoFolded = true;
      });
    }
  }

  bool _isVisibleInViewport() {
    if (!mounted) return false;
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox) return false;
    final offset = renderObject.localToGlobal(Offset.zero);
    final screenHeight = MediaQuery.of(context).size.height;
    return offset.dy < screenHeight && offset.dy + renderObject.size.height > 0;
  }

  void _toggleExpanded() {
    _autoFoldTimer?.cancel();
    _autoFoldTimer = null;
    setState(() {
      _expanded = !_expanded;
      _hasAutoFolded = true;
    });
  }

  @override
  void dispose() {
    _autoFoldTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.artifacts != null) {
      return _buildHistory(context);
    }
    final colors = context.lm.palette;
    final t = Translations.of(context);
    final reducedMotion = LmMotion.reducedMotion(context);
    return AnimatedSize(
      duration: reducedMotion ? Duration.zero : LmMotion.base,
      curve: LmMotion.easeBoth,
      child: Container(
        margin: const EdgeInsets.symmetric(
          horizontal: IntermediateSpacing.sLg,
          vertical: IntermediateSpacing.sXs,
        ),
        decoration: BoxDecoration(
          color: colors.surfaceElevated,
          borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
        ),
        child: _buildContent(colors, t, reducedMotion),
      ),
    );
  }

  Widget _buildContent(
    LmPalette colors,
    Translations t,
    bool reducedMotion,
  ) {
    if (_isApplying) return _buildApplying(colors, t);
    if (_isFailed) return _buildFailed(colors, t, reducedMotion);
    if (_isCompleted) return _buildCompleted(colors, t);
    return const SizedBox.shrink();
  }

  /// 历史态：HistoryPanelShell，空变更显示「本轮无事实变更」
  Widget _buildHistory(BuildContext context) {
    final colors = context.lm.palette;
    final artifacts = widget.artifacts!;
    final changes = artifacts.factsChanges;
    final summary = changes.isEmpty
        ? Translations.of(context).intermediate.chat.factsChangeEmpty
        : Translations.of(context).intermediate.chat.historyFactsChangeReady(
              turn: artifacts.turnNumber,
              count: changes.length,
            );
    return HistoryPanelShell(
      key: ValueKey('history-facts-change-${artifacts.turnNumber}'),
      summary: summary,
      animateEntrance: false,
      expandedContent: changes.isEmpty
          ? const SizedBox.shrink()
          : _buildChangesList(colors, Translations.of(context), changes),
    );
  }

  /// applying 阶段：标题 + 加载指示
  Widget _buildApplying(LmPalette colors, Translations t) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: IntermediateSpacing.sMd,
        vertical: IntermediateSpacing.sSm,
      ),
      child: Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: colors.primary,
            ),
          ),
          const SizedBox(width: IntermediateSpacing.sXs),
          Expanded(
            child: Text(
              t.intermediate.chat.factsChangeHint,
              style: IntermediateTextStyles.caption.copyWith(
                color: colors.muted,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  /// 完成态：空列表显示占位；非空显示折叠行 + 展开列表
  Widget _buildCompleted(LmPalette colors, Translations t) {
    final changes = _changes;
    // 空列表：明确无事实变更，显示占位（不隐藏卡片）
    if (changes.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: IntermediateSpacing.sMd,
          vertical: IntermediateSpacing.sSm,
        ),
        child: Row(
          children: [
            Icon(
              Icons.check_circle_outline,
              size: 14,
              color: colors.faint,
            ),
            const SizedBox(width: IntermediateSpacing.sXs),
            Expanded(
              child: Text(
                t.intermediate.chat.factsChangeEmpty,
                style: IntermediateTextStyles.caption.copyWith(
                  color: colors.muted,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
    }

    return InkWell(
      onTap: _toggleExpanded,
      borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: IntermediateSpacing.sMd,
          vertical: IntermediateSpacing.sSm,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  _expanded
                      ? Icons.keyboard_arrow_down
                      : Icons.keyboard_arrow_right,
                  size: 16,
                  color: colors.primary,
                ),
                const SizedBox(width: IntermediateSpacing.sXs),
                Expanded(
                  child: Text(
                    t.intermediate.chat.factsChangeReady(count: changes.length),
                    style: IntermediateTextStyles.caption.copyWith(
                      color: colors.muted,
                    ),
                  ),
                ),
              ],
            ),
            if (_expanded) ...[
              const SizedBox(height: IntermediateSpacing.sSm),
              Divider(height: 1, color: colors.divider),
              const SizedBox(height: IntermediateSpacing.sSm),
              _buildChangesList(colors, t, changes),
              // 疑似重复行（实时态有候选时追加）
              if (widget.artifacts == null &&
                  (widget.similarNameCandidates?.isNotEmpty ?? false)) ...[
                const SizedBox(height: IntermediateSpacing.sXs),
                _buildSimilarCandidates(colors, t),
              ],
            ],
          ],
        ),
      ),
    );
  }

  /// 变更列表（每条：动作徽章 + 实体名/属性摘要，点击弹详情）
  Widget _buildChangesList(
    LmPalette colors,
    Translations t,
    List<FactsChangeRecord> changes,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final record in changes)
          Padding(
            padding: const EdgeInsets.only(bottom: IntermediateSpacing.sXs),
            child: InkWell(
              onTap: () =>
                  FactsChangeDetailDialog.show(context, record: record),
              borderRadius:
                  BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  vertical: IntermediateSpacing.s2xs,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildActionBadge(colors, t, record.action),
                    const SizedBox(width: IntermediateSpacing.sXs),
                    Expanded(
                      child: Text(
                        _recordSummary(record),
                        style: IntermediateTextStyles.caption.copyWith(
                          color: colors.ink,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// 疑似重复行——「新名 ↔ 既有实体(命中名)」，点击进
  /// 记忆库事实 Tab 并预选候选实体（归并闭环）
  Widget _buildSimilarCandidates(LmPalette colors, Translations t) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final candidate in widget.similarNameCandidates!)
          Padding(
            padding: const EdgeInsets.only(bottom: IntermediateSpacing.sXs),
            child: InkWell(
              onTap: widget.session == null
                  ? null
                  : () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => MemoryBrowserPage(
                            session: widget.session!,
                            initialTab: 1,
                            preselectEntityIds:
                                candidate.similarEntityIds.toSet(),
                          ),
                        ),
                      ),
              borderRadius:
                  BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  vertical: IntermediateSpacing.s2xs,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: colors.warning.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(
                          context.lmUi.radius(LmCorner.xs),
                        ),
                        border: Border.all(
                          color: colors.warning.withValues(alpha: 0.4),
                          width: 0.5,
                        ),
                      ),
                      child: Text(
                        t.intermediate.chat.similarNameBadge,
                        style: IntermediateTextStyles.caption.copyWith(
                          color: colors.warning,
                        ),
                      ),
                    ),
                    const SizedBox(width: IntermediateSpacing.sXs),
                    Expanded(
                      child: Text(
                        t.intermediate.chat.similarNameEntry(
                          newName: candidate.newName,
                          existing: candidate.displayNames.join('、'),
                        ),
                        style: IntermediateTextStyles.caption.copyWith(
                          color: colors.ink,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// 单条变更的行内摘要（实体名 + 属性 + 变更梗概）
  String _recordSummary(FactsChangeRecord record) {
    final name = record.primaryName ?? record.entityId ?? '';
    final attr = record.attrKey;
    switch (record.action) {
      case FactAction.createEntity:
        return name;
      case FactAction.archiveEntity:
        return name;
      case FactAction.addAlias:
      case FactAction.updateAttr:
      case FactAction.appendList:
      case FactAction.removeFromList:
        return attr == null || attr.isEmpty ? name : '$name · $attr';
    }
  }

  /// 动作徽章
  Widget _buildActionBadge(
    LmPalette colors,
    Translations t,
    FactAction action,
  ) {
    final chat = t.intermediate.chat;
    final label = switch (action) {
      FactAction.createEntity => chat.factsActionCreateEntity,
      FactAction.updateAttr => chat.factsActionUpdateAttr,
      FactAction.appendList => chat.factsActionAppendList,
      FactAction.removeFromList => chat.factsActionRemoveFromList,
      FactAction.addAlias => chat.factsActionAddAlias,
      FactAction.archiveEntity => chat.factsActionArchiveEntity,
    };
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: IntermediateSpacing.sSm,
        vertical: IntermediateSpacing.s2xs,
      ),
      decoration: BoxDecoration(
        color: colors.primaryDim,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
      ),
      child: Text(
        label,
        style: IntermediateTextStyles.caption.copyWith(
          color: colors.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  /// 失败态：灰度滤镜（与 SummarizePanel 一致）
  Widget _buildFailed(
    LmPalette colors,
    Translations t,
    bool reducedMotion,
  ) {
    return AnimatedOpacity(
      opacity: 0.4,
      duration: reducedMotion ? Duration.zero : LmMotion.emphasis,
      curve: LmMotion.easeStandard,
      child: ColorFiltered(
        colorFilter: const ColorFilter.matrix(<double>[
          0.2126,
          0.7152,
          0.0722,
          0,
          0,
          0.2126,
          0.7152,
          0.0722,
          0,
          0,
          0.2126,
          0.7152,
          0.0722,
          0,
          0,
          0,
          0,
          0,
          1,
          0,
        ]),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: IntermediateSpacing.sMd,
            vertical: IntermediateSpacing.sSm,
          ),
          child: Row(
            children: [
              Icon(Icons.error_outline, size: 16, color: colors.error),
              const SizedBox(width: IntermediateSpacing.sXs),
              Expanded(
                child: Text(
                  t.intermediate.chat.factsChangeFailed,
                  style: IntermediateTextStyles.caption.copyWith(
                    color: colors.muted,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
