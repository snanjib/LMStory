import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/shared/components/section_heading.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_data.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_entry_view.dart';

/// Wiki 章节视图：章节标题 + 副标题 + 条目列表。
///
/// 设计：拒绝嵌套卡片，章节标题与副标题使用公共层级，
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 章节标题
        Padding(
          padding: const EdgeInsets.only(
            top: SimpleSpacing.sMd,
            bottom: SimpleSpacing.s2xs,
          ),
          child: SectionHeading(
            title: section.title,
            subtitle: section.subtitle,
          ),
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
