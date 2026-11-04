import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/help/presentation/widgets/glossary_diagram.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_page_scaffold.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_section_title.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// Wiki 子页 7.2：术语表（2026-07-27 新增）。
class GlossaryWikiPage extends StatelessWidget {
  const GlossaryWikiPage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;

    return WikiPageScaffold(
      title: t.help.glossaryWiki.title,
      children: [
        Text(
          t.help.glossary.intro,
          style:
              SimpleTextStyles.body.copyWith(color: colors.muted, height: 1.7),
        ),
        WikiSectionTitle(
          title: t.help.glossary.diagramTitle,
          subtitle: t.help.glossary.diagramSubtitle,
        ),
        const GlossaryDiagram(),
        WikiSectionTitle(title: t.help.glossary.apiTitle, subtitle: ''),
        _TermItem(
          term: t.help.glossary.apiKey.term,
          desc: t.help.glossary.apiKey.desc,
        ),
        _TermItem(
          term: t.help.glossary.baseUrl.term,
          desc: t.help.glossary.baseUrl.desc,
        ),
        _TermItem(
          term: t.help.glossary.sse.term,
          desc: t.help.glossary.sse.desc,
        ),
        _TermItem(
          term: t.help.glossary.stream.term,
          desc: t.help.glossary.stream.desc,
        ),
        _TermItem(
          term: t.help.glossary.token.term,
          desc: t.help.glossary.token.desc,
        ),
        _TermItem(
          term: t.help.glossary.contextWindow.term,
          desc: t.help.glossary.contextWindow.desc,
        ),
        _TermItem(
          term: t.help.glossary.temperature.term,
          desc: t.help.glossary.temperature.desc,
        ),
        _TermItem(
          term: t.help.glossary.reasoningEffort.term,
          desc: t.help.glossary.reasoningEffort.desc,
        ),
        _TermItem(
          term: t.help.glossary.samplingParamsOmit.term,
          desc: t.help.glossary.samplingParamsOmit.desc,
        ),
        WikiSectionTitle(title: t.help.glossary.memoryTitle, subtitle: ''),
        _TermItem(
          term: t.help.glossary.compactionPoint.term,
          desc: t.help.glossary.compactionPoint.desc,
        ),
        _TermItem(
          term: t.help.glossary.embedding.term,
          desc: t.help.glossary.embedding.desc,
        ),
        _TermItem(
          term: t.help.glossary.vectorIndex.term,
          desc: t.help.glossary.vectorIndex.desc,
        ),
        _TermItem(
          term: t.help.glossary.fts5.term,
          desc: t.help.glossary.fts5.desc,
        ),
        _TermItem(
          term: t.help.glossary.hybridSearch.term,
          desc: t.help.glossary.hybridSearch.desc,
        ),
        _TermItem(
          term: t.help.glossary.factualMemory.term,
          desc: t.help.glossary.factualMemory.desc,
        ),
        _TermItem(
          term: t.help.glossary.experientialMemory.term,
          desc: t.help.glossary.experientialMemory.desc,
        ),
        _TermItem(
          term: t.help.glossary.eventSummary.term,
          desc: t.help.glossary.eventSummary.desc,
        ),
        WikiSectionTitle(title: t.help.glossary.projectTitle, subtitle: ''),
        _TermItem(
          term: t.help.glossary.simpleMode.term,
          desc: t.help.glossary.simpleMode.desc,
        ),
        _TermItem(
          term: t.help.glossary.intermediateMode.term,
          desc: t.help.glossary.intermediateMode.desc,
        ),
        _TermItem(
          term: t.help.glossary.advancedMode.term,
          desc: t.help.glossary.advancedMode.desc,
        ),
        _TermItem(
          term: t.help.glossary.configDisplayMode.term,
          desc: t.help.glossary.configDisplayMode.desc,
        ),
        _TermItem(
          term: t.help.glossary.themeStructure.term,
          desc: t.help.glossary.themeStructure.desc,
        ),
        _TermItem(
          term: t.help.glossary.paletteFamily.term,
          desc: t.help.glossary.paletteFamily.desc,
        ),
        _TermItem(
          term: t.help.glossary.projectRules.term,
          desc: t.help.glossary.projectRules.desc,
        ),
        _TermItem(
          term: t.help.glossary.supervisionMode.term,
          desc: t.help.glossary.supervisionMode.desc,
        ),
        _TermItem(
          term: t.help.glossary.askDirector.term,
          desc: t.help.glossary.askDirector.desc,
        ),
        _TermItem(
          term: t.help.glossary.gmModel.term,
          desc: t.help.glossary.gmModel.desc,
        ),
        _TermItem(
          term: t.help.glossary.storyAnchorTerm.term,
          desc: t.help.glossary.storyAnchorTerm.desc,
        ),
        _TermItem(
          term: t.help.glossary.backstageTerm.term,
          desc: t.help.glossary.backstageTerm.desc,
        ),
        _TermItem(
          term: t.help.glossary.eventLog.term,
          desc: t.help.glossary.eventLog.desc,
        ),
        _TermItem(
          term: t.help.glossary.fourStepGen.term,
          desc: t.help.glossary.fourStepGen.desc,
        ),
        _TermItem(
          term: t.help.glossary.fork.term,
          desc: t.help.glossary.fork.desc,
        ),
        _TermItem(
          term: t.help.glossary.worldbook.term,
          desc: t.help.glossary.worldbook.desc,
        ),
        _TermItem(
          term: t.help.glossary.characterCard.term,
          desc: t.help.glossary.characterCard.desc,
        ),
        _TermItem(
          term: t.help.glossary.resourceLibrary.term,
          desc: t.help.glossary.resourceLibrary.desc,
        ),
        // 只读语义 2.0 术语面补齐（09-14 只更新
        // 了仓库侧 doc/glossary，应用内缺收）
        _TermItem(
          term: t.help.glossary.readonlyBaseline.term,
          desc: t.help.glossary.readonlyBaseline.desc,
        ),
        _TermItem(
          term: t.help.glossary.evolvedRow.term,
          desc: t.help.glossary.evolvedRow.desc,
        ),
        // 2026-09-16：故事模式新能力术语
        _TermItem(
          term: t.help.glossary.storyVariant.term,
          desc: t.help.glossary.storyVariant.desc,
        ),
        _TermItem(
          term: t.help.glossary.acceptPartialAsFinal.term,
          desc: t.help.glossary.acceptPartialAsFinal.desc,
        ),
        _TermItem(
          term: t.help.glossary.continueWritingTerm.term,
          desc: t.help.glossary.continueWritingTerm.desc,
        ),
        _TermItem(
          term: t.help.glossary.inSessionSearchTerm.term,
          desc: t.help.glossary.inSessionSearchTerm.desc,
        ),
        _TermItem(
          term: t.help.glossary.readingPositionTerm.term,
          desc: t.help.glossary.readingPositionTerm.desc,
        ),
        // 补录 v0.3 新术语
        _TermItem(
          term: t.help.glossary.narrativePacing.term,
          desc: t.help.glossary.narrativePacing.desc,
        ),
        _TermItem(
          term: t.help.glossary.toolPermissions.term,
          desc: t.help.glossary.toolPermissions.desc,
        ),
        _TermItem(
          term: t.help.glossary.roundBudget.term,
          desc: t.help.glossary.roundBudget.desc,
        ),
        _TermItem(
          term: t.help.glossary.contextUsage.term,
          desc: t.help.glossary.contextUsage.desc,
        ),
        // 伏笔定期清点词条（9193cd6d 交付时漏五文档面）
        _TermItem(
          term: t.help.glossary.foreshadowSweep.term,
          desc: t.help.glossary.foreshadowSweep.desc,
        ),
        _TermItem(
          term: t.help.glossary.roundTimeline.term,
          desc: t.help.glossary.roundTimeline.desc,
        ),
        // 批二三词条接线页面（此前只写 yaml 未接，6 枚死键）
        _TermItem(
          term: t.help.glossary.scriptBoard.term,
          desc: t.help.glossary.scriptBoard.desc,
        ),
        _TermItem(
          term: t.help.glossary.pureReading.term,
          desc: t.help.glossary.pureReading.desc,
        ),
        _TermItem(
          term: t.help.glossary.contextComposition.term,
          desc: t.help.glossary.contextComposition.desc,
        ),
        WikiSectionTitle(title: t.help.glossary.entryTitle, subtitle: ''),
        Text(
          t.help.glossary.entryBody,
          style:
              SimpleTextStyles.body.copyWith(color: colors.muted, height: 1.7),
        ),
      ],
    );
  }
}

class _TermItem extends StatelessWidget {
  const _TermItem({required this.term, required this.desc});

  final String term;
  final String desc;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: SimpleSpacing.s2xs),
      child: Container(
        padding: const EdgeInsets.all(SimpleSpacing.sSm),
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
          border: Border.all(color: colors.divider),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              term,
              style: SimpleTextStyles.bodySm.copyWith(
                color: colors.primary,
                fontWeight: FontWeight.w700,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),
            // 放开行数限制——最长词条描述实测 3.3 行
            //（窄屏更多），截掉的恰是关键说明；与功能索引页放开口径一致
            Text(
              desc,
              style: SimpleTextStyles.caption.copyWith(
                color: colors.muted,
                height: 1.5,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
