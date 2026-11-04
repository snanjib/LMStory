import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 增强版步骤卡片：步骤编号 + 图标 + 标题 + 输入/输出示意图 + 要点列表。
///
/// 用于四步流程页的 6 个步骤详解，比原 WikiStepCard 视觉信息更丰富。
///
/// 设计：
/// - 顶部：编号 badge + 图标 badge + 标题（横向）
/// - 中部：[输入] → [输出] 流程图（两个标签卡片 + 中间箭头）
/// - 底部：要点列表（圆点前缀 + 短句）
/// - 整体在 surface 容器内（这里是必要的卡片嵌套，承载多个子元素）
class FlowStepCard extends StatelessWidget {
  const FlowStepCard({
    required this.step,
    required this.icon,
    required this.title,
    required this.input,
    required this.output,
    required this.keyPoints,
    super.key,
  });

  final int step;
  final IconData icon;
  final String title;
  final String input;
  final String output;
  final List<String> keyPoints;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Container(
      padding: const EdgeInsets.all(SimpleSpacing.sLg),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
        border: Border.all(color: colors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 顶部：编号 + 图标 + 标题
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: colors.primary,
                  borderRadius:
                      BorderRadius.circular(context.lmUi.radius(LmCorner.full)),
                ),
                alignment: Alignment.center,
                child: Text(
                  '$step',
                  style: SimpleTextStyles.bodySm.copyWith(
                    color: colors.surface,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: SimpleSpacing.sSm),
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: colors.primaryDim,
                  borderRadius:
                      BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
                ),
                child: Icon(icon, color: colors.primary, size: 22),
              ),
              const SizedBox(width: SimpleSpacing.sMd),
              Expanded(
                child: Text(
                  title,
                  style: SimpleTextStyles.title2.copyWith(
                    color: colors.ink,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: SimpleSpacing.sMd),
          // 中部：输入 → 输出 流程图
          Row(
            children: [
              Expanded(
                child: _InputOutputBox(
                  label: Translations.of(context).help.flowDiagram.inputLabel,
                  value: input,
                  valueColor: colors.muted,
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: SimpleSpacing.sXs,
                ),
                child: Icon(
                  Icons.arrow_forward,
                  color: colors.faint,
                  size: 18,
                ),
              ),
              Expanded(
                child: _InputOutputBox(
                  label: Translations.of(context).help.flowDiagram.outputLabel,
                  value: output,
                  valueColor: colors.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: SimpleSpacing.sMd),
          // 底部：要点列表
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: keyPoints
                .map(
                  (point) => Padding(
                    padding: const EdgeInsets.only(
                      bottom: SimpleSpacing.s2xs,
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 7),
                          child: Container(
                            width: 4,
                            height: 4,
                            decoration: BoxDecoration(
                              color: colors.primary,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                        const SizedBox(width: SimpleSpacing.sSm),
                        Expanded(
                          child: Text(
                            point,
                            style: SimpleTextStyles.bodySm.copyWith(
                              color: colors.muted,
                              height: 1.6,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                )
                .toList(),
          ),
        ],
      ),
    );
  }
}

/// 输入/输出小标签卡片。
class _InputOutputBox extends StatelessWidget {
  const _InputOutputBox({
    required this.label,
    required this.value,
    required this.valueColor,
  });

  final String label;
  final String value;
  final Color valueColor;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SimpleSpacing.sSm,
        vertical: SimpleSpacing.sXs,
      ),
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: SimpleTextStyles.overline.copyWith(color: colors.faint),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: SimpleTextStyles.bodySm.copyWith(
              color: valueColor,
              fontWeight: FontWeight.w500,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
