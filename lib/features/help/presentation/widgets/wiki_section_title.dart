import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';

/// Wiki 章节标题组件：标题 + 可选副标题。
///
/// 公共组件，供所有 wiki 子页复用（2026-07-27 从 macro_summary_wiki_page
/// 和 story_flow_wiki_page 提取，消除两个文件的私有 _SectionTitle 重复）。
///
/// 设计：
/// - 标题用 title1（22px）+ w700，ink 色
/// - 副标题用 caption（12px），muted 色（非 uppercase eyebrow 套路）
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
    final colors = context.lm.palette;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: SimpleSpacing.sSm),
        Text(
          title,
          style: SimpleTextStyles.title1.copyWith(
            color: colors.ink,
            fontWeight: FontWeight.w700,
          ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        if (subtitle.isNotEmpty) ...[
          const SizedBox(height: SimpleSpacing.s2xs),
          Text(
            subtitle,
            style: SimpleTextStyles.caption.copyWith(color: colors.muted),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ],
        const SizedBox(height: SimpleSpacing.sMd),
      ],
    );
  }
}
