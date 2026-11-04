import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_spacing.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_layout.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/settings/presentation/pages/intermediate_prompt_editor_page.dart'
    show IntermediatePromptEditorPage;
import 'package:lmstory/features/settings/presentation/pages/intermediate_settings_page.dart'
    show IntermediateSettingsPage;
import 'package:lmstory/features/settings/presentation/widgets/intermediate_prompts_section.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 故事模式设置 — 提示词模板子页（2026-07-19 子页化重构）。
///
/// 包含 [IntermediatePromptsSection]：8 段可编辑提示词的 tile 列表 +
/// 预览拼接效果按钮。每个 tile 点击进入
/// [IntermediatePromptEditorPage] 全屏编辑器。
///
/// 从 [IntermediateSettingsPage] 顶层分类卡片进入。
/// 本页只读展示当前配置状态，编辑/保存由编辑器页面负责。
class IntermediatePromptsSettingsPage extends StatelessWidget {
  const IntermediatePromptsSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    return Scaffold(
      backgroundColor:
          context.scaffoldBgOf(Theme.of(context).scaffoldBackgroundColor),
      appBar: AppBar(
        title: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            t.settings.intermediate.categories.prompts.title,
            style: IntermediateTextStyles.title.copyWith(color: colors.ink),
          ),
        ),
        backgroundColor:
            context.scaffoldBgOf(Theme.of(context).scaffoldBackgroundColor),
        foregroundColor: colors.ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      body: LmMeasure(
        child: ListView(
          padding: const EdgeInsets.all(IntermediateSpacing.sLg),
          children: const [
            IntermediatePromptsSection(),
          ],
        ),
      ),
    );
  }
}
