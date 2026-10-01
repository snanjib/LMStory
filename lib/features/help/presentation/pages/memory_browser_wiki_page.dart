import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/help/presentation/widgets/memory_browser_diagram.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_page_scaffold.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_section_title.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_step_card.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// Wiki 子页 3.7：记忆库浏览器（2026-07-27 新增）。
///
/// 介绍故事模式记忆库的双 Tab 结构 + 完整 CRUD + 搜索。
///
/// 设计原则：
/// - 示意图优先，顶部主视觉展示双 Tab + 4 种操作
/// - 经历类 vs 事实类记忆用 WikiStepCard 对比说明
/// - 不涉及技术实现细节（向量检索 / 5W1E 等放在原理章节）
class MemoryBrowserWikiPage extends StatelessWidget {
  const MemoryBrowserWikiPage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;

    return WikiPageScaffold(
      title: t.help.memoryBrowserWiki.title,
      children: [
        // 引言
        Text(
          t.help.memoryBrowser.intro,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),

        // 主视觉：双 Tab + 4 种操作
        WikiSectionTitle(
          title: t.help.memoryBrowser.diagramTitle,
          subtitle: t.help.memoryBrowser.diagramSubtitle,
        ),
        const MemoryBrowserDiagram(),

        // 双 Tab 说明
        WikiSectionTitle(
          title: t.help.memoryBrowser.tabsTitle,
          subtitle: '',
        ),
        WikiStepCard(
          step: 1,
          title: t.help.memoryBrowser.tab1Title,
          body: t.help.memoryBrowser.tab1Body,
        ),
        WikiStepCard(
          step: 2,
          title: t.help.memoryBrowser.tab2Title,
          body: t.help.memoryBrowser.tab2Body,
        ),

        // 4 种操作
        WikiSectionTitle(
          title: t.help.memoryBrowser.opsTitle,
          subtitle: '',
        ),
        Text(
          t.help.memoryBrowser.opsBody,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),

        // 进入入口
        WikiSectionTitle(
          title: t.help.memoryBrowser.entryTitle,
          subtitle: '',
        ),
        Text(
          t.help.memoryBrowser.entryBody,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),
      ],
    );
  }
}
