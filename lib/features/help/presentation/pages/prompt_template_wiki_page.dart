import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/help/presentation/widgets/prompt_template_diagram.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_page_scaffold.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_section_title.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_step_card.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// Wiki 子页 5.3：提示词模板系统（2026-07-27 新增）。
class PromptTemplateWikiPage extends StatelessWidget {
  const PromptTemplateWikiPage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;

    return WikiPageScaffold(
      title: t.help.promptTemplateWiki.title,
      children: [
        Text(
          t.help.promptTemplate.intro,
          style:
              SimpleTextStyles.body.copyWith(color: colors.muted, height: 1.7),
        ),
        WikiSectionTitle(
          title: t.help.promptTemplate.diagramTitle,
          subtitle: t.help.promptTemplate.diagramSubtitle,
        ),
        const PromptTemplateDiagram(),
        WikiSectionTitle(title: t.help.promptTemplate.stepsTitle, subtitle: ''),
        WikiStepCard(
          step: 1,
          title: t.help.promptTemplate.step1Title,
          body: t.help.promptTemplate.step1Body,
        ),
        WikiStepCard(
          step: 2,
          title: t.help.promptTemplate.step2Title,
          body: t.help.promptTemplate.step2Body,
        ),
        WikiStepCard(
          step: 3,
          title: t.help.promptTemplate.step3Title,
          body: t.help.promptTemplate.step3Body,
        ),
        WikiStepCard(
          step: 4,
          title: t.help.promptTemplate.step4Title,
          body: t.help.promptTemplate.step4Body,
        ),
        WikiSectionTitle(
          title: t.help.promptTemplate.builtinTitle,
          subtitle: '',
        ),
        Text(
          t.help.promptTemplate.builtinBody,
          style:
              SimpleTextStyles.body.copyWith(color: colors.muted, height: 1.7),
        ),
        WikiSectionTitle(title: t.help.promptTemplate.applyTitle, subtitle: ''),
        Text(
          t.help.promptTemplate.applyBody,
          style:
              SimpleTextStyles.body.copyWith(color: colors.muted, height: 1.7),
        ),
        WikiSectionTitle(title: t.help.promptTemplate.entryTitle, subtitle: ''),
        Text(
          t.help.promptTemplate.entryBody,
          style:
              SimpleTextStyles.body.copyWith(color: colors.muted, height: 1.7),
        ),
      ],
    );
  }
}
