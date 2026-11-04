import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/help/presentation/widgets/appearance_diagram.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_page_scaffold.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_section_title.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_step_card.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// Wiki 子页 5.5：外观与主题（2026-07-27 新增）。
class AppearanceWikiPage extends StatelessWidget {
  const AppearanceWikiPage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;

    return WikiPageScaffold(
      title: t.help.appearanceWiki.title,
      children: [
        Text(
          t.help.appearance.intro,
          style:
              SimpleTextStyles.body.copyWith(color: colors.muted, height: 1.7),
        ),
        WikiSectionTitle(
          title: t.help.appearance.diagramTitle,
          subtitle: t.help.appearance.diagramSubtitle,
        ),
        const AppearanceDiagram(),
        WikiSectionTitle(title: t.help.appearance.stepsTitle, subtitle: ''),
        WikiStepCard(
          step: 1,
          title: t.help.appearance.step1Title,
          body: t.help.appearance.step1Body,
        ),
        WikiStepCard(
          step: 2,
          title: t.help.appearance.step2Title,
          body: t.help.appearance.step2Body,
        ),
        WikiStepCard(
          step: 3,
          title: t.help.appearance.step3Title,
          body: t.help.appearance.step3Body,
        ),
        WikiSectionTitle(
          title: t.help.appearance.a11yTitle,
          subtitle: '',
        ),
        Text(
          t.help.appearance.a11yBody,
          style:
              SimpleTextStyles.body.copyWith(color: colors.muted, height: 1.7),
        ),
        WikiSectionTitle(title: t.help.appearance.entryTitle, subtitle: ''),
        Text(
          t.help.appearance.entryBody,
          style:
              SimpleTextStyles.body.copyWith(color: colors.muted, height: 1.7),
        ),
      ],
    );
  }
}
