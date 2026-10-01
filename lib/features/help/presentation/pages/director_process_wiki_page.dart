import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/help/presentation/widgets/director_layers_diagram.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_page_scaffold.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_section_title.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// Wiki 子页：看懂过程——台前与幕后（2026-08-19 新增）。
///
/// 过程分层示意图 + 舞台动词对照 + 成本提示。
class DirectorProcessWikiPage extends StatelessWidget {
  const DirectorProcessWikiPage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context).help.directorProcess;
    final colors = context.lm.palette;

    return WikiPageScaffold(
      title: Translations.of(context).help.directorProcessWiki.title,
      children: [
        Text(
          t.intro,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),
        WikiSectionTitle(
          title: t.diagramTitle,
          subtitle: '',
        ),
        const DirectorLayersDiagram(),
        WikiSectionTitle(
          title: t.verbsTitle,
          subtitle: '',
        ),
        Text(
          t.verbsBody,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),
        WikiSectionTitle(
          title: t.costTitle,
          subtitle: '',
        ),
        Text(
          t.costBody,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),
      ],
    );
  }
}
