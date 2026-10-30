import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_button_metrics.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';

/// 向导整行描边选项（「选中即解释」范式的载体，贯穿模型/嵌入/规则步）。
///
/// 视觉参照设置页 _TemplateCard 选中容器：选中 = primaryDim 底 +
/// primary 1.5 描边；未选 = surfaceVariant 底无描边；触控高 ≥ 44。
/// [description] 未选中时常显（这个选项是干什么的）；选中后行下方
/// 追加 [explanation]（选了它意味着什么）——两者合起来实现向导区别
/// 于设置页的核心交互：选中即解释。
class WizardOptionRow extends StatelessWidget {
  const WizardOptionRow({
    required this.title,
    required this.selected,
    required this.onTap,
    this.description,
    this.explanation,
    this.icon,
    super.key,
  });

  final String title;

  /// 未选中时常显的说明行（选项是干什么的）
  final String? description;

  /// 选中后行下方追加的解释行（选了它意味着什么）
  final String? explanation;

  /// 左侧图标徽章（缺省不渲染徽章列）
  final IconData? icon;

  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          decoration: BoxDecoration(
            color: selected ? colors.primaryDim : colors.surfaceVariant,
            borderRadius: BorderRadius.circular(
              context.lmUi.radius(LmCorner.lg),
            ),
            border:
                selected ? Border.all(color: colors.primary, width: 1.5) : null,
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(
                context.lmUi.radius(LmCorner.lg),
              ),
              child: Padding(
                padding: const EdgeInsets.all(SimpleSpacing.sMd),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    minHeight: LmButtonMetrics.minInteractiveHeight,
                  ),
                  child: Row(
                    children: [
                      if (icon != null) ...[
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: selected
                                ? colors.primary.withValues(alpha: 0.15)
                                : colors.primaryDim,
                            borderRadius: BorderRadius.circular(
                              context.lmUi.radius(LmCorner.md),
                            ),
                          ),
                          child: Icon(
                            icon,
                            size: 20,
                            color: selected ? colors.primary : colors.muted,
                          ),
                        ),
                        const SizedBox(width: SimpleSpacing.sMd),
                      ],
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              title,
                              style: SimpleTextStyles.body.copyWith(
                                fontWeight: FontWeight.w600,
                                color: colors.ink,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (description != null) ...[
                              const SizedBox(height: SimpleSpacing.s2xs),
                              Text(
                                description!,
                                style: SimpleTextStyles.caption.copyWith(
                                  color: colors.muted,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ],
                        ),
                      ),
                      Icon(
                        Icons.chevron_right,
                        color: selected ? colors.primary : colors.muted,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        if (selected && explanation != null)
          Padding(
            padding: const EdgeInsets.only(
              top: SimpleSpacing.sXs,
              left: SimpleSpacing.sMd,
            ),
            child: WizardExplanationLine(text: explanation!),
          ),
      ],
    );
  }
}

/// ✓ + 一行 caption 解释（选中态/选中行摘要共用）。
class WizardExplanationLine extends StatelessWidget {
  const WizardExplanationLine({required this.text, super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.check_circle, size: 16, color: colors.success),
        const SizedBox(width: SimpleSpacing.sXs),
        Expanded(
          child: Text(
            text,
            style: SimpleTextStyles.caption.copyWith(color: colors.muted),
          ),
        ),
      ],
    );
  }
}
