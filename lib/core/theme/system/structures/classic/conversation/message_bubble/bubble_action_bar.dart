import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';
// =============================================================================
// Message action buttons
// （从 simple_message_bubble.dart 拆出，主文件装配引用）
// =============================================================================

class BubbleMessageActions extends StatefulWidget {
  const BubbleMessageActions({
    required this.isUser,
    required this.messageContent,
    required this.alwaysVisible,
    super.key,
    this.onCopy,
    this.onEdit,
    this.onDelete,
    this.onRegenerate,
    this.onContinueGenerating,
    this.onQuote,
  });

  final bool isUser;
  final String messageContent;
  final bool alwaysVisible;
  final VoidCallback? onCopy;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final VoidCallback? onRegenerate;
  final VoidCallback? onContinueGenerating;
  final VoidCallback? onQuote;

  @override
  State<BubbleMessageActions> createState() => _BubbleMessageActionsState();
}

class _BubbleMessageActionsState extends State<BubbleMessageActions> {
  bool _isVisible = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    // If alwaysVisible is true, show actions without hover/long-press
    final effectiveVisible = widget.alwaysVisible || _isVisible;

    // 不可见时不渲染任何内容——避免留白和"不可见但可点击"的问题
    // (对标 ChatBox: ChatBox 用 opacity-0 保留布局, 但移动端通过 sticky + 三点菜单
    //  保证可用性。LMStory 移动端没有 sticky, 直接不渲染更干净)
    if (!effectiveVisible) {
      return const SizedBox.shrink();
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _isVisible = true),
      onExit: (_) {
        if (!widget.alwaysVisible) {
          setState(() => _isVisible = false);
        }
      },
      child: GestureDetector(
        onLongPressStart: (_) => setState(() => _isVisible = true),
        onLongPressEnd: (_) {
          if (!widget.alwaysVisible) {
            // Keep visible briefly after long press ends so user can tap
            Future.delayed(const Duration(seconds: 3), () {
              if (mounted) setState(() => _isVisible = false);
            });
          }
        },
        child: AnimatedOpacity(
          opacity: 1,
          duration: LmMotion.fast,
          child: Padding(
            padding: const EdgeInsets.only(top: LmSpacing.s2xs),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Regenerate button (assistant messages)
                if (!widget.isUser && widget.onRegenerate != null) ...[
                  _ActionButton(
                    icon: Icons.refresh_rounded,
                    size: 14,
                    color: colors.primary,
                    tooltip: t.chat.regenerate,
                    onTap: widget.onRegenerate!,
                  ),
                  const SizedBox(width: LmSpacing.s2xs),
                ],
                // Continue generating button (user messages)
                if (widget.isUser && widget.onContinueGenerating != null) ...[
                  _ActionButton(
                    icon: Icons.arrow_downward,
                    size: 14,
                    color: colors.primary,
                    tooltip: t.chat.continueGenerating,
                    onTap: widget.onContinueGenerating!,
                  ),
                  const SizedBox(width: LmSpacing.s2xs),
                ],
                // Quote button
                if (widget.onQuote != null) ...[
                  _ActionButton(
                    icon: Icons.format_quote,
                    size: 14,
                    color: colors.muted,
                    tooltip: t.chat.messageActions.quote,
                    onTap: widget.onQuote!,
                  ),
                  const SizedBox(width: LmSpacing.s2xs),
                ],
                if (widget.onCopy != null)
                  _ActionButton(
                    icon: Icons.copy_outlined,
                    size: 14,
                    color: colors.muted,
                    tooltip: t.chat.messageActions.copy,
                    onTap: () {
                      Clipboard.setData(
                        ClipboardData(text: widget.messageContent),
                      );
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(t.chat.messageActions.copySuccess),
                          duration: const Duration(seconds: 1),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                      widget.onCopy?.call();
                    },
                  ),
                if (widget.onEdit != null) ...[
                  SizedBox(
                    width: widget.onCopy != null ? LmSpacing.s2xs : 0,
                  ),
                  _ActionButton(
                    icon: Icons.edit_outlined,
                    size: 14,
                    color: colors.muted,
                    tooltip: t.chat.messageActions.edit,
                    onTap: widget.onEdit!,
                  ),
                ],
                if (widget.onDelete != null) ...[
                  SizedBox(
                    width: (widget.onCopy != null || widget.onEdit != null)
                        ? LmSpacing.s2xs
                        : 0,
                  ),
                  _ActionButton(
                    icon: Icons.delete_outline,
                    size: 14,
                    color: colors.faint,
                    tooltip: t.chat.messageActions.delete,
                    onTap: () async {
                      // 删除确认对话框，避免误触
                      final confirmed = await showLmDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: Text(
                            t.chat.messageActions.delete,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          content: Text(
                            t.chat.messageActions.deleteConfirm,
                            maxLines: 5,
                            overflow: TextOverflow.ellipsis,
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.of(ctx).pop(false),
                              child: Text(
                                t.common.cancel,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            TextButton(
                              onPressed: () => Navigator.of(ctx).pop(true),
                              style: TextButton.styleFrom(
                                foregroundColor: colors.error,
                              ),
                              child: Text(
                                t.common.confirm,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      );
                      if (confirmed ?? false) {
                        widget.onDelete!();
                      }
                    },
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.size,
    required this.color,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final double size;
  final Color color;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
        child: Padding(
          // 扩大点击区域（满足触控目标要求，兼顾操作栏紧凑性）
          padding: const EdgeInsets.all(LmSpacing.sMd),
          child: Icon(icon, size: size, color: color),
        ),
      ),
    );
  }
}
