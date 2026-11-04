import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/help/presentation/widgets/first_story_flow_diagram.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_page_scaffold.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_section_title.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_step_card.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// Wiki 子页 3.2：创建第一个故事（2026-07-27 新增）。
///
/// 介绍从零开始创建一个故事会话的完整流程。
///
/// 设计原则：
/// - 示意图优先，顶部主视觉展示 3 步流程 + 嵌入模型缺失提示
/// - 配置项分步说明，避免堆砌
/// - 重点强调嵌入模型配置（语义检索依赖）
class FirstStoryWikiPage extends StatelessWidget {
  const FirstStoryWikiPage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;

    return WikiPageScaffold(
      title: t.help.firstStoryWiki.title,
      children: [
        // 引言
        Text(
          t.help.firstStory.intro,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),

        // 主视觉：3 步流程 + Banner
        WikiSectionTitle(
          title: t.help.firstStory.flowTitle,
          subtitle: t.help.firstStory.flowSubtitle,
        ),
        const FirstStoryFlowDiagram(),

        // 3 步详解
        WikiSectionTitle(
          title: t.help.firstStory.stepsTitle,
          subtitle: '',
        ),
        WikiStepCard(
          step: 1,
          title: t.help.firstStory.step1Title,
          body: t.help.firstStory.step1Body,
        ),
        WikiStepCard(
          step: 2,
          title: t.help.firstStory.step2Title,
          body: t.help.firstStory.step2Body,
        ),
        WikiStepCard(
          step: 3,
          title: t.help.firstStory.step3Title,
          body: t.help.firstStory.step3Body,
        ),

        // 系统提示词
        WikiSectionTitle(
          title: t.help.firstStory.promptTitle,
          subtitle: '',
        ),
        Text(
          t.help.firstStory.promptBody,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),

        // 嵌入模型
        WikiSectionTitle(
          title: t.help.firstStory.embeddingTitle,
          subtitle: '',
        ),
        Text(
          t.help.firstStory.embeddingBody,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),

        // 首条消息
        WikiSectionTitle(
          title: t.help.firstStory.firstMessageTitle,
          subtitle: '',
        ),
        Text(
          t.help.firstStory.firstMessageBody,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),
      ],
    );
  }
}
