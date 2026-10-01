import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/help/presentation/widgets/diagnostics_diagram.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_page_scaffold.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_section_title.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_step_card.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// Wiki 子页 6.4：诊断信息（2026-07-27 新增）。
class DiagnosticsWikiPage extends StatelessWidget {
  const DiagnosticsWikiPage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;

    return WikiPageScaffold(
      title: t.help.diagnosticsWiki.title,
      children: [
        Text(
          t.help.diagnostics.intro,
          style:
              SimpleTextStyles.body.copyWith(color: colors.muted, height: 1.7),
        ),
        WikiSectionTitle(
          title: t.help.diagnostics.diagramTitle,
          subtitle: t.help.diagnostics.diagramSubtitle,
        ),
        const DiagnosticsDiagram(),
        WikiSectionTitle(title: t.help.diagnostics.stepsTitle, subtitle: ''),
        WikiStepCard(
          step: 1,
          title: t.help.diagnostics.step1Title,
          body: t.help.diagnostics.step1Body,
        ),
        WikiStepCard(
          step: 2,
          title: t.help.diagnostics.step2Title,
          body: t.help.diagnostics.step2Body,
        ),
        WikiStepCard(
          step: 3,
          title: t.help.diagnostics.step3Title,
          body: t.help.diagnostics.step3Body,
        ),
        WikiStepCard(
          step: 4,
          title: t.help.diagnostics.step4Title,
          body: t.help.diagnostics.step4Body,
        ),
        WikiSectionTitle(title: t.help.diagnostics.fileTitle, subtitle: ''),
        Text(
          t.help.diagnostics.fileBody,
          style:
              SimpleTextStyles.body.copyWith(color: colors.muted, height: 1.7),
        ),
        WikiSectionTitle(title: t.help.diagnostics.entryTitle, subtitle: ''),
        Text(
          t.help.diagnostics.entryBody,
          style:
              SimpleTextStyles.body.copyWith(color: colors.muted, height: 1.7),
        ),
      ],
    );
  }
}
