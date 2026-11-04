import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/config/config_level.dart';
import 'package:lmstory/core/config/config_visibility.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_spacing.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_layout.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/settings/presentation/pages/intermediate_settings_page.dart'
    show IntermediateSettingsPage;
import 'package:lmstory/features/settings/presentation/widgets/intermediate_embedding_model_section.dart';
import 'package:lmstory/features/settings/presentation/widgets/intermediate_phase_models_section.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 故事模式设置 — 模型配置子页（2026-07-19 子页化重构）。
///
/// 包含两个区块：
/// - 分步骤模型（生成/提取/审查/摘要各阶段独立模型，全局配置）
/// - 嵌入模型（语义检索用，独立于聊天模型）
///
/// **2026-07-21 配置架构重构**：删除原"故事模式默认模型"区块
/// （IntermediateDefaultModelSection），故事模式仅保留两层模型配置：
/// - 全局级 phaseModels（此处配置）
/// - 会话级 phaseModels（在会话设置面板中配置）
/// 优先级：会话级 > 全局级；都没配 → 报错（不再回退到 broadcastChat）。
///
/// 从 [IntermediateSettingsPage] 顶层分类卡片进入。
/// 各 section 即时持久化，本页无 dirty state。
///
/// 2026-07-19 Phase B：顶部新增"建议配置支持 reasoning 的模型"提示卡片，
/// 因为 reviewing 阶段的审查指令依赖模型的 reasoning 能力。
///
/// 组装层按配置显示模式过滤：简单模式保留分步骤模型区（四类②）与
/// 嵌入模型区（嵌入模型是故事/导演两模式基本需要，划 simple）；
/// reasoning 提示卡随展示层裁量隐藏——其所指的审查阶段开关在简单模式
/// 不可见，提示失去对象（非配置项，不走可见性键）。过滤只动展示层，
/// 被隐藏区已有用户值继续生效。
class IntermediateModelsSettingsPage extends ConsumerWidget {
  const IntermediateModelsSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    final level = ref.watch(configLevelProvider);
    final isAdvanced = level == ConfigLevel.advanced;

    return Scaffold(
      backgroundColor:
          context.scaffoldBgOf(Theme.of(context).scaffoldBackgroundColor),
      appBar: AppBar(
        title: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            t.settings.intermediate.categories.models.title,
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
          children: [
            if (isAdvanced) ...[
              _buildReasoningHint(context, t, colors),
              const SizedBox(height: IntermediateSpacing.sXl),
            ],
            if (ConfigVisibility.of(
              ConfigVisibilityKeys.storyModelsPhaseModels,
              level,
            ))
              const IntermediatePhaseModelsSection(),
            if (ConfigVisibility.of(
              ConfigVisibilityKeys.storyModelsEmbedding,
              level,
            )) ...[
              const SizedBox(height: IntermediateSpacing.sXl),
              const IntermediateEmbeddingModelSection(),
            ],
          ],
        ),
      ),
    );
  }

  /// reasoning 能力提示卡片
  ///
  /// reviewing 阶段的审查指令依赖模型的 reasoning 能力。
  /// 提示用户配置支持 reasoning 的模型并勾选"推理"能力。
  Widget _buildReasoningHint(
    BuildContext context,
    Translations t,
    LmPalette colors,
  ) {
    return Container(
      padding: const EdgeInsets.all(IntermediateSpacing.sMd),
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
        border: Border.all(
          color: colors.accent.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.lightbulb_outline,
            size: 18,
            color: colors.accent,
          ),
          const SizedBox(width: IntermediateSpacing.sSm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t.settings.intermediate.reasoningHintTitle,
                  style: IntermediateTextStyles.label.copyWith(
                    color: colors.ink,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: IntermediateSpacing.sXs),
                Text(
                  t.settings.intermediate.reasoningHintBody,
                  style: IntermediateTextStyles.caption.copyWith(
                    color: colors.muted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
