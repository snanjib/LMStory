import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/shared/components/section_heading.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';

/// Wiki 章节卡片：标题 + 正文段落（无步骤编号）。
///
/// 用于记忆机制 / 失败处理等子页的章节展示。
/// 设计原则：
/// - 不用嵌套卡片（避免「卡片里套卡片」的 AI slop）
/// - 章节之间靠 spacing 节奏区分，不靠 border 或 background
/// - 使用公共章节标题，正文用 body（15px / 行高 1.7 提升可读性）
class WikiSection extends StatelessWidget {
  const WikiSection({
    required this.title,
    required this.body,
    super.key,
  });

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeading(title: title),
        const SizedBox(height: SimpleSpacing.sSm),
        Text(
          body,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),
      ],
    );
  }
}
