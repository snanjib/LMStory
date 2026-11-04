import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/help/presentation/widgets/story_message_actions_diagram.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_page_scaffold.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_section_title.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_step_card.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// Wiki 子页 3.4：故事模式消息操作（2026-07-27 新增）。
///
/// 介绍故事模式的 4 种消息操作 + Fork 窗口限制。
///
/// 设计原则：
/// - 示意图优先，顶部主视觉展示 4 种操作 + 窗口限制
/// - 与对话模式差异点单独说明（无引用 / 无继续生成 / 窗口限制）
/// - 不涉及技术实现细节
class StoryMessageActionsWikiPage extends StatelessWidget {
  const StoryMessageActionsWikiPage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;

    return WikiPageScaffold(
      title: t.help.storyMessageActionsWiki.title,
      children: [
        // 引言
        Text(
          t.help.storyMessageActions.intro,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),

        // 主视觉：4 种操作 + 窗口限制
        WikiSectionTitle(
          title: t.help.storyMessageActions.diagramTitle,
          subtitle: t.help.storyMessageActions.diagramSubtitle,
        ),
        const StoryMessageActionsDiagram(),

        // 4 种操作详解
        WikiSectionTitle(
          title: t.help.storyMessageActions.opsTitle,
          subtitle: '',
        ),
        WikiStepCard(
          step: 1,
          title: t.help.storyMessageActions.op1Title,
          body: t.help.storyMessageActions.op1Body,
        ),
        WikiStepCard(
          step: 2,
          title: t.help.storyMessageActions.op2Title,
          body: t.help.storyMessageActions.op2Body,
        ),
        WikiStepCard(
          step: 3,
          title: t.help.storyMessageActions.op3Title,
          body: t.help.storyMessageActions.op3Body,
        ),
        WikiStepCard(
          step: 4,
          title: t.help.storyMessageActions.op4Title,
          body: t.help.storyMessageActions.op4Body,
        ),

        // Fork 窗口限制
        WikiSectionTitle(
          title: t.help.storyMessageActions.windowTitle,
          subtitle: '',
        ),
        Text(
          t.help.storyMessageActions.windowBody,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),

        // 与对话模式差异
        WikiSectionTitle(
          title: t.help.storyMessageActions.diffTitle,
          subtitle: '',
        ),
        Text(
          t.help.storyMessageActions.diffBody,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),
      ],
    );
  }
}
