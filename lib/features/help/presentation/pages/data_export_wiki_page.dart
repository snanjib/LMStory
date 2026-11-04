import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/help/presentation/widgets/data_export_diagram.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_page_scaffold.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_section_title.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_step_card.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// Wiki 子页 6.1：数据导出与导入（2026-07-27 新增）。
class DataExportWikiPage extends StatelessWidget {
  const DataExportWikiPage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;

    return WikiPageScaffold(
      title: t.help.dataExportWiki.title,
      children: [
        Text(
          t.help.dataExport.intro,
          style:
              SimpleTextStyles.body.copyWith(color: colors.muted, height: 1.7),
        ),
        WikiSectionTitle(
          title: t.help.dataExport.diagramTitle,
          subtitle: t.help.dataExport.diagramSubtitle,
        ),
        const DataExportDiagram(),
        WikiSectionTitle(title: t.help.dataExport.stepsTitle, subtitle: ''),
        WikiStepCard(
          step: 1,
          title: t.help.dataExport.step1Title,
          body: t.help.dataExport.step1Body,
        ),
        WikiStepCard(
          step: 2,
          title: t.help.dataExport.step2Title,
          body: t.help.dataExport.step2Body,
        ),
        WikiStepCard(
          step: 3,
          title: t.help.dataExport.step3Title,
          body: t.help.dataExport.step3Body,
        ),
        WikiStepCard(
          step: 4,
          title: t.help.dataExport.step4Title,
          body: t.help.dataExport.step4Body,
        ),
        WikiSectionTitle(
          title: t.help.dataExport.singleSessionTitle,
          subtitle: '',
        ),
        Text(
          t.help.dataExport.singleSessionBody,
          style:
              SimpleTextStyles.body.copyWith(color: colors.muted, height: 1.7),
        ),
        //  备份完整性立项：自动备份说明
        WikiSectionTitle(
          title: t.help.dataExport.autoBackupTitle,
          subtitle: '',
        ),
        Text(
          t.help.dataExport.autoBackupBody,
          style:
              SimpleTextStyles.body.copyWith(color: colors.muted, height: 1.7),
        ),
        WikiSectionTitle(title: t.help.dataExport.entryTitle, subtitle: ''),
        Text(
          t.help.dataExport.entryBody,
          style:
              SimpleTextStyles.body.copyWith(color: colors.muted, height: 1.7),
        ),
      ],
    );
  }
}
