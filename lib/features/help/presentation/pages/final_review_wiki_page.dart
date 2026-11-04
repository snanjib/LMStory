import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_page_scaffold.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_section.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_section_title.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// Wiki 子页 4.6：终稿审查（v0.2.2 新增）。
///
/// 解释终稿审查开关的作用、开启/关闭的区别（3 次 vs 4 次 AI 请求）、
/// 与思考预算的关系（思考预算作用于草稿生成和终稿审查两个阶段）。
///
/// 设计原则：示意图优先，顶部主视觉对比开启/关闭两列，下方逐项说明。
class FinalReviewWikiPage extends StatelessWidget {
  const FinalReviewWikiPage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;

    return WikiPageScaffold(
      title: t.help.finalReviewWiki.title,
      children: [
        Text(
          t.help.finalReview.intro,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),
        WikiSectionTitle(
          title: t.help.finalReview.diagramTitle,
          subtitle: t.help.finalReview.diagramSubtitle,
        ),
        const _FinalReviewDiagram(),
        WikiSection(
          title: t.help.finalReview.toggleTitle,
          body: t.help.finalReview.toggleBody,
        ),
        WikiSection(
          title: t.help.finalReview.budgetTitle,
          body: t.help.finalReview.budgetBody,
        ),
        WikiSection(
          title: t.help.finalReview.adviceTitle,
          body: t.help.finalReview.adviceBody,
        ),
        WikiSection(
          title: t.help.finalReview.entryTitle,
          body: t.help.finalReview.entryBody,
        ),
      ],
    );
  }
}

/// 开启 vs 关闭对比示意图：两列步骤列表，开启列多一个审查步骤。
///
/// 视觉传达：左侧 3 步（关闭），右侧 4 步（开启，审查高亮）。
class _FinalReviewDiagram extends StatelessWidget {
  const _FinalReviewDiagram();

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: _StepColumn(
              title: t.help.finalReview.diagramOffTitle,
              steps: [
                t.help.finalReview.offStep1,
                t.help.finalReview.offStep2,
                t.help.finalReview.offStep3,
              ],
              highlightLast: false,
            ),
          ),
          const SizedBox(width: SimpleSpacing.sSm),
          Expanded(
            child: _StepColumn(
              title: t.help.finalReview.diagramOnTitle,
              steps: [
                t.help.finalReview.onStep1,
                t.help.finalReview.onStep2,
                t.help.finalReview.onStep3,
                t.help.finalReview.onStep4,
              ],
              highlightLast: true,
            ),
          ),
        ],
      ),
    );
  }
}

class _StepColumn extends StatelessWidget {
  const _StepColumn({
    required this.title,
    required this.steps,
    required this.highlightLast,
  });

  final String title;
  final List<String> steps;
  final bool highlightLast;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Container(
      padding: const EdgeInsets.all(SimpleSpacing.sSm),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
        border: Border.all(color: colors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: SimpleTextStyles.bodySm.copyWith(
              color: colors.ink,
              fontWeight: FontWeight.w600,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: SimpleSpacing.s2xs),
          for (var i = 0; i < steps.length; i++)
            Padding(
              padding: const EdgeInsets.only(top: SimpleSpacing.s2xs),
              child: _StepRow(
                text: steps[i],
                highlight: highlightLast && i == steps.length - 1,
              ),
            ),
        ],
      ),
    );
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow({required this.text, required this.highlight});

  final String text;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: SimpleSpacing.sSm,
        vertical: SimpleSpacing.s2xs,
      ),
      decoration: BoxDecoration(
        color: highlight ? colors.primaryDim : colors.surfaceVariant,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
      ),
      child: Text(
        text,
        style: SimpleTextStyles.caption.copyWith(
          color: colors.ink,
          fontWeight: highlight ? FontWeight.w600 : FontWeight.w400,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
