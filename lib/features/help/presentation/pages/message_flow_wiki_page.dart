import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/help/presentation/widgets/message_flow_diagram.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_page_scaffold.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_section_title.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_step_card.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 对话模式 wiki 子页 2.2：发送消息与查看回复（2026-07-27 新增）。
///
/// 介绍输入框结构、流式输出体验、引用与附件。
class MessageFlowWikiPage extends StatelessWidget {
  const MessageFlowWikiPage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;

    return WikiPageScaffold(
      title: t.help.messageFlowWiki.title,
      children: [
        // 引言
        Text(
          t.help.messageFlow.intro,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),

        // 主视觉：输入框结构 + 流式时序
        WikiSectionTitle(
          title: t.help.messageFlow.layoutTitle,
          subtitle: t.help.messageFlow.layoutSubtitle,
        ),
        const MessageFlowDiagram(),

        // 输入框要点
        WikiSectionTitle(
          title: t.help.messageFlow.inputTipsTitle,
          subtitle: '',
        ),
        WikiStepCard(
          step: 1,
          title: t.help.messageFlow.tip1Title,
          body: t.help.messageFlow.tip1Body,
        ),
        WikiStepCard(
          step: 2,
          title: t.help.messageFlow.tip2Title,
          body: t.help.messageFlow.tip2Body,
        ),
        WikiStepCard(
          step: 3,
          title: t.help.messageFlow.tip3Title,
          body: t.help.messageFlow.tip3Body,
        ),

        // 流式输出体验
        WikiSectionTitle(
          title: t.help.messageFlow.streamTitle,
          subtitle: '',
        ),
        Text(
          t.help.messageFlow.streamBody,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),
      ],
    );
  }
}
