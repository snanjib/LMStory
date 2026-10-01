import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_page_scaffold.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_section_title.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_step_card.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// Wiki 子页：导演会话设置（2026-08-19 新增）。
///
/// 主模型/项目规则/预算/监督模式四个关键设置 + 记忆库入口。
class DirectorSettingsWikiPage extends StatelessWidget {
  const DirectorSettingsWikiPage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context).help.directorSettings;
    final colors = context.lm.palette;

    return WikiPageScaffold(
      title: Translations.of(context).help.directorSettingsWiki.title,
      children: [
        Text(
          t.intro,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),
        WikiSectionTitle(
          title: t.settingsTitle,
          subtitle: '',
        ),
        WikiStepCard(step: 1, title: t.modelTitle, body: t.modelBody),
        WikiStepCard(step: 2, title: t.rulesTitle, body: t.rulesBody),
        WikiStepCard(step: 3, title: t.pacingTitle, body: t.pacingBody),
        WikiStepCard(step: 4, title: t.budgetTitle, body: t.budgetBody),
        WikiStepCard(step: 5, title: t.watchTitle, body: t.watchBody),
        WikiStepCard(step: 6, title: t.contextTitle, body: t.contextBody),
        WikiStepCard(
          step: 7,
          title: t.suggestReplyTitle,
          body: t.suggestReplyBody,
        ),
        WikiSectionTitle(
          title: t.memoryTitle,
          subtitle: '',
        ),
        Text(
          t.memoryBody,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),
      ],
    );
  }
}
