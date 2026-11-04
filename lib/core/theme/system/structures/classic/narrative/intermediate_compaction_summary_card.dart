import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/system/lm_narrative_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/system/structures/classic/narrative/intermediate_markdown_body.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 故事模式压缩摘要卡片（DOC-06B §6.5）。
///
/// 设计意图：压缩摘要作为「上下文隔断」展示，区别于普通消息气泡。
/// 参考对标 ChatBox 的 SummaryMessage，但适配夜航主题：
///
/// - **整宽显示**：不像普通气泡限制 92% 宽度，而是占满消息列表可用宽度，
///   视觉上「横跨」对话流，形成隔断感
/// - **区分底色**：用 `surfaceVariant`（比气泡 `surface` 略浅），加上 1px
///   `divider` 边框，强化「这不是对话消息」的视觉信号
/// - **折叠态紧凑**：仅显示标签行（图标 + "早期消息已摘要" + 展开箭头），
///   高度约 44px，像一条带文字的分隔条
/// - **展开态叙事**：标签行 + 分隔线 + 衬线斜体摘要内容（narrativeQuote），
///   保持夜航主题的文学感
/// - **无侧边条**（impeccable 禁令）：用底色 + 边框 + 图标实现区分，
///   不使用 `border-left` 彩色侧条
///
/// 位置语义：摘要消息由 `StoryCompactionService.filterByCompactionPoint`
/// 置于消息列表最前，boundary 之后的消息（含新用户消息）排在摘要之后，
/// 确保新用户消息始终在压缩摘要后边（用户需求 2026-08-04）。
class IntermediateCompactionSummaryCard extends StatefulWidget {
  const IntermediateCompactionSummaryCard({
    required this.content,
    this.fontScale = 1.0,
    this.showFloorWarning = false,
    this.archivedTurnRange,
    this.onUndo,
    this.undoEnabled = true,
    super.key,
  });

  /// 摘要文本内容（剧情宏观骨架）。
  ///
  /// 由 `StoryCompactionService.compact` 生成并持久化到
  /// `chat_messages` 表（isSummary=true, role=system）。
  final String content;

  /// 字体缩放比例（与宿主消息列表共享）。
  ///
  /// 应用到展开态摘要正文的字号（narrativeQuote 16px 基准），
  /// 与普通消息气泡保持字号一致。折叠态标签使用 caption 字号，
  /// 不随 fontScale 缩放，保持 UI 元素视觉层次。
  final double fontScale;

  /// 压缩保留量触底警示。
  ///
  /// true = 最近一次压缩的保留量上限（触发线 − 检索预留 − 基础上下文）
  /// 已 ≤ 0，近期对话保留区只剩保底量，后续轮次极易再次触发压缩。
  /// 在标签行下方显示一行警示文案（warning 色），不随展开态变化。
  final bool showFloorWarning;

  /// 已归档轮次范围：`第 X–Y 轮`（null = 未知，不显示）。
  ///
  /// X = 该摘要之前的历史压缩累计轮数 +1，Y = 本次压缩覆盖到的轮数。
  final ({int from, int to})? archivedTurnRange;

  /// 撤销压缩回调（U2，2026-09-04）：null = 不显示撤销入口。
  ///
  /// 回调内部已含业务守卫（非 idle 时控制器直接拒绝），UI 侧用
  /// [undoEnabled] 控制按钮可用性。确认弹窗由卡片自带（两模式共用）。
  final Future<void> Function()? onUndo;

  /// 撤销按钮可用性（生成中/压缩中置灰，与手动压缩互斥同口径）。
  final bool undoEnabled;

  @override
  State<IntermediateCompactionSummaryCard> createState() =>
      _IntermediateCompactionSummaryCardState();
}

class _IntermediateCompactionSummaryCardState
    extends State<IntermediateCompactionSummaryCard> {
  bool _isExpanded = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    return Padding(
      // 上下用 sMd（12px）留白，比普通消息的 s2xs（4px）更大，
      // 在摘要与上下消息之间形成视觉呼吸感，强化隔断效果。
      padding: const EdgeInsets.symmetric(
        vertical: LmSpacing.sMd,
      ),
      child: Container(
        decoration: BoxDecoration(
          // surfaceVariant 比 bubble 的 surface 略浅，区分「非对话消息」
          color: colors.surfaceVariant,
          borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
          // 1px 边框强化隔断感（不用侧边条，impeccable 禁令）
          border: Border.all(color: colors.divider),
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
          child: InkWell(
            borderRadius:
                BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
            onTap: () => setState(() => _isExpanded = !_isExpanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: LmSpacing.sLg,
                vertical: LmSpacing.sSm,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildHeader(colors, t),
                  //  触底警示：保留区只剩保底量，连续压缩风险
                  if (widget.showFloorWarning) ...[
                    const SizedBox(height: LmSpacing.s2xs),
                    _buildFloorWarning(colors, t),
                  ],
                  if (_isExpanded) ...[
                    const SizedBox(height: LmSpacing.sXs),
                    Divider(
                      height: 1,
                      color: colors.divider,
                    ),
                    const SizedBox(height: LmSpacing.sSm),
                    _buildSummaryContent(colors),
                    // U2（2026-09-04 撤销压缩）：展开态尾部撤销入口
                    if (widget.onUndo != null) ...[
                      const SizedBox(height: LmSpacing.sSm),
                      _buildUndoFooter(colors, t),
                    ],
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 标签行（始终显示）。
  ///
  /// 图标（auto_awesome_outlined，accent 琥珀金）+ "早期消息已摘要"
  /// （caption，muted，斜体）+ 展开/收起箭头。点击整行切换展开状态。
  Widget _buildHeader(LmPalette colors, Translations t) {
    return Row(
      children: [
        Icon(
          Icons.auto_awesome_outlined,
          size: 16,
          color: colors.accent,
        ),
        const SizedBox(width: LmSpacing.sXs),
        Expanded(
          child: Text(
            // 已归档轮次范围拼在标签后
            widget.archivedTurnRange == null
                ? t.intermediate.chat.compaction.earlierSummarized
                : '${t.intermediate.chat.compaction.earlierSummarized} · '
                    '${t.intermediate.chat.compaction.archivedTurns(from: widget.archivedTurnRange!.from, to: widget.archivedTurnRange!.to)}',
            style: LmNarrativeTextStyles.caption.copyWith(
              color: colors.muted,
              fontStyle: FontStyle.italic,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        // 无障碍：展开/收起按钮的语义标签
        Semantics(
          label: _isExpanded
              ? t.intermediate.chat.compaction.collapse
              : t.intermediate.chat.compaction.expand,
          button: true,
          child: Icon(
            _isExpanded ? Icons.expand_less : Icons.expand_more,
            size: 18,
            color: colors.muted,
          ),
        ),
      ],
    );
  }

  /// 展开态：衬线斜体摘要内容。
  ///
  /// 使用 IntermediateMarkdownBody（isUser=false）渲染，保持夜航主题
  /// 的衬线叙事字体。摘要可能包含基础 Markdown 语法（加粗/列表等），
  /// 由 LLM 生成。
  Widget _buildSummaryContent(LmPalette colors) {
    // 摘要行缺失时的哨兵占位 → 本地化文案（哨兵不直接示人）
    final content = widget.content == ChatMessage.summaryUnavailableContent
        ? Translations.of(context).chat.compaction.summaryUnavailable
        : widget.content;
    return IntermediateMarkdownBody(
      data: content,
      isUser: false,
      fontScale: widget.fontScale,
    );
  }

  /// 展开态尾部：撤销压缩按钮（U2，2026-09-04）。
  ///
  /// 与整卡的「隔断」语言一致：muted 文字 + undo 图标，点了先弹确认——
  /// 撤销删除摘要属破坏性方向的操作，不允许免确认直接触发。
  /// [IntermediateCompactionSummaryCard.undoEnabled] 为 false 时置灰。
  Widget _buildUndoFooter(LmPalette colors, Translations t) {
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: widget.undoEnabled ? () => _confirmUndo(t) : null,
        icon: Icon(
          Icons.undo,
          size: 14,
          color: widget.undoEnabled ? colors.muted : colors.faint,
        ),
        label: Text(
          t.intermediate.chat.compaction.undoCompaction,
          style: LmNarrativeTextStyles.caption.copyWith(
            color: widget.undoEnabled ? colors.muted : colors.faint,
          ),
        ),
        style: TextButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(
            horizontal: LmSpacing.sXs,
          ),
          minimumSize: const Size(0, 32),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
    );
  }

  Future<void> _confirmUndo(Translations t) async {
    final confirmed = await showLmDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(t.intermediate.chat.compaction.undoConfirmTitle),
        content: Text(t.intermediate.chat.compaction.undoConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(t.common.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(t.intermediate.chat.compaction.undoCompaction),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.onUndo?.call();
    // 撤销成功后摘要卡会随列表刷新消失；若仍在（撤销失败），收起展开态
    if (mounted && _isExpanded) {
      setState(() => _isExpanded = false);
    }
  }

  /// 保留量触底警示行。
  ///
  /// warning 色图标 + 一行说明：近期对话保留区已被压到保底量，
  /// 后续轮次可能频繁触发压缩；建议收敛剧情/清理上下文或换更大窗口模型。
  Widget _buildFloorWarning(LmPalette colors, Translations t) {
    return Row(
      children: [
        Icon(
          Icons.warning_amber_rounded,
          size: 14,
          color: colors.warning,
        ),
        const SizedBox(width: LmSpacing.sXs),
        Expanded(
          child: Text(
            t.intermediate.chat.compaction.retentionFloorWarning,
            style: LmNarrativeTextStyles.caption.copyWith(
              color: colors.warning,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
