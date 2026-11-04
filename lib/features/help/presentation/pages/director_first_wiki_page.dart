import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_page_scaffold.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_section_title.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_step_card.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// Wiki 子页：创建导演会话（2026-08-19 新增）。
///
/// 开关 → 新建 → 项目规则三步流程 + 开场建议。
class DirectorFirstWikiPage extends StatelessWidget {
  const DirectorFirstWikiPage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context).help.directorFirst;
    final colors = context.lm.palette;

    return WikiPageScaffold(
      title: Translations.of(context).help.directorFirstWiki.title,
      children: [
        Text(
          t.intro,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),
        WikiSectionTitle(
          title: t.flowTitle,
          subtitle: '',
        ),
        WikiStepCard(step: 1, title: t.flow1Label, body: t.flow1Desc),
        WikiStepCard(step: 2, title: t.flow2Label, body: t.flow2Desc),
        WikiStepCard(step: 3, title: t.flow3Label, body: t.flow3Desc),
        WikiSectionTitle(
          title: t.rulesTitle,
          subtitle: '',
        ),
        Text(
          t.rulesBody,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),
        WikiSectionTitle(
          title: t.startTitle,
          subtitle: '',
        ),
        Text(
          t.startBody,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),
      ],
    );
  }
}
