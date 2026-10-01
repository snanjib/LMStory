import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_data.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_entry_view.dart';

/// Wiki 章节视图：章节标题 + 副标题 + 条目列表。
///
/// 设计：拒绝嵌套卡片，章节标题用 title1 + caption 的层级组合，
/// 条目之间用 sSm 间距呼吸；章节间用 sLg 间距区分。
class WikiSectionView extends StatelessWidget {
  const WikiSectionView({
    required this.section,
    required this.isLast,
    super.key,
  });

  final WikiSection section;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 章节标题
        Padding(
          padding: const EdgeInsets.only(
            top: SimpleSpacing.sMd,
            bottom: SimpleSpacing.s2xs,
          ),
          child: Text(
            section.title,
            style: SimpleTextStyles.title1.copyWith(
              color: colors.ink,
              fontWeight: FontWeight.w700,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        // 章节副标题
        Text(
          section.subtitle,
          style: SimpleTextStyles.caption.copyWith(color: colors.muted),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: SimpleSpacing.sMd),
        // 条目列表
        for (int i = 0; i < section.entries.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: SimpleSpacing.sSm),
            child: WikiEntryView(entry: section.entries[i]),
          ),
        // 章节间分隔（最后一个不加）
        if (!isLast) const SizedBox(height: SimpleSpacing.sLg),
      ],
    );
  }
}
