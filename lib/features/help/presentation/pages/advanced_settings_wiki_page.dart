import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/help/presentation/widgets/advanced_settings_diagram.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_page_scaffold.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_section_title.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_step_card.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// Wiki 子页 5.7：高级设置（2026-07-27 新增）。
class AdvancedSettingsWikiPage extends StatelessWidget {
  const AdvancedSettingsWikiPage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;

    return WikiPageScaffold(
      title: t.help.advancedSettingsWiki.title,
      children: [
        Text(
          t.help.advancedSettings.intro,
          style:
              SimpleTextStyles.body.copyWith(color: colors.muted, height: 1.7),
        ),
        WikiSectionTitle(
          title: t.help.advancedSettings.diagramTitle,
          subtitle: t.help.advancedSettings.diagramSubtitle,
        ),
        const AdvancedSettingsDiagram(),
        WikiSectionTitle(
          title: t.help.advancedSettings.stepsTitle,
          subtitle: '',
        ),
        WikiStepCard(
          step: 1,
          title: t.help.advancedSettings.step1Title,
          body: t.help.advancedSettings.step1Body,
        ),
        WikiStepCard(
          step: 2,
          title: t.help.advancedSettings.step2Title,
          body: t.help.advancedSettings.step2Body,
        ),
        WikiStepCard(
          step: 3,
          title: t.help.advancedSettings.step3Title,
          body: t.help.advancedSettings.step3Body,
        ),
        WikiSectionTitle(
          title: t.help.advancedSettings.streamTitle,
          subtitle: '',
        ),
        Text(
          t.help.advancedSettings.streamBody,
          style:
              SimpleTextStyles.body.copyWith(color: colors.muted, height: 1.7),
        ),
        WikiSectionTitle(
          title: t.help.advancedSettings.entryTitle,
          subtitle: '',
        ),
        Text(
          t.help.advancedSettings.entryBody,
          style:
              SimpleTextStyles.body.copyWith(color: colors.muted, height: 1.7),
        ),
      ],
    );
  }
}
