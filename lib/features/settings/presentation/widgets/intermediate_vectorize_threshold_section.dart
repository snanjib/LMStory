import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_spacing.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/widgets/commit_slider.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 故事模式设置 — 记忆检索门槛全局配置（2026-08-13 恢复）。
///
/// 控制 `intermediate.retrieval` 的两个重要性门槛（两级向量化策略，
/// DOC-10 §8）：
/// - **存储索引门槛**（importance_storage_threshold，默认 3）：importance 低于
///   此值的记忆不建 FTS5 索引（无法检索），仍保留原始记录供后续批量提炼。
/// - **向量化门槛**（micro_vectorize_threshold，默认 4）：达到此值才生成
///   embedding 语义向量；介于两门槛之间的记忆仅建 FTS5 索引。
///
/// 纳入低分（如 2 分）记忆需同时调低两个门槛（存储门槛 ≤ 向量化门槛）。
///
/// 历史：v0.2.3 宏摘要重构（commit c6c4248）删除承载此阈值的
/// `MacroSummaryConfig`/`IntermediateMemorySection` 容器，阈值参数保留并搬到
/// retrieval 组但无 UI 入口。本组件恢复该入口。
///
/// 持久化：SettingsRepository.user_overrides
/// - `intermediate.retrieval.importance_storage_threshold`
/// - `intermediate.retrieval.micro_vectorize_threshold`
class IntermediateVectorizeThresholdSection extends ConsumerWidget {
  const IntermediateVectorizeThresholdSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final configAsync = ref.watch(intermediateConfigProvider);
    final config = configAsync.valueOrNull;
    final colors = context.lm.palette;
    final t = Translations.of(context);

    final retrieval = config?.retrieval;
    final storageThreshold = retrieval?.importanceStorageThreshold ?? 3;
    final vectorizeThreshold = retrieval?.microVectorizeThreshold ?? 4;
    final isLoading = configAsync.isLoading;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          t.settings.intermediate.vectorizeThreshold,
          style: IntermediateTextStyles.title.copyWith(color: colors.ink),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: IntermediateSpacing.s2xs),
        Text(
          t.settings.intermediate.vectorizeThresholdDesc,
          style: IntermediateTextStyles.caption.copyWith(color: colors.muted),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: IntermediateSpacing.sMd),
        Material(
          color: colors.surface,
          borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
          child: Padding(
            padding: const EdgeInsets.all(IntermediateSpacing.sLg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _ThresholdSlider(
                  label: t.settings.intermediate.storageThreshold,
                  value: storageThreshold,
                  hint: t.settings.intermediate.storageThresholdHint,
                  enabled: !isLoading,
                  onChanged:
                      isLoading ? null : (v) => _onStorageChanged(ref, v),
                ),
                const SizedBox(height: IntermediateSpacing.sMd),
                _ThresholdSlider(
                  label: t.settings.intermediate.vectorizeThresholdLabel,
                  value: vectorizeThreshold,
                  hint: t.settings.intermediate.vectorizeThresholdHint,
                  enabled: !isLoading,
                  onChanged:
                      isLoading ? null : (v) => _onVectorizeChanged(ref, v),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _onStorageChanged(WidgetRef ref, int value) async {
    final repo = ref.read(settingsRepositoryProvider);
    await repo.setUserOverride(
      'intermediate.retrieval.importance_storage_threshold',
      value,
    );
    ref.invalidate(intermediateConfigProvider);
  }

  Future<void> _onVectorizeChanged(WidgetRef ref, int value) async {
    final repo = ref.read(settingsRepositoryProvider);
    await repo.setUserOverride(
      'intermediate.retrieval.micro_vectorize_threshold',
      value,
    );
    ref.invalidate(intermediateConfigProvider);
  }
}

/// 1-5 分整数控块（importance 评分）。
class _ThresholdSlider extends StatelessWidget {
  const _ThresholdSlider({
    required this.label,
    required this.value,
    required this.hint,
    required this.enabled,
    required this.onChanged,
  });

  final String label;
  final int value;
  final String hint;
  final bool enabled;
  final ValueChanged<int>? onChanged;

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: IntermediateTextStyles.caption
                    .copyWith(color: colors.muted),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(
              t.settings.intermediate.vectorizeThresholdLevel(score: value),
              style: IntermediateTextStyles.caption.copyWith(color: colors.ink),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        CommitSlider(
          value: value.toDouble(),
          min: 1,
          max: 5,
          divisions: 4,
          activeColor: colors.primary,
          inactiveColor: colors.primaryDim,
          enabled: enabled && onChanged != null,
          labelBuilder: (v) =>
              t.settings.intermediate.vectorizeThresholdLevel(score: v.round()),
          onCommit: (v) => onChanged?.call(v.round()),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            hint,
            style: IntermediateTextStyles.caption.copyWith(
              color: colors.faint,
              fontSize: 11,
            ),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
