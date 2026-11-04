import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/shared/components/section_heading.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';

/// Wiki 章节标题组件：标题 + 可选副标题。
///
/// 公共组件，供所有 wiki 子页复用（2026-07-27 从 macro_summary_wiki_page
/// 和 story_flow_wiki_page 提取，消除两个文件的私有 _SectionTitle 重复）。
///
/// 设计：
/// - 公共章节标题使用衬线字体，ink 色
/// - 副标题使用 UI 正文，muted 色
/// - 顶部 sSm 间距，与上一个章节分隔
/// - 副标题为空字符串时不渲染副标题区域
class WikiSectionTitle extends StatelessWidget {
  const WikiSectionTitle({
    required this.title,
    required this.subtitle,
    super.key,
  });

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: SimpleSpacing.sSm),
        SectionHeading(title: title, subtitle: subtitle),
        const SizedBox(height: SimpleSpacing.sMd),
      ],
    );
  }
}
