import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_spacing.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_layout.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/advanced/presentation/widgets/director_anchor_edit_sheet.dart';
import 'package:lmstory/features/chat/domain/entities/story_anchor.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 幕间 Recap 卡（体验重构卡片 C §4.3.7）
///
/// 每轮正文块之后的极简章末行：`第 N 幕 · 叙事时间 · 一句主线进展`。
/// 书脊形态复用压缩摘要卡（IntermediateCompactionSummaryCard）的观感语言：
/// 整宽、surfaceVariant、muted、无统计。点击展开锚详情（当前弧线/伏笔
/// 清单）。
///
/// [onEditAnchor] 非空（仅最新锚卡由 body
/// 提供）时展开区显示「编辑」入口——经 [DirectorAnchorEditSheet] 编辑后
/// 走与 AI 相同的数据源写回（历史轮快照保持只读，编辑改的是会话当前锚）。
///
/// （'）：[factsChangeCount] > 0 时书脊行末显示「设定集 N 处变更」
/// chip，点击经 [onOpenMemory] 直达记忆库（观测闭环）。
class DirectorRecapCard extends StatefulWidget {
  const DirectorRecapCard({
    required this.act,
    required this.anchor,
    this.factsChangeCount = 0,
    this.onOpenMemory,
    this.onEditAnchor,
    super.key,
  });

  /// 幕号（= 轮次号，剧场语言）
  final int act;

  /// 该轮结束时的剧情锚快照
  final StoryAnchor anchor;

  /// 该轮设定集（事实层）变更数（artifacts.factsChanges.length）
  final int factsChangeCount;

  /// 「设定集 N 处变更」chip 点击 → 记忆库页
  final VoidCallback? onOpenMemory;

  /// 编辑当前锚回调（null = 只读历史快照，不显示编辑入口）
  final ValueChanged<StoryAnchor>? onEditAnchor;

  @override
  State<DirectorRecapCard> createState() => _DirectorRecapCardState();
}

class _DirectorRecapCardState extends State<DirectorRecapCard> {
  var _expanded = false;

  // 伏笔清单超 8 条时展开/收起全部（分待兑现/已兑现两组独立）
  var _showAllOpen = false;
  var _showAllResolved = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    final anchor = widget.anchor;

    // 阅读行宽钳制（与稿件卡同款；移动端视口窄于上限不受影响）
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: LmLayout.readingWidthOf(context)),
        child: Padding(
          padding: const EdgeInsets.only(bottom: IntermediateSpacing.sMd),
          child: Container(
            decoration: BoxDecoration(
              color: colors.surfaceVariant,
              borderRadius:
                  BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
              border: Border.all(color: colors.divider, width: 0.5),
            ),
            child: Material(
              color: Colors.transparent,
              borderRadius:
                  BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
              child: InkWell(
                borderRadius:
                    BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
                onTap: () => setState(() => _expanded = !_expanded),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: IntermediateSpacing.sLg,
                    vertical: IntermediateSpacing.sSm,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 32),
                        child: Row(
                          children: [
                            Icon(
                              Icons.menu_book_outlined,
                              size: 13,
                              color: colors.faint,
                            ),
                            const SizedBox(width: IntermediateSpacing.sSm),
                            Expanded(
                              child: Text(
                                _spine(anchor, t),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: IntermediateTextStyles.caption.copyWith(
                                  color: colors.muted,
                                ),
                              ),
                            ),
                            // （'）：设定集变更 chip（有变更才显示，
                            // 点击直达记忆库；与展开箭头并排）
                            if (widget.factsChangeCount > 0) ...[
                              _FactsChangeChip(
                                count: widget.factsChangeCount,
                                onTap: widget.onOpenMemory,
                              ),
                              const SizedBox(width: IntermediateSpacing.sXs),
                            ],
                            Icon(
                              _expanded ? Icons.expand_less : Icons.expand_more,
                              size: 16,
                              color: colors.faint,
                            ),
                          ],
                        ),
                      ),
                      if (_expanded) _detail(anchor, colors, t),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 书脊一行：第 N 幕 · 叙事时间 · 一句主线
  String _spine(StoryAnchor anchor, Translations t) {
    final parts = <String>[
      t.advanced.recap.actLabel(act: widget.act),
      if (anchor.narrativeTime != null && anchor.narrativeTime!.isNotEmpty)
        anchor.narrativeTime!,
      if (anchor.oneLiner != null && anchor.oneLiner!.isNotEmpty)
        anchor.oneLiner!,
    ];
    return parts.join(' · ');
  }

  /// 展开的锚详情：弧线 + 伏笔清单（只读，无编辑入口）
  Widget _detail(
    StoryAnchor anchor,
    LmPalette colors,
    Translations t,
  ) {
    final open = anchor.openForeshadows;
    final resolved = anchor.foreshadows.where((f) => f.resolved).toList();

    return Padding(
      padding: const EdgeInsets.only(top: IntermediateSpacing.sXs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (anchor.arc != null && anchor.arc!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: IntermediateSpacing.s2xs),
              child: Text(
                '${t.advanced.recap.arc}：${anchor.arc}',
                style: IntermediateTextStyles.caption.copyWith(
                  color: colors.muted,
                ),
              ),
            ),
          if (open.isNotEmpty) ...[
            Text(
              t.advanced.recap.foreshadowsOpen,
              style: IntermediateTextStyles.caption.copyWith(
                color: colors.faint,
              ),
            ),
            // 截断 8 条改为可展开——「展开全部 N 条」替代静默计数行
            for (final foreshadow in _visible(open, _showAllOpen))
              Padding(
                padding: const EdgeInsets.only(left: IntermediateSpacing.sMd),
                child: Text(
                  '· ${foreshadow.text}',
                  style: IntermediateTextStyles.caption.copyWith(
                    color: colors.muted,
                  ),
                ),
              ),
            if (open.length > 8)
              _expandToggle(
                expanded: _showAllOpen,
                hiddenCount: open.length - 8,
                colors: colors,
                t: t,
                onTap: () => setState(() => _showAllOpen = !_showAllOpen),
              ),
          ],
          if (resolved.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.only(top: IntermediateSpacing.s2xs),
              child: Text(
                t.advanced.recap.foreshadowsResolved,
                style: IntermediateTextStyles.caption.copyWith(
                  color: colors.faint,
                ),
              ),
            ),
            for (final foreshadow in _visible(resolved, _showAllResolved))
              Padding(
                padding: const EdgeInsets.only(left: IntermediateSpacing.sMd),
                child: Text(
                  '· ${foreshadow.text}',
                  style: IntermediateTextStyles.caption.copyWith(
                    color: colors.faint,
                    decoration: TextDecoration.lineThrough,
                    decorationColor: colors.faint,
                  ),
                ),
              ),
            if (resolved.length > 8)
              _expandToggle(
                expanded: _showAllResolved,
                hiddenCount: resolved.length - 8,
                colors: colors,
                t: t,
                onTap: () =>
                    setState(() => _showAllResolved = !_showAllResolved),
              ),
          ],
          // 编辑入口（仅最新锚卡提供回调时显示）
          if (widget.onEditAnchor != null) _editEntry(colors, t),
        ],
      ),
    );
  }

  /// 截断窗口——收起态取前 8 条，展开态全量
  static const _foreshadowPreviewCount = 8;

  List<AnchorForeshadow> _visible(List<AnchorForeshadow> list, bool showAll) =>
      showAll ? list : list.take(_foreshadowPreviewCount).toList();

  /// 展开/收起切换行（替代  的静默计数行）
  Widget _expandToggle({
    required bool expanded,
    required int hiddenCount,
    required LmPalette colors,
    required Translations t,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(left: IntermediateSpacing.sMd),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.full)),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: IntermediateSpacing.sSm,
            vertical: 2,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                expanded ? Icons.expand_less : Icons.expand_more,
                size: 14,
                color: colors.faint,
              ),
              const SizedBox(width: IntermediateSpacing.s2xs),
              Text(
                expanded
                    ? t.advanced.recap.foreshadowsCollapse
                    : t.advanced.recap.foreshadowsExpandAll(
                        count: hiddenCount,
                      ),
                style: IntermediateTextStyles.caption.copyWith(
                  color: colors.faint,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 编辑当前锚入口行
  Widget _editEntry(LmPalette colors, Translations t) {
    return Padding(
      padding: const EdgeInsets.only(top: IntermediateSpacing.sXs),
      child: Align(
        alignment: Alignment.centerRight,
        child: InkWell(
          key: const ValueKey('recap-edit-anchor'),
          onTap: () async {
            final edited = await DirectorAnchorEditSheet.show(
              context,
              widget.anchor,
            );
            if (edited != null) widget.onEditAnchor?.call(edited);
          },
          borderRadius:
              BorderRadius.circular(context.lmUi.radius(LmCorner.full)),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: IntermediateSpacing.sSm,
              vertical: IntermediateSpacing.s2xs,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.edit_outlined, size: 13, color: colors.primary),
                const SizedBox(width: IntermediateSpacing.s2xs),
                Text(
                  t.advanced.anchorEdit.entry,
                  style: IntermediateTextStyles.caption.copyWith(
                    color: colors.primary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 设定集变更 chip（'）：行末小标签，点击直达记忆库
class _FactsChangeChip extends StatelessWidget {
  const _FactsChangeChip({required this.count, this.onTap});

  final int count;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.full)),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: IntermediateSpacing.sSm,
          vertical: 2,
        ),
        decoration: BoxDecoration(
          color: colors.primaryDim,
          borderRadius:
              BorderRadius.circular(context.lmUi.radius(LmCorner.full)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.tune, size: 10, color: colors.primary),
            const SizedBox(width: 3),
            Text(
              t.advanced.recap.factsChanges(count: count),
              style: IntermediateTextStyles.caption.copyWith(
                color: colors.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
