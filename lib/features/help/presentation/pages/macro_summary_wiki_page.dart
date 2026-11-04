import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/help/presentation/widgets/macro_summary_overview_diagram.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_page_scaffold.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_section_title.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 故事模式 wiki 子页 4：宏摘要机制（2026-07-26 新增）。
///
/// 通俗解释宏摘要的双触发机制、边界跳过、失败降级、UI 表现。
///
/// 设计原则（遵循用户要求）：
/// - 示意图优先，拒绝大段文字
/// - 顶部主视觉图展示微摘要→宏摘要的聚合关系
/// - 双触发用并列卡片（icon + 标题 + 短句说明）
/// - 边界跳过/失败降级/UI 表现用 WikiSection 短文
///
/// 内容来源：DOC-10 v1.1、DOC-06B §6.3B、DOC-09A-1 §1.2。
class MacroSummaryWikiPage extends StatelessWidget {
  const MacroSummaryWikiPage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;

    return WikiPageScaffold(
      title: t.help.macroWiki.title,
      children: [
        // 引言
        Text(
          t.help.macroWiki.intro,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),

        // 主视觉：微摘要与宏摘要关系示意图
        WikiSectionTitle(
          title: t.help.macroWiki.overviewTitle,
          subtitle: t.help.macroWiki.overviewSubtitle,
        ),
        const MacroSummaryOverviewDiagram(),

        // 双触发机制：并列卡片
        WikiSectionTitle(
          title: t.help.macroWiki.triggersTitle,
          subtitle: t.help.macroWiki.triggersSubtitle,
        ),
        _TriggerCard(
          icon: Icons.flag_outlined,
          title: t.help.macroWiki.trigger1Title,
          body: t.help.macroWiki.trigger1Body,
        ),
        const SizedBox(height: SimpleSpacing.sSm),
        _TriggerCard(
          icon: Icons.timer_outlined,
          title: t.help.macroWiki.trigger2Title,
          body: t.help.macroWiki.trigger2Body,
        ),

        // 边界跳过
        WikiSectionTitle(
          title: t.help.macroWiki.skipTitle,
          subtitle: '',
        ),
        Text(
          t.help.macroWiki.skipBody,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),

        // 失败降级
        WikiSectionTitle(
          title: t.help.macroWiki.fallbackTitle,
          subtitle: '',
        ),
        Text(
          t.help.macroWiki.fallbackBody,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),

        // UI 表现
        WikiSectionTitle(
          title: t.help.macroWiki.uiTitle,
          subtitle: '',
        ),
        Text(
          t.help.macroWiki.uiBody,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),
      ],
    );
  }
}

/// 双触发卡片：图标 + 标题 + 短句说明。
///
/// 设计：横向排列，图标 badge 在左，文字在右。
/// 用 surfaceVariant 底 + rLg 圆角，与 SimpleSettingCard 风格一致但更紧凑。
class _TriggerCard extends StatelessWidget {
  const _TriggerCard({
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
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: colors.primaryDim,
              borderRadius:
                  BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
            ),
            child: Icon(icon, color: colors.primary, size: 20),
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
