import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';

/// Wiki 步骤卡片：步骤编号 + 标题 + 正文。
///
/// 专门用于四步生成流程子页。步骤编号是真实有序序列（1→2→3→4→5→6），
/// 不是装饰性「01/02/03」scaffolding。
///
/// 设计：
/// - 步骤编号用 primary 色填充的圆形 badge，36px
/// - 标题用 title2（18px），强调「第 N 步：xxx」
/// - 正文用 body（15px / 行高 1.7）
/// - 编号和文字水平排列，文字 Expanded 撑满
class WikiStepCard extends StatelessWidget {
  const WikiStepCard({
    required this.step,
    required this.title,
    required this.body,
    super.key,
  });

  final int step;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
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
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(width: SimpleSpacing.sMd),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: SimpleTextStyles.title2.copyWith(
                  color: colors.ink,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: SimpleSpacing.sXs),
              Text(
                body,
                style: SimpleTextStyles.body.copyWith(
                  color: colors.muted,
                  height: 1.7,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
