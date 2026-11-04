import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/help/presentation/widgets/floating_nav_diagram.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_page_scaffold.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_section_title.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_step_card.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 对话模式 wiki 子页 2.4：消息导航（2026-07-27 新增）。
///
/// 介绍 4 个浮动导航按钮和自动隐藏机制。
class MessageNavigationWikiPage extends StatelessWidget {
  const MessageNavigationWikiPage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;

    return WikiPageScaffold(
      title: t.help.messageNavWiki.title,
      children: [
        // 引言
        Text(
          t.help.messageNav.intro,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),

        // 主视觉
        WikiSectionTitle(
          title: t.help.messageNav.buttonsTitle,
          subtitle: t.help.messageNav.buttonsSubtitle,
        ),
        const FloatingNavDiagram(),

        // 4 个按钮说明
        WikiSectionTitle(
          title: t.help.messageNav.opsTitle,
          subtitle: '',
        ),
        WikiStepCard(
          step: 1,
          title: t.help.messageNav.btn1Title,
          body: t.help.messageNav.btn1Body,
        ),
        WikiStepCard(
          step: 2,
          title: t.help.messageNav.btn2Title,
          body: t.help.messageNav.btn2Body,
        ),
        WikiStepCard(
          step: 3,
          title: t.help.messageNav.btn3Title,
          body: t.help.messageNav.btn3Body,
        ),
        WikiStepCard(
          step: 4,
          title: t.help.messageNav.btn4Title,
          body: t.help.messageNav.btn4Body,
        ),

        // 自动隐藏
        WikiSectionTitle(
          title: t.help.messageNav.hideTitle,
          subtitle: '',
        ),
        Text(
          t.help.messageNav.hideBody,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),

        // 会话内搜索（批 K， 手册面补账）
        WikiSectionTitle(
          title: t.help.messageNav.searchTitle,
          subtitle: '',
        ),
        Text(
          t.help.messageNav.searchBody,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),
      ],
    );
  }
}
