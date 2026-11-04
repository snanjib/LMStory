import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/help/presentation/widgets/feature_index_diagram.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_page_scaffold.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_section_title.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// Wiki 子页 7.3：功能索引表（2026-07-27 新增）。
class FeatureIndexWikiPage extends StatelessWidget {
  const FeatureIndexWikiPage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;

    return WikiPageScaffold(
      title: t.help.featureIndexWiki.title,
      children: [
        Text(
          t.help.featureIndex.intro,
          style:
              SimpleTextStyles.body.copyWith(color: colors.muted, height: 1.7),
        ),
        WikiSectionTitle(
          title: t.help.featureIndex.diagramTitle,
          subtitle: t.help.featureIndex.diagramSubtitle,
        ),
        const FeatureIndexDiagram(),
        WikiSectionTitle(
          title: t.help.featureIndex.moduleSimpleTitle,
          subtitle: '',
        ),
        _ModuleBlock(
          body: t.help.featureIndex.moduleSimpleBody,
          color: colors.primary,
        ),
        WikiSectionTitle(
          title: t.help.featureIndex.moduleIntermediateTitle,
          subtitle: '',
        ),
        _ModuleBlock(
          body: t.help.featureIndex.moduleIntermediateBody,
          color: colors.accent,
        ),
        WikiSectionTitle(
          title: t.help.featureIndex.moduleDirectorTitle,
          subtitle: '',
        ),
        _ModuleBlock(
          body: t.help.featureIndex.moduleDirectorBody,
          color: colors.warning,
        ),
        WikiSectionTitle(
          title: t.help.featureIndex.moduleSettingsTitle,
          subtitle: '',
        ),
        _ModuleBlock(
          body: t.help.featureIndex.moduleSettingsBody,
          color: colors.success,
        ),
        WikiSectionTitle(
          title: t.help.featureIndex.moduleDataTitle,
          subtitle: '',
        ),
        _ModuleBlock(
          body: t.help.featureIndex.moduleDataBody,
          color: colors.warning,
        ),
        WikiSectionTitle(
          title: t.help.featureIndex.moduleHelpTitle,
          subtitle: '',
        ),
        _ModuleBlock(
          body: t.help.featureIndex.moduleHelpBody,
          color: colors.muted,
        ),
        WikiSectionTitle(title: t.help.featureIndex.entryTitle, subtitle: ''),
        Text(
          t.help.featureIndex.entryBody,
          style:
              SimpleTextStyles.body.copyWith(color: colors.muted, height: 1.7),
        ),
      ],
    );
  }
}

class _ModuleBlock extends StatelessWidget {
  const _ModuleBlock({required this.body, required this.color});

  final String body;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Container(
      padding: const EdgeInsets.all(SimpleSpacing.sSm),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
        border: Border.all(color: colors.divider),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 4,
            constraints: const BoxConstraints(minHeight: 60),
            decoration: BoxDecoration(
              color: color,
              borderRadius:
                  BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
            ),
          ),
          const SizedBox(width: SimpleSpacing.sSm),
          Expanded(
            child: Text(
              body,
              style: SimpleTextStyles.bodySm.copyWith(
                color: colors.ink,
                height: 1.7,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
