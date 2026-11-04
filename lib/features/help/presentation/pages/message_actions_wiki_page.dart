import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/help/presentation/widgets/message_actions_diagram.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_page_scaffold.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_section_title.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_step_card.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 对话模式 wiki 子页 2.3：消息操作（2026-07-27 新增）。
///
/// 介绍 5 种消息操作（复制/编辑/重发/引用/删除）和按钮显示策略。
class MessageActionsWikiPage extends StatelessWidget {
  const MessageActionsWikiPage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;

    return WikiPageScaffold(
      title: t.help.messageActionsWiki.title,
      children: [
        // 引言
        Text(
          t.help.messageActions.intro,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),

        // 主视觉：消息气泡结构 + 5 种操作
        WikiSectionTitle(
          title: t.help.messageActions.bubbleTitle,
          subtitle: t.help.messageActions.bubbleSubtitle,
        ),
        const MessageActionsDiagram(),

        // 6 种操作
        WikiSectionTitle(
          title: t.help.messageActions.opsTitle,
          subtitle: '',
        ),
        WikiStepCard(
          step: 1,
          title: t.help.messageActions.op1Title,
          body: t.help.messageActions.op1Body,
        ),
        WikiStepCard(
          step: 2,
          title: t.help.messageActions.op2Title,
          body: t.help.messageActions.op2Body,
        ),
        WikiStepCard(
          step: 3,
          title: t.help.messageActions.op3Title,
          body: t.help.messageActions.op3Body,
        ),
        WikiStepCard(
          step: 4,
          title: t.help.messageActions.op4Title,
          body: t.help.messageActions.op4Body,
        ),
        WikiStepCard(
          step: 5,
          title: t.help.messageActions.op5Title,
          body: t.help.messageActions.op5Body,
        ),
        WikiStepCard(
          step: 6,
          title: t.help.messageActions.op6Title,
          body: t.help.messageActions.op6Body,
        ),

        // 分支说明
        WikiSectionTitle(
          title: t.help.messageActions.forkTitle,
          subtitle: '',
        ),
        Text(
          t.help.messageActions.forkBody,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),
      ],
    );
  }
}
