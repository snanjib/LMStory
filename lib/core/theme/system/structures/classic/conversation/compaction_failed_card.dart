import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/system/lm_ui_text_styles.dart';
import 'package:lmstory/core/theme/system/structures/classic/conversation/simple_markdown_body.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 压缩失败卡片
///
/// 当压缩摘要消息满足 `isSummary && error != null` 时渲染。
/// 常驻对话流，用户必须手动点关闭按钮才会删除（不自动消失）。
/// 保留 LLM 已生成的部分摘要内容，提供"重试"和"关闭"操作。
///
/// 视觉：error 色全边框 + error 淡背景 tint，区别于正常摘要卡片
/// （遵循 impeccable 规则：不使用侧边条作为彩色强调）。
///
/// 错误信息展示：默认 3 行预览 + 省略号 + "展开"按钮；点击展开后显示完整错误内容，
/// 按钮切换为"收起"。对标 ChatBox CompactionStatus 失败态的折叠/展开。
class CompactionFailedCard extends StatefulWidget {
  const CompactionFailedCard({
    required this.message,
    required this.colors,
    required this.onRetry,
    required this.onClose,
    super.key,
  });

  /// 失败的摘要消息
  ///
  /// [ChatMessage.error] 存储错误信息，[ChatMessage.content]
  /// 为 LLM 已生成的部分摘要内容（可能为空）。
  final ChatMessage message;

  final LmPalette colors;

  /// 点击"重试"按钮：删除失败摘要后重新触发流式压缩
  final VoidCallback onRetry;

  /// 点击"关闭"按钮：从对话流删除失败摘要消息
  final VoidCallback onClose;

  @override
  State<CompactionFailedCard> createState() => _CompactionFailedCardState();
}

class _CompactionFailedCardState extends State<CompactionFailedCard> {
  bool _isErrorExpanded = false;

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final errorText = widget.message.error ?? '';
    final partialContent = widget.message.content ?? '';

    return Padding(
      padding: const EdgeInsets.only(bottom: LmSpacing.sSm),
      child: Container(
        decoration: BoxDecoration(
          color: widget.colors.error.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
          border: Border.all(
            color: widget.colors.error.withValues(alpha: 0.25),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: LmSpacing.sMd,
            vertical: LmSpacing.sSm,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.error_outline,
                    size: 16,
                    color: widget.colors.error,
                  ),
                  const SizedBox(width: LmSpacing.sXs),
                  Expanded(
                    child: Text(
                      t.chat.compaction.compressFailedTitle,
                      style: LmUiTextStyles.caption.copyWith(
                        color: widget.colors.error,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    padding: EdgeInsets.zero,
                    // P0-E 修复：触控目标 ≥44x44（移动端可访问性规范）
                    constraints: const BoxConstraints(
                      minWidth: 44,
                      minHeight: 44,
                    ),
                    color: widget.colors.muted,
                    tooltip: t.chat.compaction.close,
                    onPressed: widget.onClose,
                  ),
                ],
              ),
              if (errorText.isNotEmpty) ...[
                Text(
                  errorText,
                  style: LmUiTextStyles.bodySm.copyWith(
                    color: widget.colors.error.withValues(alpha: 0.9),
                  ),
                  maxLines: _isErrorExpanded ? null : 3,
                  overflow: _isErrorExpanded
                      ? TextOverflow.visible
                      : TextOverflow.ellipsis,
                ),
                // 展开/收起按钮（右下角对齐）
                Align(
                  alignment: Alignment.centerRight,
                  child: _ErrorExpandToggle(
                    isExpanded: _isErrorExpanded,
                    colors: widget.colors,
                    expandLabel: t.chat.messageActions.showMore,
                    collapseLabel: t.chat.messageActions.showLess,
                    onTap: () =>
                        setState(() => _isErrorExpanded = !_isErrorExpanded),
                  ),
                ),
              ],
              if (partialContent.isNotEmpty) ...[
                const SizedBox(height: LmSpacing.sXs),
                Divider(
                  height: 1,
                  color: widget.colors.error.withValues(alpha: 0.15),
                ),
                const SizedBox(height: LmSpacing.sXs),
                Text(
                  t.chat.compaction.partialSummaryHint,
                  style: LmUiTextStyles.caption.copyWith(
                    color: widget.colors.muted,
                    fontStyle: FontStyle.italic,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: LmSpacing.sXs),
                SimpleMarkdownBody(data: partialContent),
              ],
              const SizedBox(height: LmSpacing.sXs),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton.icon(
                    onPressed: widget.onRetry,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: Text(
                      t.chat.compaction.retry,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    style: TextButton.styleFrom(
                      foregroundColor: widget.colors.error,
                      padding: const EdgeInsets.symmetric(
                        horizontal: LmSpacing.sSm,
                        vertical: LmSpacing.sXs,
                      ),
                      minimumSize: const Size(0, 32),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 错误展开/收起切换按钮（紧凑型，用于失败卡片内部）。
class _ErrorExpandToggle extends StatelessWidget {
  const _ErrorExpandToggle({
    required this.isExpanded,
    required this.colors,
    required this.expandLabel,
    required this.collapseLabel,
    required this.onTap,
  });

  final bool isExpanded;
  final LmPalette colors;
  final String expandLabel;
  final String collapseLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: LmSpacing.s2xs,
          vertical: LmSpacing.s3xs,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              isExpanded ? collapseLabel : expandLabel,
              style: LmUiTextStyles.overline.copyWith(
                color: colors.error,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(width: LmSpacing.s3xs),
            Icon(
              isExpanded ? Icons.expand_less : Icons.expand_more,
              size: 14,
              color: colors.error,
            ),
          ],
        ),
      ),
    );
  }
}
