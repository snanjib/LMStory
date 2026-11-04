import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/help/presentation/widgets/data_recovery_diagram.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_page_scaffold.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_section_title.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_step_card.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// Wiki 子页 6.2：数据恢复与表修复（2026-07-27 新增）。
class DataRecoveryWikiPage extends StatelessWidget {
  const DataRecoveryWikiPage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;

    return WikiPageScaffold(
      title: t.help.dataRecoveryWiki.title,
      children: [
        Text(
          t.help.dataRecovery.intro,
          style:
              SimpleTextStyles.body.copyWith(color: colors.muted, height: 1.7),
        ),
        WikiSectionTitle(
          title: t.help.dataRecovery.diagramTitle,
          subtitle: t.help.dataRecovery.diagramSubtitle,
        ),
        const DataRecoveryDiagram(),
        WikiSectionTitle(title: t.help.dataRecovery.stepsTitle, subtitle: ''),
        WikiStepCard(
          step: 1,
          title: t.help.dataRecovery.step1Title,
          body: t.help.dataRecovery.step1Body,
        ),
        WikiStepCard(
          step: 2,
          title: t.help.dataRecovery.step2Title,
          body: t.help.dataRecovery.step2Body,
        ),
        WikiStepCard(
          step: 3,
          title: t.help.dataRecovery.step3Title,
          body: t.help.dataRecovery.step3Body,
        ),
        WikiStepCard(
          step: 4,
          title: t.help.dataRecovery.step4Title,
          body: t.help.dataRecovery.step4Body,
        ),
        WikiSectionTitle(title: t.help.dataRecovery.diffTitle, subtitle: ''),
        Text(
          t.help.dataRecovery.diffBody,
          style:
              SimpleTextStyles.body.copyWith(color: colors.muted, height: 1.7),
        ),
        WikiSectionTitle(title: t.help.dataRecovery.entryTitle, subtitle: ''),
        Text(
          t.help.dataRecovery.entryBody,
          style:
              SimpleTextStyles.body.copyWith(color: colors.muted, height: 1.7),
        ),
      ],
    );
  }
}
