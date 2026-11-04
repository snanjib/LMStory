import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/help/presentation/widgets/clear_data_diagram.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_page_scaffold.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_section_title.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_step_card.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// Wiki 子页 6.3：清除所有数据（2026-07-27 新增）。
class ClearDataWikiPage extends StatelessWidget {
  const ClearDataWikiPage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;

    return WikiPageScaffold(
      title: t.help.clearDataWiki.title,
      children: [
        Text(
          t.help.clearData.intro,
          style:
              SimpleTextStyles.body.copyWith(color: colors.muted, height: 1.7),
        ),
        WikiSectionTitle(
          title: t.help.clearData.diagramTitle,
          subtitle: t.help.clearData.diagramSubtitle,
        ),
        const ClearDataDiagram(),
        WikiSectionTitle(title: t.help.clearData.stepsTitle, subtitle: ''),
        WikiStepCard(
          step: 1,
          title: t.help.clearData.step1Title,
          body: t.help.clearData.step1Body,
        ),
        WikiStepCard(
          step: 2,
          title: t.help.clearData.step2Title,
          body: t.help.clearData.step2Body,
        ),
        WikiStepCard(
          step: 3,
          title: t.help.clearData.step3Title,
          body: t.help.clearData.step3Body,
        ),
        WikiStepCard(
          step: 4,
          title: t.help.clearData.step4Title,
          body: t.help.clearData.step4Body,
        ),
        WikiSectionTitle(title: t.help.clearData.warningTitle, subtitle: ''),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: colors.error.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: colors.error.withValues(alpha: 0.3)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.warning_amber_rounded, size: 18, color: colors.error),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  t.help.clearData.warningBody,
                  style: SimpleTextStyles.bodySm.copyWith(
                    color: colors.error,
                    height: 1.6,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        WikiSectionTitle(title: t.help.clearData.entryTitle, subtitle: ''),
        Text(
          t.help.clearData.entryBody,
          style:
              SimpleTextStyles.body.copyWith(color: colors.muted, height: 1.7),
        ),
      ],
    );
  }
}
