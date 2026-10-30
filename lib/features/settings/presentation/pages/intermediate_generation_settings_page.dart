import 'package:flutter/material.dart';
import 'package:lmstory/core/config/config_visibility.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_spacing.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_layout.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/widgets/advanced_level_hint.dart';
import 'package:lmstory/features/settings/presentation/pages/intermediate_settings_page.dart'
    show IntermediateSettingsPage;
import 'package:lmstory/features/settings/presentation/widgets/intermediate_generation_section.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 故事模式设置 — 生成参数子页（v0.2.2 阶段 2-B 新增）。
///
/// 单一区块：5 个生成参数（温度/Top P/最大 Token 数/存在惩罚/频率惩罚）。
///
/// 这些值是新会话物化时的"快照源"，修改不影响已物化的会话。
/// 作用范围：generating（生成）与 reviewing（审查）阶段。
///
/// 从 [IntermediateSettingsPage] 顶层分类卡片进入。
/// 即时持久化，本页无 dirty state。
class IntermediateGenerationSettingsPage extends StatelessWidget {
  const IntermediateGenerationSettingsPage({super.key});

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
            t.settings.intermediate.categories.generation.title,
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
            IntermediateGenerationSection(),
            AdvancedLevelHint(
              surfaceId: ConfigVisibilitySurfaces.storyGeneration,
            ),
          ],
        ),
      ),
    );
  }
}
