import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 提示词模板系统示意图（2026-07-27 新增）。
///
/// 用于「提示词模板系统」wiki 页顶部主视觉。
///
/// 设计：
/// - 上段：2 种当前可用模板类型（系统提示词 / 压缩模板）
/// - 下段：4 种操作（新增 / 编辑 / 复制 / 删除）
class PromptTemplateDiagram extends StatelessWidget {
  const PromptTemplateDiagram({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 上段：2 种当前可用模板类型
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
                t.help.promptTemplate.diagramTypesTitle,
                style: SimpleTextStyles.bodySm.copyWith(
                  color: colors.muted,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: SimpleSpacing.sSm),
              Row(
                children: [
                  Expanded(
                    child: _TypeCard(
                      icon: Icons.description_outlined,
                      label: t.help.promptTemplate.typeSystem,
                      desc: t.help.promptTemplate.typeSystemDesc,
                      highlight: true,
                    ),
                  ),
                  const SizedBox(width: SimpleSpacing.sXs),
                  Expanded(
                    child: _TypeCard(
                      icon: Icons.compress_outlined,
                      label: t.help.promptTemplate.typeConsolidation,
                      desc: t.help.promptTemplate.typeConsolidationDesc,
                      highlight: false,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: SimpleSpacing.sMd),

        // 下段：4 种操作
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
              Text(
                t.help.promptTemplate.diagramOpsTitle,
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
                    icon: Icons.add_circle_outline,
                    label: t.help.promptTemplate.opCreate,
                    color: colors.success,
                  ),
                  _OpBadge(
                    icon: Icons.edit_outlined,
                    label: t.help.promptTemplate.opEdit,
                    color: colors.primary,
                  ),
                  _OpBadge(
                    icon: Icons.copy_outlined,
                    label: t.help.promptTemplate.opCopy,
                    color: colors.muted,
                  ),
                  _OpBadge(
                    icon: Icons.delete_outline,
                    label: t.help.promptTemplate.opDelete,
                    color: colors.error,
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TypeCard extends StatelessWidget {
  const _TypeCard({
    required this.icon,
    required this.label,
    required this.desc,
    required this.highlight,
  });

  final IconData icon;
  final String label;
  final String desc;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Container(
      padding: const EdgeInsets.all(SimpleSpacing.sSm),
      decoration: BoxDecoration(
        color: highlight ? colors.primaryDim : colors.surface,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
        border: Border.all(color: highlight ? colors.primary : colors.divider),
      ),
      child: Column(
        children: [
          Icon(
            icon,
            color: highlight ? colors.primary : colors.muted,
            size: 20,
          ),
          const SizedBox(height: SimpleSpacing.s2xs),
          Text(
            label,
            style: SimpleTextStyles.caption.copyWith(
              color: highlight ? colors.primary : colors.ink,
              fontWeight: FontWeight.w600,
            ),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: SimpleSpacing.s2xs),
          Text(
            desc,
            style: SimpleTextStyles.caption.copyWith(
              color: colors.muted,
              fontSize: 10,
              height: 1.3,
            ),
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
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
