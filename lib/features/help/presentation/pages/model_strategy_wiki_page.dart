import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/help/presentation/widgets/model_strategy_diagram.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_page_scaffold.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_section_title.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_step_card.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// Wiki 子页 5.2：模型选择策略（2026-07-27 新增）。
class ModelStrategyWikiPage extends StatelessWidget {
  const ModelStrategyWikiPage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;

    return WikiPageScaffold(
      title: t.help.modelStrategyWiki.title,
      children: [
        Text(
          t.help.modelStrategy.intro,
          style:
              SimpleTextStyles.body.copyWith(color: colors.muted, height: 1.7),
        ),
        WikiSectionTitle(
          title: t.help.modelStrategy.diagramTitle,
          subtitle: t.help.modelStrategy.diagramSubtitle,
        ),
        const ModelStrategyDiagram(),
        WikiSectionTitle(title: t.help.modelStrategy.stepsTitle, subtitle: ''),
        WikiStepCard(
          step: 1,
          title: t.help.modelStrategy.step1Title,
          body: t.help.modelStrategy.step1Body,
        ),
        WikiStepCard(
          step: 2,
          title: t.help.modelStrategy.step2Title,
          body: t.help.modelStrategy.step2Body,
        ),
        WikiStepCard(
          step: 3,
          title: t.help.modelStrategy.step3Title,
          body: t.help.modelStrategy.step3Body,
        ),
        WikiSectionTitle(
          title: t.help.modelStrategy.embeddingTitle,
          subtitle: '',
        ),
        Text(
          t.help.modelStrategy.embeddingBody,
          style:
              SimpleTextStyles.body.copyWith(color: colors.muted, height: 1.7),
        ),
        WikiSectionTitle(
          title: t.help.modelStrategy.titleModelTitle,
          subtitle: '',
        ),
        Text(
          t.help.modelStrategy.titleModelBody,
          style:
              SimpleTextStyles.body.copyWith(color: colors.muted, height: 1.7),
        ),
        WikiSectionTitle(title: t.help.modelStrategy.entryTitle, subtitle: ''),
        Text(
          t.help.modelStrategy.entryBody,
          style:
              SimpleTextStyles.body.copyWith(color: colors.muted, height: 1.7),
        ),
      ],
    );
  }
}
