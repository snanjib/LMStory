import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 消息操作示意图（2026-07-27 新增）。
///
/// 用于「消息操作」wiki 页顶部主视觉。
///
/// 设计：
/// - 上段：消息气泡结构（用户消息 + 助手消息 + 操作按钮行）
/// - 下段：5 个操作图标矩阵（复制/编辑/重发/引用/删除）
///
/// 视觉传达：操作按钮的位置 + 5 种操作的图标语义
class MessageActionsDiagram extends StatelessWidget {
  const MessageActionsDiagram({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 上段：消息气泡结构
        Container(
          padding: const EdgeInsets.all(SimpleSpacing.sMd),
          decoration: BoxDecoration(
            color: colors.surfaceVariant,
            borderRadius:
                BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                t.help.messageActions.diagramBubbleTitle,
                style: SimpleTextStyles.bodySm.copyWith(
                  color: colors.muted,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: SimpleSpacing.sSm),
              // 用户消息气泡
              _MiniBubble(
                label: t.help.messageActions.userBubbleLabel,
                role: 'user',
              ),
              const SizedBox(height: SimpleSpacing.sSm),
              // 助手消息气泡 + 操作按钮
              _MiniBubble(
                label: t.help.messageActions.assistantBubbleLabel,
                role: 'assistant',
              ),
              const SizedBox(height: SimpleSpacing.s2xs),
              // 操作按钮行（点击消息气泡显示，3 秒后自动隐藏）
              Padding(
                padding: const EdgeInsets.only(left: SimpleSpacing.sXl),
                child: Wrap(
                  spacing: SimpleSpacing.sMd,
                  runSpacing: SimpleSpacing.s2xs,
                  children: [
                    _OpBadge(
                      icon: Icons.refresh_rounded,
                      label: t.help.messageActions.opRegenerate,
                    ),
                    _OpBadge(
                      icon: Icons.arrow_downward,
                      label: t.help.messageActions.opContinue,
                    ),
                    _OpBadge(
                      icon: Icons.format_quote,
                      label: t.help.messageActions.opQuote,
                    ),
                    _OpBadge(
                      icon: Icons.copy_outlined,
                      label: t.help.messageActions.opCopy,
                    ),
                    _OpBadge(
                      icon: Icons.edit_outlined,
                      label: t.help.messageActions.opEdit,
                    ),
                    _OpBadge(
                      icon: Icons.delete_outline,
                      label: t.help.messageActions.opDelete,
                      color: colors.error,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: SimpleSpacing.sMd),

        // 下段：显示策略说明
        Container(
          padding: const EdgeInsets.all(SimpleSpacing.sMd),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius:
                BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
            border: Border.all(color: colors.divider),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.touch_app_outlined,
                    color: colors.primary,
                    size: 16,
                  ),
                  const SizedBox(width: SimpleSpacing.s2xs),
                  Flexible(
                    child: Text(
                      t.help.messageActions.diagramStrategyTitle,
                      style: SimpleTextStyles.bodySm.copyWith(
                        color: colors.ink,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: SimpleSpacing.s2xs),
              Text(
                t.help.messageActions.diagramStrategyDesc,
                style: SimpleTextStyles.caption.copyWith(
                  color: colors.muted,
                  height: 1.5,
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MiniBubble extends StatelessWidget {
  const _MiniBubble({required this.label, required this.role});

  final String label;
  final String role;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final isUser = role == 'user';

    return Row(
      mainAxisAlignment:
          isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: isUser ? colors.primary : colors.surface,
            shape: BoxShape.circle,
          ),
          child: Icon(
            isUser ? Icons.person_outline : Icons.smart_toy_outlined,
            color: isUser ? colors.surface : colors.primary,
            size: 16,
          ),
        ),
        const SizedBox(width: SimpleSpacing.s2xs),
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: SimpleSpacing.sSm,
              vertical: SimpleSpacing.s2xs,
            ),
            decoration: BoxDecoration(
              color: isUser ? colors.primaryDim : colors.surface,
              borderRadius:
                  BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
            ),
            child: Text(
              label,
              style: SimpleTextStyles.caption.copyWith(
                color: colors.ink,
                fontSize: 11,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ],
    );
  }
}

class _OpBadge extends StatelessWidget {
  const _OpBadge({
    required this.icon,
    required this.label,
    this.color,
  });

  final IconData icon;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final actualColor = color ?? colors.muted;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: actualColor, size: 14),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            label,
            style: SimpleTextStyles.caption.copyWith(
              color: actualColor,
              fontSize: 11,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
