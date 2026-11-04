import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/help/presentation/widgets/faq_diagram.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_page_scaffold.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_section_title.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_step_card.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// Wiki 子页 7.1：故障排除 FAQ（2026-07-27 新增）。
class FaqWikiPage extends StatelessWidget {
  const FaqWikiPage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;

    return WikiPageScaffold(
      title: t.help.faqWiki.title,
      children: [
        Text(
          t.help.faq.intro,
          style:
              SimpleTextStyles.body.copyWith(color: colors.muted, height: 1.7),
        ),
        WikiSectionTitle(
          title: t.help.faq.diagramTitle,
          subtitle: t.help.faq.diagramSubtitle,
        ),
        const FaqDiagram(),
        WikiSectionTitle(title: t.help.faq.scenesTitle, subtitle: ''),
        WikiStepCard(
          step: 1,
          title: t.help.faq.scene1Title,
          body: t.help.faq.scene1Body,
        ),
        WikiStepCard(
          step: 2,
          title: t.help.faq.scene2Title,
          body: t.help.faq.scene2Body,
        ),
        WikiStepCard(
          step: 3,
          title: t.help.faq.scene3Title,
          body: t.help.faq.scene3Body,
        ),
        WikiStepCard(
          step: 4,
          title: t.help.faq.scene4Title,
          body: t.help.faq.scene4Body,
        ),
        WikiStepCard(
          step: 5,
          title: t.help.faq.scene5Title,
          body: t.help.faq.scene5Body,
        ),
        WikiStepCard(
          step: 6,
          title: t.help.faq.scene6Title,
          body: t.help.faq.scene6Body,
        ),
        WikiStepCard(
          step: 7,
          title: t.help.faq.scene7Title,
          body: t.help.faq.scene7Body,
        ),
        WikiStepCard(
          step: 8,
          title: t.help.faq.scene8Title,
          body: t.help.faq.scene8Body,
        ),
        // 2026-09-16：导演模式选型 FAQ（附录页此前无导演场景条目）
        WikiStepCard(
          step: 9,
          title: t.help.faq.scene9Title,
          body: t.help.faq.scene9Body,
        ),
        WikiSectionTitle(title: t.help.faq.identifyTitle, subtitle: ''),
        Text(
          t.help.faq.identifyBody,
          style:
              SimpleTextStyles.body.copyWith(color: colors.muted, height: 1.7),
        ),
        WikiSectionTitle(title: t.help.faq.linkTitle, subtitle: ''),
        Text(
          t.help.faq.linkBody,
          style:
              SimpleTextStyles.body.copyWith(color: colors.muted, height: 1.7),
        ),
        WikiSectionTitle(title: t.help.faq.entryTitle, subtitle: ''),
        Text(
          t.help.faq.entryBody,
          style:
              SimpleTextStyles.body.copyWith(color: colors.muted, height: 1.7),
        ),
      ],
    );
  }
}
