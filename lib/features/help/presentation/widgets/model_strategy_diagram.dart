import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 模型选择策略示意图（2026-07-27 新增）。
///
/// 用于「模型选择策略」wiki 页顶部主视觉。
///
/// 设计：
/// - 上段：3 层优先级（全局默认 → 会话级覆盖 → 故事 4 步骤）
/// - 下段：故事模式 4 步骤（生成/提取/审查/摘要）
class ModelStrategyDiagram extends StatelessWidget {
  const ModelStrategyDiagram({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 上段：3 层优先级
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
                t.help.modelStrategy.diagramLayersTitle,
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
                    child: _LayerItem(
                      icon: Icons.public_outlined,
                      label: t.help.modelStrategy.layer1Label,
                      desc: t.help.modelStrategy.layer1Desc,
                      highlight: true,
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    color: colors.faint,
                    size: 18,
                  ),
                  Expanded(
                    child: _LayerItem(
                      icon: Icons.layers_outlined,
                      label: t.help.modelStrategy.layer2Label,
                      desc: t.help.modelStrategy.layer2Desc,
                      highlight: false,
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    color: colors.faint,
                    size: 18,
                  ),
                  Expanded(
                    child: _LayerItem(
                      icon: Icons.timeline_outlined,
                      label: t.help.modelStrategy.layer3Label,
                      desc: t.help.modelStrategy.layer3Desc,
                      highlight: false,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: SimpleSpacing.sMd),

        // 下段：故事模式 4 步骤
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
                t.help.modelStrategy.diagramStoryTitle,
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
                  _PhaseBadge(
                    icon: Icons.edit_outlined,
                    label: t.help.modelStrategy.storyGenerating,
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    color: colors.faint,
                    size: 16,
                  ),
                  _PhaseBadge(
                    icon: Icons.search_outlined,
                    label: t.help.modelStrategy.storyExtracting,
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    color: colors.faint,
                    size: 16,
                  ),
                  _PhaseBadge(
                    icon: Icons.auto_fix_high_outlined,
                    label: t.help.modelStrategy.storyReviewing,
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    color: colors.faint,
                    size: 16,
                  ),
                  _PhaseBadge(
                    icon: Icons.summarize_outlined,
                    label: t.help.modelStrategy.storySummarizing,
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

class _LayerItem extends StatelessWidget {
  const _LayerItem({
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
            size: 18,
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

class _PhaseBadge extends StatelessWidget {
  const _PhaseBadge({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Column(
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: colors.primaryDim,
            borderRadius:
                BorderRadius.circular(context.lmUi.radius(LmCorner.full)),
          ),
          alignment: Alignment.center,
          child: Icon(icon, color: colors.primary, size: 14),
        ),
        const SizedBox(height: SimpleSpacing.s2xs),
        Text(
          label,
          style: SimpleTextStyles.caption.copyWith(
            color: colors.ink,
            fontSize: 10,
            fontWeight: FontWeight.w600,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}
