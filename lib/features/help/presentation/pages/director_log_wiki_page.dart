import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_page_scaffold.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_section_title.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_step_card.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// Wiki 子页：事件日志与恢复（2026-08-19 新增）。
///
/// 执行→意外→恢复三步 + 幕间回顾卡说明。
class DirectorLogWikiPage extends StatelessWidget {
  const DirectorLogWikiPage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context).help.directorLog;
    final colors = context.lm.palette;

    return WikiPageScaffold(
      title: Translations.of(context).help.directorLogWiki.title,
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
          title: t.diagramWorkLabel,
          body: t.diagramWorkDesc,
        ),
        WikiStepCard(
          step: 2,
          title: t.diagramCrashLabel,
          body: t.diagramCrashDesc,
        ),
        WikiStepCard(
          step: 3,
          title: t.diagramRecoverLabel,
          body: t.diagramRecoverDesc,
        ),
        WikiSectionTitle(
          title: t.recapTitle,
          subtitle: '',
        ),
        Text(
          t.recapBody,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),
      ],
    );
  }
}
