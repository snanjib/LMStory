import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/help/presentation/widgets/session_settings_diagram.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_page_scaffold.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_section_title.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_step_card.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 对话模式 wiki 子页 2.5：会话设置（2026-07-27 新增）。
///
/// 介绍会话级配置覆盖全局的机制和 4 大设置区段。
class SessionSettingsWikiPage extends StatelessWidget {
  const SessionSettingsWikiPage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;

    return WikiPageScaffold(
      title: t.help.sessionSettingsWiki.title,
      children: [
        // 引言
        Text(
          t.help.sessionSettings.intro,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),

        // 主视觉
        WikiSectionTitle(
          title: t.help.sessionSettings.priorityTitle,
          subtitle: t.help.sessionSettings.prioritySubtitle,
        ),
        const SessionSettingsDiagram(),

        // 三级优先级说明
        WikiSectionTitle(
          title: t.help.sessionSettings.levelsTitle,
          subtitle: '',
        ),
        WikiStepCard(
          step: 1,
          title: t.help.sessionSettings.level1Title,
          body: t.help.sessionSettings.level1Body,
        ),
        WikiStepCard(
          step: 2,
          title: t.help.sessionSettings.level2Title,
          body: t.help.sessionSettings.level2Body,
        ),
        WikiStepCard(
          step: 3,
          title: t.help.sessionSettings.level3Title,
          body: t.help.sessionSettings.level3Body,
        ),

        // 重置为全局
        WikiSectionTitle(
          title: t.help.sessionSettings.resetTitle,
          subtitle: '',
        ),
        Text(
          t.help.sessionSettings.resetBody,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),
      ],
    );
  }
}
