import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/help/presentation/widgets/story_session_settings_diagram.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_page_scaffold.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_section_title.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_step_card.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// Wiki 子页 3.6：故事会话设置。
///
/// 介绍故事模式会话设置的 4 步骤模型 + 9 个区段。
///
/// 设计原则：
/// - 示意图优先，顶部主视觉展示 4 步骤模型 + 9 个设置区段
/// - 4 步骤独立模型配置单独说明（核心差异点）
/// - 9 个区段按 UI 实际顺序逐一说明（记忆管理置顶）
class StorySessionSettingsWikiPage extends StatelessWidget {
  const StorySessionSettingsWikiPage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;

    return WikiPageScaffold(
      title: t.help.storySessionSettingsWiki.title,
      children: [
        // 引言
        Text(
          t.help.storySessionSettings.intro,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),

        // 主视觉：4 步骤模型 + 9 个区段
        WikiSectionTitle(
          title: t.help.storySessionSettings.diagramTitle,
          subtitle: t.help.storySessionSettings.diagramSubtitle,
        ),
        const StorySessionSettingsDiagram(),

        // 4 步骤模型
        WikiSectionTitle(
          title: t.help.storySessionSettings.phaseModelsTitle,
          subtitle: '',
        ),
        Text(
          t.help.storySessionSettings.phaseModelsBody,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),

        // 10 个区段说明（按 UI 实际顺序：记忆管理置顶，角色卡/世界书次之）
        WikiSectionTitle(
          title: t.help.storySessionSettings.sectionsTitle,
          subtitle: '',
        ),
        WikiStepCard(
          step: 1,
          title: t.help.storySessionSettings.section9Title,
          body: t.help.storySessionSettings.section9Body,
        ),
        WikiStepCard(
          step: 2,
          title: t.help.storySessionSettings.section10Title,
          body: t.help.storySessionSettings.section10Body,
        ),
        WikiStepCard(
          step: 3,
          title: t.help.storySessionSettings.section1Title,
          body: t.help.storySessionSettings.section1Body,
        ),
        WikiStepCard(
          step: 4,
          title: t.help.storySessionSettings.section2Title,
          body: t.help.storySessionSettings.section2Body,
        ),
        WikiStepCard(
          step: 5,
          title: t.help.storySessionSettings.section3Title,
          body: t.help.storySessionSettings.section3Body,
        ),
        WikiStepCard(
          step: 6,
          title: t.help.storySessionSettings.section4Title,
          body: t.help.storySessionSettings.section4Body,
        ),
        WikiStepCard(
          step: 7,
          title: t.help.storySessionSettings.section5Title,
          body: t.help.storySessionSettings.section5Body,
        ),
        WikiStepCard(
          step: 8,
          title: t.help.storySessionSettings.section6Title,
          body: t.help.storySessionSettings.section6Body,
        ),
        WikiStepCard(
          step: 9,
          title: t.help.storySessionSettings.section7Title,
          body: t.help.storySessionSettings.section7Body,
        ),
        WikiStepCard(
          step: 10,
          title: t.help.storySessionSettings.section8Title,
          body: t.help.storySessionSettings.section8Body,
        ),

        // 失败状态下可修改
        WikiSectionTitle(
          title: t.help.storySessionSettings.failedEditTitle,
          subtitle: '',
        ),
        Text(
          t.help.storySessionSettings.failedEditBody,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),
      ],
    );
  }
}
