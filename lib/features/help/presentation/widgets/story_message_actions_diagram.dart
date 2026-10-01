import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 故事模式消息操作示意图（2026-07-27 新增）。
///
/// 用于「故事模式消息操作」wiki 页顶部主视觉。
///
/// 设计：
/// - 上段：4 种操作图标横排（复制/重新生成/编辑重发/删除整轮）
/// - 下段：Fork 窗口限制示意（最近 N 轮可操作 + 窗口外灰显）
///
/// 视觉传达：故事模式操作按钮 + 窗口限制
/// 注意：图标对齐 intermediate_message_actions.dart 实际代码
class StoryMessageActionsDiagram extends StatelessWidget {
  const StoryMessageActionsDiagram({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 上段：4 种操作
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
                t.help.storyMessageActions.diagramOpsTitle,
                style: SimpleTextStyles.bodySm.copyWith(
                  color: colors.muted,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: SimpleSpacing.sSm),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _OpBadge(
                    icon: Icons.copy_outlined,
                    label: t.help.storyMessageActions.opCopy,
                    color: colors.ink,
                  ),
                  _OpBadge(
                    icon: Icons.refresh_rounded,
                    label: t.help.storyMessageActions.opRegenerate,
                    color: colors.muted,
                  ),
                  _OpBadge(
                    icon: Icons.edit_outlined,
                    label: t.help.storyMessageActions.opEditResend,
                    color: colors.muted,
                  ),
                  _OpBadge(
                    icon: Icons.delete_outline,
                    label: t.help.storyMessageActions.opDeleteRound,
                    color: colors.error,
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: SimpleSpacing.sMd),

        // 下段：Fork 窗口限制
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
                  Icon(Icons.window_outlined, color: colors.primary, size: 16),
                  const SizedBox(width: SimpleSpacing.s2xs),
                  Flexible(
                    child: Text(
                      t.help.storyMessageActions.diagramWindowTitle,
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
                t.help.storyMessageActions.diagramWindowDesc,
                style: SimpleTextStyles.caption.copyWith(
                  color: colors.muted,
                  height: 1.5,
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: SimpleSpacing.sSm),
              // 窗口示意：前几轮灰显，最近 N 轮高亮（：标签入 slang）
              Builder(
                builder: (context) {
                  final t = Translations.of(context);
                  return Row(
                    children: [
                      _RoundChip(
                        label: t.help.flowDiagram.roundN(n: '1'),
                        active: false,
                      ),
                      const SizedBox(width: SimpleSpacing.s2xs),
                      _RoundChip(
                        label: t.help.flowDiagram.roundN(n: '2'),
                        active: false,
                      ),
                      const SizedBox(width: SimpleSpacing.s2xs),
                      _RoundChip(
                        label: t.help.flowDiagram.roundN(n: 'N-1'),
                        active: true,
                      ),
                      const SizedBox(width: SimpleSpacing.s2xs),
                      _RoundChip(
                        label: t.help.flowDiagram.roundN(n: 'N'),
                        active: true,
                      ),
                    ],
                  );
                },
              ),
            ],
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
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(icon, color: color, size: 22),
        const SizedBox(height: SimpleSpacing.s2xs),
        Text(
          label,
          style: SimpleTextStyles.caption.copyWith(
            color: color,
            fontSize: 11,
            fontWeight: FontWeight.w500,
          ),
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

class _RoundChip extends StatelessWidget {
  const _RoundChip({required this.label, required this.active});

  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SimpleSpacing.sSm,
        vertical: SimpleSpacing.s2xs,
      ),
      decoration: BoxDecoration(
        color: active ? colors.primaryDim : colors.surfaceVariant,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.full)),
        border: active ? null : Border.all(color: colors.divider),
      ),
      child: Text(
        label,
        style: SimpleTextStyles.caption.copyWith(
          color: active ? colors.primary : colors.faint,
          fontSize: 11,
          fontWeight: active ? FontWeight.w600 : FontWeight.w400,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
