import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/help/presentation/widgets/compaction_flow_diagram.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_page_scaffold.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_section_title.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_step_card.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 对话模式 wiki 子页 2.6：上下文管理与压缩（2026-07-27 新增）。
///
/// 介绍 CompactionPoint 自动压缩的触发条件、流程、失败处理。
class CompactionFlowWikiPage extends StatelessWidget {
  const CompactionFlowWikiPage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;

    return WikiPageScaffold(
      title: t.help.compactionFlowWiki.title,
      children: [
        // 引言
        Text(
          t.help.compactionFlow.intro,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),

        // 主视觉
        WikiSectionTitle(
          title: t.help.compactionFlow.flowTitle,
          subtitle: t.help.compactionFlow.flowSubtitle,
        ),
        const CompactionFlowDiagram(),

        // 自动压缩触发
        WikiSectionTitle(
          title: t.help.compactionFlow.triggerTitle,
          subtitle: '',
        ),
        Text(
          t.help.compactionFlow.triggerBody,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),

        // 流程说明
        WikiSectionTitle(
          title: t.help.compactionFlow.stepsTitle,
          subtitle: '',
        ),
        WikiStepCard(
          step: 1,
          title: t.help.compactionFlow.step1Title,
          body: t.help.compactionFlow.step1Body,
        ),
        WikiStepCard(
          step: 2,
          title: t.help.compactionFlow.step2Title,
          body: t.help.compactionFlow.step2Body,
        ),
        WikiStepCard(
          step: 3,
          title: t.help.compactionFlow.step3Title,
          body: t.help.compactionFlow.step3Body,
        ),

        // 失败处理
        WikiSectionTitle(
          title: t.help.compactionFlow.failedTitle,
          subtitle: '',
        ),
        Text(
          t.help.compactionFlow.failedBody,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),
      ],
    );
  }
}
