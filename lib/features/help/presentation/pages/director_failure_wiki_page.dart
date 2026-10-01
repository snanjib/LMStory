import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_page_scaffold.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_section_title.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_step_card.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// Wiki 子页：失败与重试（2026-08-19 新增，导演模式）。
///
/// 失败表现两步卡 + 重试语义与排查建议。
class DirectorFailureWikiPage extends StatelessWidget {
  const DirectorFailureWikiPage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context).help.directorFailure;
    final colors = context.lm.palette;

    return WikiPageScaffold(
      title: Translations.of(context).help.directorFailureWiki.title,
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
        WikiStepCard(
          step: 1,
          title: t.diagramFailLabel,
          body: t.diagramFailDesc,
        ),
        WikiStepCard(
          step: 2,
          title: t.diagramRetryLabel,
          body: t.diagramRetryDesc,
        ),
        WikiSectionTitle(
          title: t.retryTitle,
          subtitle: '',
        ),
        Text(
          t.retryBody,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),
      ],
    );
  }
}
