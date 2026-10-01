import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/help/presentation/widgets/director_mode_diagram.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_page_scaffold.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_section_title.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_step_card.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// Wiki 子页：导演模式是什么（2026-08-19 新增，v0.3 实验性）。
///
/// 介绍第三种模式的定位、一轮工作的循环、与另两种模式的选择。
///
/// 设计原则：
/// - 示意图优先，顶部主视觉为「你推进→幕后→正文→沉淀」循环
/// - 三模式对比用 WikiStepCard
/// - 不出现内部代号，全部用剧场/编辑部比喻
class DirectorModeWikiPage extends StatelessWidget {
  const DirectorModeWikiPage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context).help.directorMode;
    final colors = context.lm.palette;

    return WikiPageScaffold(
      title: Translations.of(context).help.directorModeWiki.title,
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
          subtitle: t.diagramSubtitle,
        ),
        const DirectorModeDiagram(),
        WikiSectionTitle(
          title: t.vsTitle,
          subtitle: '',
        ),
        WikiStepCard(
          step: 1,
          title: t.vsChatTitle,
          body: t.vsChatBody,
        ),
        WikiStepCard(
          step: 2,
          title: t.vsStoryTitle,
          body: t.vsStoryBody,
        ),
        WikiStepCard(
          step: 3,
          title: t.vsDirectorTitle,
          body: t.vsDirectorBody,
        ),
        WikiSectionTitle(
          title: t.experimentTitle,
          subtitle: '',
        ),
        Text(
          t.experimentBody,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),
      ],
    );
  }
}
