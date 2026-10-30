import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/config/config_level.dart';
import 'package:lmstory/core/config/config_visibility.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_spacing.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/intermediate/presentation/widgets/collapsible_settings_section.dart';
import 'package:lmstory/features/settings/domain/entities/model_capability.dart';
import 'package:lmstory/features/settings/presentation/widgets/default_model_picker_sheet.dart';
import 'package:lmstory/features/settings/presentation/widgets/sections/director_setting_rows.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 导演设置 — 检索与记忆分区（导演设置 ，设计文档 §7）。
///
/// 向量化模型（`advanced.embedding_preset_id/model_id`，清除=FTS5 兜底）+
/// 事实记忆开关与阈值（`advanced.memory.factual.*`）+ 归并触发（
/// `advanced.consolidation.trigger_threshold`）；高级子折叠：
/// embedding 超时/降级、归并批量参数、记忆检索双门槛
/// （`advanced.retrieval.importance_storage_threshold` /
/// `micro_vectorize_threshold`——2026-08-29 审查 ：导演运行时仅消费
/// 这两个检索键，故事侧混合检索的 14 个排序参数不再在此暴露）。
///
/// 行级可见性（D-C13）：向量化模型行 simple 双模式渲染（区壳恒显，
/// 见 DirectorSettingsPage 的 `_sectionVisibilityKey`）；事实记忆/
/// 归并触发/高级子折叠为记忆管线技术配置，仅进阶模式渲染。
class DirectorMemorySection extends ConsumerWidget {
  const DirectorMemorySection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(advancedConfigProvider).valueOrNull;
    final level = ref.watch(configLevelProvider);
    final colors = context.lm.palette;
    final t = Translations.of(context);
    final m = t.settings.director.memory;

    final embeddingPreset = config?.embeddingPresetId ?? '';
    final embeddingModel = config?.embeddingModelId ?? '';
    final factual = config?.memory.factual;
    final consolidation = config?.consolidation;
    final embedding = config?.embedding;
    final retrieval = config?.retrieval ?? const RetrievalConfig();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── 向量化模型（D-C13 simple，双模式渲染）─────────────────
        if (ConfigVisibility.of(
          ConfigVisibilityKeys.directorMemoryEmbedding,
          level,
        )) ...[
          SettingsTile(
            child: _EmbeddingModelTile(
              presetId: embeddingPreset,
              modelId: embeddingModel,
            ),
          ),
          directorSectionGap,
        ],

        // ── 事实记忆 ────────────────────────────────────────────
        if (ConfigVisibility.of(
          ConfigVisibilityKeys.directorMemoryFactual,
          level,
        )) ...[
          SettingsTile(
            child: _SwitchRow(
              label: m.factualEnabled,
              desc: m.factualEnabledDesc,
              value: factual?.enabled ?? true,
              writeKey: 'advanced.memory.factual.enabled',
            ),
          ),
          directorSectionGap,
          DirectorStepperRow(
            label: m.keyEntityThreshold,
            value: factual?.keyEntityImportanceThreshold ?? 5,
            min: 1,
            max: 10,
            hint: m.keyEntityThresholdHint,
            onChanged: (v) => writeDirectorOverride(
              ref,
              'advanced.memory.factual.key_entity_importance_threshold',
              v,
            ),
          ),
          directorSectionGap,
        ],

        // ── 归并触发 ────────────────────────────────────────────
        if (ConfigVisibility.of(
          ConfigVisibilityKeys.directorMemoryConsolidation,
          level,
        ))
          DirectorSliderRow(
            label: m.consolidationTrigger,
            value: consolidation?.triggerThreshold ?? 2.0,
            min: 0.5,
            max: 5,
            divisions: 45,
            hint: m.consolidationTriggerHint,
            onChanged: (v) => writeDirectorOverride(
              ref,
              'advanced.consolidation.trigger_threshold',
              v,
            ),
          ),

        // ── 高级子折叠（与归并触发同为进阶专属，间隔行不补）────────
        if (ConfigVisibility.of(
          ConfigVisibilityKeys.directorMemoryAdvanced,
          level,
        ))
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: const EdgeInsets.symmetric(
                horizontal: IntermediateSpacing.sMd,
              ),
              childrenPadding: const EdgeInsets.symmetric(
                horizontal: IntermediateSpacing.sXs,
              ),
              title: Text(
                m.advanced,
                style: IntermediateTextStyles.label
                    .copyWith(color: colors.primary),
              ),
              children: [
                // embedding 调用参数
                DirectorStepperRow(
                  label: m.embeddingTimeout,
                  value: embedding?.timeoutMs ?? 5000,
                  min: 1000,
                  max: 60000,
                  onChanged: (v) => writeDirectorOverride(
                    ref,
                    'advanced.embedding.timeout_ms',
                    v,
                  ),
                ),
                directorSectionGap,
                _SwitchRow(
                  label: m.embeddingFallback,
                  value: embedding?.fallbackOnFailure ?? false,
                  writeKey: 'advanced.embedding.fallback_on_failure',
                ),
                directorSectionGap,
                // 归并批量参数
                DirectorStepperRow(
                  label: m.consolidationMin,
                  value: consolidation?.minArtifactsToConsolidate ?? 3,
                  min: 1,
                  max: 20,
                  onChanged: (v) => writeDirectorOverride(
                    ref,
                    'advanced.consolidation.min_artifacts_to_consolidate',
                    v,
                  ),
                ),
                directorSectionGap,
                DirectorStepperRow(
                  label: m.consolidationMax,
                  value: consolidation?.maxArtifactsToConsolidate ?? 10,
                  min: 5,
                  max: 50,
                  onChanged: (v) => writeDirectorOverride(
                    ref,
                    'advanced.consolidation.max_artifacts_to_consolidate',
                    v,
                  ),
                ),
                directorSectionGap,
                // 记忆检索双门槛（导演运行时消费的两个检索键）
                DirectorStepperRow(
                  label: t.settings.intermediate.storageThreshold,
                  value: retrieval.importanceStorageThreshold,
                  min: 0,
                  max: 5,
                  hint: t.settings.intermediate.storageThresholdHint,
                  onChanged: (v) => writeDirectorOverride(
                    ref,
                    'advanced.retrieval.importance_storage_threshold',
                    v,
                  ),
                ),
                directorSectionGap,
                DirectorStepperRow(
                  label: t.settings.intermediate.vectorizeThresholdLabel,
                  value: retrieval.microVectorizeThreshold,
                  min: 0,
                  max: 5,
                  hint: t.settings.intermediate.vectorizeThresholdHint,
                  onChanged: (v) => writeDirectorOverride(
                    ref,
                    'advanced.retrieval.micro_vectorize_threshold',
                    v,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// 布尔开关行（写 [writeKey]；显式写 true/false）。
class _SwitchRow extends ConsumerWidget {
  const _SwitchRow({
    required this.label,
    required this.value,
    required this.writeKey,
    this.desc,
  });

  final String label;
  final String? desc;
  final bool value;
  final String writeKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.lm.palette;

    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: IntermediateTextStyles.caption
                    .copyWith(color: colors.muted),
              ),
              if (desc != null)
                Text(
                  desc!,
                  style: IntermediateTextStyles.captionSm.copyWith(
                    color: colors.faint,
                  ),
                ),
            ],
          ),
        ),
        Switch(
          value: value,
          activeThumbColor: colors.primary,
          onChanged: (v) => writeDirectorOverride(ref, writeKey, v),
        ),
      ],
    );
  }
}

/// 向量化模型瓦片（DefaultModelPickerSheet 复用，embedding 类型过滤）。
class _EmbeddingModelTile extends ConsumerWidget {
  const _EmbeddingModelTile({required this.presetId, required this.modelId});

  final String presetId;
  final String modelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    final configured = presetId.isNotEmpty && modelId.isNotEmpty;

    return InkWell(
      onTap: () => _openPicker(context, ref),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  t.settings.director.memory.embeddingModel,
                  style: IntermediateTextStyles.caption
                      .copyWith(color: colors.muted),
                ),
              ),
              Icon(Icons.chevron_right, size: 18, color: colors.muted),
            ],
          ),
          const SizedBox(height: IntermediateSpacing.s2xs),
          Text(
            configured
                ? modelId
                : t.settings.director.memory.embeddingModelDesc,
            style: IntermediateTextStyles.bodyUi.copyWith(
              color: configured ? colors.ink : colors.faint,
              fontWeight: FontWeight.w600,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Future<void> _openPicker(BuildContext context, WidgetRef ref) async {
    final t = Translations.of(context);
    await showLmSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => DefaultModelPickerSheet(
        selectedPresetId: presetId.isEmpty ? null : presetId,
        selectedModelId: modelId.isEmpty ? null : modelId,
        title: t.settings.director.memory.embeddingModel,
        modelType: ModelType.embedding,
        clearLabel: t.settings.director.models.clear,
        // 与故事侧嵌入切换同语义：当前已有完整配置时，切换会让已有
        // 向量失效——先确认再落库，避免静默失效。
        onBeforeSelect: (p, m) => _confirmSwitchIfNeeded(context, t),
        onModelSelected: (p, m) async {
          final clear = p == null || m == null;
          await writeDirectorOverride(
            ref,
            'advanced.embedding_preset_id',
            clear ? null : p,
          );
          await writeDirectorOverride(
            ref,
            'advanced.embedding_model_id',
            clear ? null : m,
          );
        },
      ),
    );
  }

  /// 已有完整向量化配置（presetId + modelId 均非空）时弹切换确认。
  Future<bool> _confirmSwitchIfNeeded(
    BuildContext context,
    Translations t,
  ) async {
    if (presetId.isEmpty || modelId.isEmpty) return true;
    final confirmed = await showLmDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          t.settings.director.memory.embeddingSwitchConfirmTitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        content: Text(
          t.settings.director.memory.embeddingSwitchConfirmContent,
          maxLines: 5,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              t.common.cancel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              t.settings.director.memory.embeddingSwitchConfirmAction,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }
}
