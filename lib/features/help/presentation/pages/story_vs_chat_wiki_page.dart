import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/help/presentation/widgets/story_vs_chat_diagram.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_page_scaffold.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_section_title.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_step_card.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// Wiki 子页 3.1：故事模式与对话模式的区别（2026-07-27 新增）。
///
/// 介绍三种模式（对话/故事/导演）的定位、视觉差异、选择建议。
///
/// 设计原则：
/// - 示意图优先，顶部主视觉左右对比两种模式
/// - 选择建议用 WikiStepCard 列出场景化对比
/// - 不涉及技术实现细节
class StoryVsChatWikiPage extends StatelessWidget {
  const StoryVsChatWikiPage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;

    return WikiPageScaffold(
      title: t.help.storyVsChatWiki.title,
      children: [
        // 引言
        Text(
          t.help.storyVsChat.intro,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),

        // 主视觉：双栏对比
        WikiSectionTitle(
          title: t.help.storyVsChat.compareTitle,
          subtitle: t.help.storyVsChat.compareSubtitle,
        ),
        const StoryVsChatDiagram(),

        // 两种模式定位
        WikiSectionTitle(
          title: t.help.storyVsChat.positioningTitle,
          subtitle: '',
        ),
        WikiStepCard(
          step: 1,
          title: t.help.storyVsChat.chatModeTitle,
          body: t.help.storyVsChat.chatModeBody,
        ),
        WikiStepCard(
          step: 2,
          title: t.help.storyVsChat.storyModeTitle,
          body: t.help.storyVsChat.storyModeBody,
        ),
        WikiStepCard(
          step: 3,
          title: t.help.storyVsChat.directorModeTitle,
          body: t.help.storyVsChat.directorModeBody,
        ),

        // 何时选哪个
        WikiSectionTitle(
          title: t.help.storyVsChat.whenTitle,
          subtitle: '',
        ),
        Text(
          t.help.storyVsChat.whenBody,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),

        // 模式切换
        WikiSectionTitle(
          title: t.help.storyVsChat.switchTitle,
          subtitle: '',
        ),
        Text(
          t.help.storyVsChat.switchBody,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),
      ],
    );
  }
}
