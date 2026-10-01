import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/help/presentation/widgets/api_provider_diagram.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_page_scaffold.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_section_title.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_step_card.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// Wiki 子页 5.1：API 供应商管理（2026-07-27 新增）。
class ApiProviderWikiPage extends StatelessWidget {
  const ApiProviderWikiPage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;

    return WikiPageScaffold(
      title: t.help.apiProviderWiki.title,
      children: [
        Text(
          t.help.apiProvider.intro,
          style:
              SimpleTextStyles.body.copyWith(color: colors.muted, height: 1.7),
        ),
        WikiSectionTitle(
          title: t.help.apiProvider.diagramTitle,
          subtitle: t.help.apiProvider.diagramSubtitle,
        ),
        const ApiProviderDiagram(),
        WikiSectionTitle(title: t.help.apiProvider.stepsTitle, subtitle: ''),
        WikiStepCard(
          step: 1,
          title: t.help.apiProvider.step1Title,
          body: t.help.apiProvider.step1Body,
        ),
        WikiStepCard(
          step: 2,
          title: t.help.apiProvider.step2Title,
          body: t.help.apiProvider.step2Body,
        ),
        WikiStepCard(
          step: 3,
          title: t.help.apiProvider.step3Title,
          body: t.help.apiProvider.step3Body,
        ),
        WikiStepCard(
          step: 4,
          title: t.help.apiProvider.step4Title,
          body: t.help.apiProvider.step4Body,
        ),
        WikiStepCard(
          step: 5,
          title: t.help.apiProvider.step5Title,
          body: t.help.apiProvider.step5Body,
        ),
        WikiSectionTitle(title: t.help.apiProvider.modelsTitle, subtitle: ''),
        Text(
          t.help.apiProvider.modelsBody,
          style:
              SimpleTextStyles.body.copyWith(color: colors.muted, height: 1.7),
        ),
        WikiSectionTitle(title: t.help.apiProvider.entryTitle, subtitle: ''),
        Text(
          t.help.apiProvider.entryBody,
          style:
              SimpleTextStyles.body.copyWith(color: colors.muted, height: 1.7),
        ),
      ],
    );
  }
}
