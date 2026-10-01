import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/help/presentation/widgets/home_layout_diagram.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_page_scaffold.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_section_title.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// Wiki 子页 1.2：界面总览（2026-07-27 新增）。
///
/// 通俗介绍主界面的布局：首页结构 + 侧边栏结构 + 模式切换入口。
///
/// 设计原则（遵循用户要求）：
/// - 示意图优先，拒绝大段文字
/// - 顶部主视觉图展示首页布局（HomeLayoutDiagram）
/// - 侧边栏用 4 个紧凑卡片展示 4 个区域
/// - 模式切换用独立卡片强调"通过双卡入口实现"
///
/// 内容来源：home_page.dart 和 chat_sidebar.dart 实际实现。
class HomeOverviewWikiPage extends StatelessWidget {
  const HomeOverviewWikiPage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;

    return WikiPageScaffold(
      title: t.help.homeOverviewWiki.title,
      children: [
        // 引言
        Text(
          t.help.homeOverview.intro,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),

        // 主视觉：首页布局示意图
        WikiSectionTitle(
          title: t.help.homeOverview.layoutTitle,
          subtitle: t.help.homeOverview.layoutSubtitle,
        ),
        const HomeLayoutDiagram(),

        // 侧边栏：4 个区域
        WikiSectionTitle(
          title: t.help.homeOverview.sidebarTitle,
          subtitle: t.help.homeOverview.sidebarSubtitle,
        ),
        _SidebarBlock(
          icon: Icons.vertical_align_top_outlined,
          label: t.help.homeOverview.sidebarHeaderLabel,
          desc: t.help.homeOverview.sidebarHeaderDesc,
        ),
        const SizedBox(height: SimpleSpacing.sSm),
        _SidebarBlock(
          icon: Icons.search_outlined,
          label: t.help.homeOverview.sidebarSearchLabel,
          desc: t.help.homeOverview.sidebarSearchDesc,
        ),
        const SizedBox(height: SimpleSpacing.sSm),
        _SidebarBlock(
          icon: Icons.list_outlined,
          label: t.help.homeOverview.sidebarListLabel,
          desc: t.help.homeOverview.sidebarListDesc,
        ),
        const SizedBox(height: SimpleSpacing.sSm),
        _SidebarBlock(
          icon: Icons.vertical_align_bottom_outlined,
          label: t.help.homeOverview.sidebarFooterLabel,
          desc: t.help.homeOverview.sidebarFooterDesc,
        ),

        // 模式切换说明
        WikiSectionTitle(
          title: t.help.homeOverview.modeSwitchTitle,
          subtitle: '',
        ),
        _ModeSwitchCard(
          icon: Icons.swap_horiz_outlined,
          title: t.help.homeOverview.modeSwitchCardTitle,
          body: t.help.homeOverview.modeSwitchCardBody,
        ),
      ],
    );
  }
}

/// 侧边栏区域卡片：图标 + 标签 + 描述（紧凑横向排列）。
///
/// 设计：与首页布局区块风格一致，用 surfaceVariant 底 + rMd 圆角。
class _SidebarBlock extends StatelessWidget {
  const _SidebarBlock({
    required this.icon,
    required this.label,
    required this.desc,
  });

  final IconData icon;
  final String label;
  final String desc;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Container(
      padding: const EdgeInsets.all(SimpleSpacing.sMd),
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
      ),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius:
                  BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
            ),
            child: Icon(icon, color: colors.primary, size: 18),
          ),
          const SizedBox(width: SimpleSpacing.sSm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: SimpleTextStyles.body.copyWith(
                    color: colors.ink,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  desc,
                  style: SimpleTextStyles.caption.copyWith(
                    color: colors.muted,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 模式切换说明卡片：用 accent 色调强调"通过双卡入口实现"。
class _ModeSwitchCard extends StatelessWidget {
  const _ModeSwitchCard({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Container(
      padding: const EdgeInsets.all(SimpleSpacing.sMd),
      decoration: BoxDecoration(
        color: colors.accentDim,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: colors.accent,
              borderRadius:
                  BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
            ),
            child: Icon(icon, color: colors.surface, size: 20),
          ),
          const SizedBox(width: SimpleSpacing.sSm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: SimpleTextStyles.body.copyWith(
                    color: colors.ink,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  body,
                  style: SimpleTextStyles.caption.copyWith(
                    color: colors.muted,
                    height: 1.6,
                  ),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
