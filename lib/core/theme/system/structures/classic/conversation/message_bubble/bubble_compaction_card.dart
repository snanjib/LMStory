import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/system/lm_ui_text_styles.dart';
import 'package:lmstory/core/theme/system/structures/classic/conversation/message_bubble/bubble_shared.dart';
import 'package:lmstory/core/theme/system/structures/classic/conversation/simple_markdown_body.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/i18n/strings.g.dart';

// =============================================================================
// CompactionPoint summary card (expandable)
// （从 simple_message_bubble.dart 拆出，主文件装配引用）
// =============================================================================

/// Expandable card for CompactionPoint summary messages.
///
/// Reference: ChatBox's SummaryMessage — shows "Earlier messages summarized"
/// with expand button. When expanded, shows summary text + edit/delete actions.
/// Style: surfaceVariant background, italic text, left border accent.
///
/// 流式生成中（[isStreaming]=true）的展示策略（对标 ChatBox CompactionStatus）：
/// - 折叠态：标签行显示加载动画 + "正在生成摘要..."；下方小窗预览实时显示
///   流式内容最后几行 + 末尾闪烁光标
/// - 展开态：正常显示流式内容（Markdown），末尾闪烁光标；不显示编辑/删除按钮
///
/// 生成完毕（[isStreaming]=false）的展示策略：
/// - 折叠态：标签行显示"早期消息已摘要"+ 展开图标（无预览窗）
/// - 展开态：Markdown 内容 + 编辑/删除按钮（对标 ChatBox SummaryMessage）
class BubbleCompactionSummaryCard extends StatefulWidget {
  const BubbleCompactionSummaryCard({
    required this.message,
    required this.colors,
    super.key,
    this.isStreaming = false,
    this.isLatestSummary = false,
    this.onEdit,
    this.onDelete,
  });

  final ChatMessage message;
  final LmPalette colors;

  /// 是否正在流式生成内容（压缩进行中）。
  /// 详见类注释中的渲染策略。
  final bool isStreaming;

  /// 是否为最新摘要——只有最新压缩可「撤销压缩」
  ///（删旧摘要不改上下文：getCompressedMessages 只认最新压缩点）。
  final bool isLatestSummary;

  /// 对标 ChatBox SummaryMessage handleEdit：编辑摘要内容
  final VoidCallback? onEdit;

  /// 对标 ChatBox SummaryMessage onDelete：删除摘要，恢复原始消息到上下文
  final VoidCallback? onDelete;

  @override
  State<BubbleCompactionSummaryCard> createState() =>
      _BubbleCompactionSummaryCardState();
}

class _BubbleCompactionSummaryCardState
    extends State<BubbleCompactionSummaryCard> {
  bool _isExpanded = false;

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    // 摘要行缺失时的哨兵占位 → 本地化文案（哨兵不直接示人）
    final rawContent = widget.message.content ?? '';
    final content = rawContent == ChatMessage.summaryUnavailableContent
        ? t.chat.compaction.summaryUnavailable
        : rawContent;

    return Padding(
      padding: const EdgeInsets.only(
        bottom: LmSpacing.sSm,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: widget.colors.surfaceVariant,
          borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
          border: Border(
            left: BorderSide(
              color: widget.colors.accent,
              width: 3,
            ),
          ),
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
                horizontal: LmSpacing.sMd,
                vertical: LmSpacing.sSm,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 标签行
                  // - 流式中：加载动画 + "正在生成摘要..." + 展开图标
                  // - 流式结束：摘要图标 + "早期消息已摘要" + 展开图标
                  _buildHeader(t),
                  // 折叠 + 流式中：小窗预览（最后几行 + 闪烁光标）
                  if (!_isExpanded && widget.isStreaming)
                    _buildStreamingPreview(content),
                  // 展开 + 流式中：完整 Markdown 内容 + 末尾闪烁光标
                  if (_isExpanded && widget.isStreaming)
                    _buildExpandedStreamingContent(content),
                  // 展开 + 流式结束：完整 Markdown 内容 + 编辑/删除按钮
                  if (_isExpanded && !widget.isStreaming)
                    _buildExpandedFinishedContent(t),
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
  /// 流式中的动画策略（避免与内容区重复）：
  /// - 折叠态：标签行显示三点动画（提示生成中），下方小窗预览也承载动画/光标
  /// - 展开态：标签行改用静态图标（动画仅由内容区承载，避免"标签 + 内容"双重动画）
  Widget _buildHeader(Translations t) {
    if (widget.isStreaming) {
      return Row(
        children: [
          if (_isExpanded)
            // 展开态：静态图标，动画交给下方内容区
            Icon(
              Icons.auto_awesome_outlined,
              size: 16,
              color: widget.colors.accent,
            )
          else
            // 折叠态：三点动画提示生成中
            BubbleBouncingDotsIndicator(colors: widget.colors),
          const SizedBox(width: LmSpacing.sXs),
          Expanded(
            child: Text(
              t.chat.compaction.generating,
              style: LmUiTextStyles.caption.copyWith(
                color: widget.colors.accent,
                fontStyle: FontStyle.italic,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Icon(
            _isExpanded ? Icons.expand_less : Icons.expand_more,
            size: 18,
            color: widget.colors.muted,
          ),
        ],
      );
    }

    // 流式结束：保持原有标签
    return Row(
      children: [
        Icon(
          Icons.auto_awesome_outlined,
          size: 16,
          color: widget.colors.accent,
        ),
        const SizedBox(width: LmSpacing.sXs),
        Expanded(
          child: Text(
            t.chat.compaction.earlierSummarized,
            style: LmUiTextStyles.caption.copyWith(
              color: widget.colors.muted,
              fontStyle: FontStyle.italic,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Icon(
          _isExpanded ? Icons.expand_less : Icons.expand_more,
          size: 18,
          color: widget.colors.muted,
        ),
      ],
    );
  }

  /// 折叠 + 流式中：小窗预览实时显示流式内容最后几行 + 闪烁光标。
  ///
  /// - content 为空时：显示加载动画（BubbleBouncingDotsIndicator）作为占位
  /// - content 非空时：取最后约 240 个字符显示（纯文本预览，避免 Markdown 全量重渲染）
  ///   末尾跟 BubbleStreamingCursor 表示仍在接收
  Widget _buildStreamingPreview(String content) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: LmSpacing.sXs),
        Divider(height: 1, color: widget.colors.divider),
        const SizedBox(height: LmSpacing.sXs),
        if (content.isEmpty)
          // 等待首个 token：显示三个点动画占位
          Padding(
            padding: const EdgeInsets.symmetric(
              vertical: LmSpacing.s2xs,
            ),
            child: BubbleBouncingDotsIndicator(colors: widget.colors),
          )
        else
          // 显示最后几行预览 + 闪烁光标
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 80),
            child: SingleChildScrollView(
              reverse: true,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Flexible(
                    child: Text(
                      _lastPreviewLines(content),
                      style: LmUiTextStyles.bodySm.copyWith(
                        color: widget.colors.muted,
                      ),
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const BubbleStreamingCursor(),
                ],
              ),
            ),
          ),
      ],
    );
  }

  /// 展开 + 流式中：完整 Markdown 内容 + 末尾闪烁光标。
  Widget _buildExpandedStreamingContent(String content) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: LmSpacing.sXs),
        Divider(height: 1, color: widget.colors.divider),
        const SizedBox(height: LmSpacing.sXs),
        if (content.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: LmSpacing.s2xs),
            child: BubbleBouncingDotsIndicator(colors: widget.colors),
          )
        else
          Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Flexible(child: SimpleMarkdownBody(data: content)),
              const BubbleStreamingCursor(),
            ],
          ),
      ],
    );
  }

  /// 展开 + 流式结束：完整 Markdown 内容 + 编辑/删除按钮（对标 ChatBox SummaryMessage）。
  Widget _buildExpandedFinishedContent(Translations t) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: LmSpacing.sXs),
        Divider(
          height: 1,
          color: widget.colors.divider,
        ),
        const SizedBox(height: LmSpacing.sXs),
        SimpleMarkdownBody(
          data: widget.message.content ?? '',
        ),
        // 编辑/删除按钮（对标 ChatBox SummaryMessage 操作栏）
        if (widget.onEdit != null || widget.onDelete != null) ...[
          const SizedBox(height: LmSpacing.sXs),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (widget.onEdit != null)
                _SummaryActionButton(
                  icon: Icons.edit_outlined,
                  label: t.chat.compaction.editSummary,
                  colors: widget.colors,
                  onTap: widget.onEdit!,
                ),
              if (widget.onEdit != null && widget.onDelete != null)
                const SizedBox(width: LmSpacing.sSm),
              if (widget.onDelete != null)
                _SummaryActionButton(
                  // 最新摘要=「撤销压缩」（非破坏性
                  // 语义：归档对话恢复）；旧摘要保留「删除」
                  icon: widget.isLatestSummary
                      ? Icons.undo
                      : Icons.delete_outline,
                  label: widget.isLatestSummary
                      ? t.chat.compaction.undoCompaction
                      : t.chat.compaction.deleteSummary,
                  colors: widget.colors,
                  isDestructive: !widget.isLatestSummary,
                  onTap: () => _showDeleteConfirm(context, t),
                ),
            ],
          ),
        ],
      ],
    );
  }

  /// 取流式 content 的最后几行作为预览文本。
  ///
  /// 仅取末尾约 240 字符，避免长文本预览时一次性渲染大量字符。
  /// 不做 Markdown 解析（预览阶段），保留纯文本以便性能。
  String _lastPreviewLines(String content) {
    const maxChars = 240;
    if (content.length <= maxChars) return content.trimRight();
    final slice = content.substring(content.length - maxChars);
    final firstNewline = slice.indexOf('\n');
    return (firstNewline >= 0 ? slice.substring(firstNewline + 1) : slice)
        .trimRight();
  }

  /// 删除确认弹窗（对标 ChatBox SummaryMessage showDeleteConfirm）
  void _showDeleteConfirm(BuildContext context, Translations t) {
    showLmDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          widget.isLatestSummary
              ? t.chat.compaction.undoConfirmTitle
              : t.chat.compaction.deleteSummaryTitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        content: Text(
          widget.isLatestSummary
              ? t.chat.compaction.undoConfirmBody
              : t.chat.compaction.deleteSummaryConfirm,
          maxLines: 5,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(
              t.chat.compaction.cancel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              widget.onDelete?.call();
            },
            style: TextButton.styleFrom(
              foregroundColor: widget.colors.error,
            ),
            child: Text(
              widget.isLatestSummary
                  ? t.chat.compaction.undoAction
                  : t.chat.compaction.delete,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// 摘要操作按钮（编辑/删除）
class _SummaryActionButton extends StatelessWidget {
  const _SummaryActionButton({
    required this.icon,
    required this.label,
    required this.colors,
    required this.onTap,
    this.isDestructive = false,
  });

  final IconData icon;
  final String label;
  final LmPalette colors;
  final VoidCallback onTap;
  final bool isDestructive;

  @override
  Widget build(BuildContext context) {
    final color = isDestructive ? colors.error : colors.muted;
    return InkWell(
      borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: LmSpacing.sXs,
          vertical: LmSpacing.sXs,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: LmSpacing.sXs),
            Text(
              label,
              style: LmUiTextStyles.overline.copyWith(color: color),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
