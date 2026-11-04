import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/help/presentation/widgets/story_prompt_custom_diagram.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_page_scaffold.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_section_title.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_step_card.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// Wiki 子页 5.4：故事模式提示词自定义（2026-07-27 新增）。
class StoryPromptCustomWikiPage extends StatelessWidget {
  const StoryPromptCustomWikiPage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;

    return WikiPageScaffold(
      title: t.help.storyPromptCustomWiki.title,
      children: [
        Text(
          t.help.storyPromptCustom.intro,
          style:
              SimpleTextStyles.body.copyWith(color: colors.muted, height: 1.7),
        ),
        WikiSectionTitle(
          title: t.help.storyPromptCustom.diagramTitle,
          subtitle: t.help.storyPromptCustom.diagramSubtitle,
        ),
        const StoryPromptCustomDiagram(),
        WikiSectionTitle(
          title: t.help.storyPromptCustom.stepsTitle,
          subtitle: '',
        ),
        WikiStepCard(
          step: 1,
          title: t.help.storyPromptCustom.step1Title,
          body: t.help.storyPromptCustom.step1Body,
        ),
        WikiStepCard(
          step: 2,
          title: t.help.storyPromptCustom.step2Title,
          body: t.help.storyPromptCustom.step2Body,
        ),
        WikiStepCard(
          step: 3,
          title: t.help.storyPromptCustom.step3Title,
          body: t.help.storyPromptCustom.step3Body,
        ),
        WikiStepCard(
          step: 4,
          title: t.help.storyPromptCustom.step4Title,
          body: t.help.storyPromptCustom.step4Body,
        ),
        WikiStepCard(
          step: 5,
          title: t.help.storyPromptCustom.step5Title,
          body: t.help.storyPromptCustom.step5Body,
        ),
        WikiStepCard(
          step: 6,
          title: t.help.storyPromptCustom.step6Title,
          body: t.help.storyPromptCustom.step6Body,
        ),
        WikiStepCard(
          step: 7,
          title: t.help.storyPromptCustom.step7Title,
          body: t.help.storyPromptCustom.step7Body,
        ),
        WikiStepCard(
          step: 8,
          title: t.help.storyPromptCustom.step8Title,
          body: t.help.storyPromptCustom.step8Body,
        ),
        WikiStepCard(
          step: 9,
          title: t.help.storyPromptCustom.step9Title,
          body: t.help.storyPromptCustom.step9Body,
        ),
        WikiStepCard(
          step: 10,
          title: t.help.storyPromptCustom.step10Title,
          body: t.help.storyPromptCustom.step10Body,
        ),
        WikiSectionTitle(
          title: t.help.storyPromptCustom.previewTitle,
          subtitle: '',
        ),
        Text(
          t.help.storyPromptCustom.previewBody,
          style:
              SimpleTextStyles.body.copyWith(color: colors.muted, height: 1.7),
        ),
        WikiSectionTitle(
          title: t.help.storyPromptCustom.dirtyTitle,
          subtitle: '',
        ),
        Text(
          t.help.storyPromptCustom.dirtyBody,
          style:
              SimpleTextStyles.body.copyWith(color: colors.muted, height: 1.7),
        ),
        WikiSectionTitle(
          title: t.help.storyPromptCustom.entryTitle,
          subtitle: '',
        ),
        Text(
          t.help.storyPromptCustom.entryBody,
          style:
              SimpleTextStyles.body.copyWith(color: colors.muted, height: 1.7),
        ),
      ],
    );
  }
}
