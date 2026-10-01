import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/help/presentation/widgets/story_suggest_reply_diagram.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_page_scaffold.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_section_title.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// Wiki 子页 3.8：推荐回复与输入助手（2026-07-29 新增）。
///
/// 介绍故事模式输入框上方的 3 个工具栏按钮：
/// - 引号按钮：在光标处插入成对英文引号 ""
/// - 括号按钮：在光标处插入成对英文括号 ()
/// - 推荐回复按钮：AI 生成 3 条候选回复
///
/// 设计原则：
/// - 示意图优先，顶部主视觉展示工具栏布局
/// - 不涉及技术实现细节（不提 LLM、token、prompt）
/// - 用通俗语言解释功能和交互
/// - 配置部分简短带过，引导到设置页
class StorySuggestReplyWikiPage extends StatelessWidget {
  const StorySuggestReplyWikiPage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;

    return WikiPageScaffold(
      title: t.help.storySuggestReplyWiki.title,
      children: [
        // 引言
        Text(
          t.help.storySuggestReply.intro,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),

        // 主视觉：工具栏示意图
        WikiSectionTitle(
          title: t.help.storySuggestReply.diagramTitle,
          subtitle: t.help.storySuggestReply.diagramSubtitle,
        ),
        const StorySuggestReplyDiagram(),

        // 引号与括号按钮
        WikiSectionTitle(
          title: t.help.storySuggestReply.symbolsTitle,
          subtitle: '',
        ),
        Text(
          t.help.storySuggestReply.symbolsBody,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),

        // 推荐回复按钮
        WikiSectionTitle(
          title: t.help.storySuggestReply.suggestIntroTitle,
          subtitle: '',
        ),
        Text(
          t.help.storySuggestReply.suggestIntroBody,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),

        // 生成中
        WikiSectionTitle(
          title: t.help.storySuggestReply.generatingTitle,
          subtitle: '',
        ),
        Text(
          t.help.storySuggestReply.generatingBody,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),

        // 候选气泡的操作
        WikiSectionTitle(
          title: t.help.storySuggestReply.bubblesTitle,
          subtitle: '',
        ),
        Text(
          t.help.storySuggestReply.bubblesBody,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),

        // 生命周期
        WikiSectionTitle(
          title: t.help.storySuggestReply.lifecycleTitle,
          subtitle: '',
        ),
        Text(
          t.help.storySuggestReply.lifecycleBody,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),

        // 配置
        WikiSectionTitle(
          title: t.help.storySuggestReply.configTitle,
          subtitle: '',
        ),
        Text(
          t.help.storySuggestReply.configBody,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),

        // 省 token
        WikiSectionTitle(
          title: t.help.storySuggestReply.tokenTitle,
          subtitle: '',
        ),
        Text(
          t.help.storySuggestReply.tokenBody,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),
      ],
    );
  }
}
