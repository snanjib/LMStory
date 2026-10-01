import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_spacing.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_layout.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/settings/presentation/pages/intermediate_settings_page.dart'
    show IntermediateSettingsPage;
import 'package:lmstory/features/settings/presentation/widgets/intermediate_context_budget_section.dart';
import 'package:lmstory/features/settings/presentation/widgets/intermediate_json_mode_section.dart';
import 'package:lmstory/features/settings/presentation/widgets/intermediate_review_enabled_section.dart';
import 'package:lmstory/features/settings/presentation/widgets/intermediate_vectorize_threshold_section.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 故事模式设置 — 工具与记忆子页（2026-07-19 子页化重构）。
///
/// 包含四个区块（新增审查 + 上下文预算）：
/// - 工具调用（控制 AI 输出格式：工具调用 vs 纯 JSON 文本）
/// - 审查（控制 reviewing 阶段是否执行：3 次 vs 4 次 LLM 调用）
/// - 上下文预算（原文区上限/下限 + 检索区比例的 token 预算分配）
///
/// 从 [IntermediateSettingsPage] 顶层分类卡片进入。
/// 各 section 即时持久化，本页无 dirty state。
class IntermediateToolsMemorySettingsPage extends StatelessWidget {
  const IntermediateToolsMemorySettingsPage({super.key});

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
            t.settings.intermediate.categories.toolsMemory.title,
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
            IntermediateJsonModeSection(),
            SizedBox(height: IntermediateSpacing.sXl),
            IntermediateReviewEnabledSection(),
            SizedBox(height: IntermediateSpacing.sXl),
            IntermediateContextBudgetSection(),
            SizedBox(height: IntermediateSpacing.sXl),
            IntermediateVectorizeThresholdSection(),
          ],
        ),
      ),
    );
  }
}
