import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/help/presentation/widgets/director_watch_diagram.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_page_scaffold.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_section_title.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// Wiki 子页：监督模式——请示与审批（2026-08-19 新增）。
///
/// 审批流示意图 + 请示导演 + 开关与代价。
class DirectorWatchWikiPage extends StatelessWidget {
  const DirectorWatchWikiPage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context).help.directorWatch;
    final colors = context.lm.palette;

    return WikiPageScaffold(
      title: Translations.of(context).help.directorWatchWiki.title,
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
        const DirectorWatchDiagram(),
        WikiSectionTitle(
          title: t.askTitle,
          subtitle: '',
        ),
        Text(
          t.askBody,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),
        WikiSectionTitle(
          title: t.toggleTitle,
          subtitle: '',
        ),
        Text(
          t.toggleBody,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),
      ],
    );
  }
}
