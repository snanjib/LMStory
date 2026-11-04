import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/help/presentation/widgets/language_input_diagram.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_page_scaffold.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_section_title.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_step_card.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// Wiki 子页 5.6：语言与输入（2026-07-27 新增）。
class LanguageInputWikiPage extends StatelessWidget {
  const LanguageInputWikiPage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;

    return WikiPageScaffold(
      title: t.help.languageInputWiki.title,
      children: [
        Text(
          t.help.languageInput.intro,
          style:
              SimpleTextStyles.body.copyWith(color: colors.muted, height: 1.7),
        ),
        WikiSectionTitle(
          title: t.help.languageInput.diagramTitle,
          subtitle: t.help.languageInput.diagramSubtitle,
        ),
        const LanguageInputDiagram(),
        WikiSectionTitle(title: t.help.languageInput.stepsTitle, subtitle: ''),
        WikiStepCard(
          step: 1,
          title: t.help.languageInput.step1Title,
          body: t.help.languageInput.step1Body,
        ),
        WikiStepCard(
          step: 2,
          title: t.help.languageInput.step2Title,
          body: t.help.languageInput.step2Body,
        ),
        WikiSectionTitle(title: t.help.languageInput.entryTitle, subtitle: ''),
        Text(
          t.help.languageInput.entryBody,
          style:
              SimpleTextStyles.body.copyWith(color: colors.muted, height: 1.7),
        ),
      ],
    );
  }
}
