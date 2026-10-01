import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_page_scaffold.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_section.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 故事模式 wiki 子页 2：记忆机制。
///
/// 通俗解释两类记忆（经历类 vs 事实类）、向量化检索的具体内容、
/// 检索查询源、事实层防护机制。
///
/// 内容来源：用户产品 wiki，由设计文档 DOC-08/09/11 提炼。
class StoryMemoryWikiPage extends StatelessWidget {
  const StoryMemoryWikiPage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;

    return WikiPageScaffold(
      title: t.help.memoryWiki.title,
      children: [
        // 引言
        Text(
          t.help.memory.intro,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),
        // 两类记忆对比
        WikiSection(
          title: t.help.memory.twoTypesTitle,
          body: t.help.memory.twoTypesBody,
        ),
        // 经历类记忆详情
        WikiSection(
          title: t.help.memory.experientialTitle,
          body: t.help.memory.experientialBody,
        ),
        // 事实类记忆详情
        WikiSection(
          title: t.help.memory.factualTitle,
          body: t.help.memory.factualBody,
        ),
        // 向量化内容
        WikiSection(
          title: t.help.memory.retrievalTitle,
          body: t.help.memory.retrievalBody,
        ),
        // 检索查询源
        WikiSection(
          title: t.help.memory.retrievalQueryTitle,
          body: t.help.memory.retrievalQueryBody,
        ),
        // 事实层三重防护
        WikiSection(
          title: t.help.memory.factualGuardTitle,
          body: t.help.memory.factualGuardBody,
        ),
        // 5 层健康度防护
        WikiSection(
          title: t.help.memory.factualHealthTitle,
          body: t.help.memory.factualHealthBody,
        ),
        // 本轮事实变更（事实层变更小窗）
        WikiSection(
          title: t.help.memory.factualChangePanelTitle,
          body: t.help.memory.factualChangePanelBody,
        ),
        // 记忆检索门槛（向量化/索引阈值）
        WikiSection(
          title: t.help.memory.vectorizationThresholdTitle,
          body: t.help.memory.vectorizationThresholdBody,
        ),
      ],
    );
  }
}
