import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_spacing.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/widgets/commit_slider.dart';
import 'package:lmstory/features/settings/presentation/widgets/context_budget_slider.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 故事模式设置 — 上下文预算全局配置（夜航主题）。
///
/// 控制 `intermediate.contextBudget` 配置项：
/// - **压缩触发线**（compactionTriggerRatio）：默认 0.5，可调 0.30-0.80
///   （DOC-14 §3.3 由固定改为可调）
/// - **原文区下限**（recentMinRatio）：null=动态（基于 32K token 反推），
///   非 null=用户自定义百分比
/// - **检索区比例**（retrievalRatio）：默认 0.15
///
/// 持久化：SettingsRepository.user_overrides
/// - `intermediate.contextBudget.compactionTriggerRatio`
/// - `intermediate.contextBudget.recentMinRatio`（null 时 removeUserOverride）
/// - `intermediate.contextBudget.retrievalRatio`
///
/// 交互模式：即时持久化（slider 变更即保存）
/// 因为数值变更无需 dirty state。
///
/// 可用窗口（availableWindow）：从 `intermediateGlobalContextWindowProvider`
/// 读取全局 phaseModels 配置的 generating/reviewing 模型的 contextWindow，
/// 分别展示生成阶段和审查阶段的 token 预估。
/// 未配置模型时回退到 `ConfigurationResolver.defaultContextWindow`（96000）。
class IntermediateContextBudgetSection extends ConsumerWidget {
  const IntermediateContextBudgetSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final configAsync = ref.watch(intermediateConfigProvider);
    final config = configAsync.valueOrNull;
    final colors = context.lm.palette;
    final t = Translations.of(context);

    // 读取全局 phaseModels 的 generating/reviewing 模型 contextWindow
    final windowsAsync = ref.watch(intermediateGlobalContextWindowProvider);
    final windows = windowsAsync.valueOrNull;
    final generatingWindow = windows?.generating ?? 96000;
    final reviewingWindow = windows?.reviewing;

    final budget = config?.contextBudget;
    final compactionTriggerRatio = budget?.compactionTriggerRatio ?? 0.5;
    final recentMinRatio = budget?.recentMinRatio;
    final retrievalRatio = budget?.retrievalRatio ?? 0.15;
    final recentMinTokenTarget = budget?.recentMinTokenTarget ?? 32000;
    final effectiveContextLimit = config?.context.effectiveContextLimit;
    final isLoading = configAsync.isLoading || windowsAsync.isLoading;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          t.settings.intermediate.contextBudget,
          style: IntermediateTextStyles.title.copyWith(color: colors.ink),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: IntermediateSpacing.s2xs),
        Text(
          t.settings.intermediate.contextBudgetDesc,
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
            child: ContextBudgetSlider(
              compactionTriggerRatio: compactionTriggerRatio,
              recentMinRatio: recentMinRatio,
              retrievalRatio: retrievalRatio,
              availableWindow: generatingWindow,
              secondaryWindow: reviewingWindow,
              recentMinTokenTarget: recentMinTokenTarget,
              enabled: !isLoading,
              onCompactionTriggerRatioChanged: isLoading
                  ? null
                  : (value) => _onCompactionTriggerRatioChanged(ref, value),
              onMinRatioChanged:
                  isLoading ? null : (value) => _onMinRatioChanged(ref, value),
              onRetrievalRatioChanged: isLoading
                  ? null
                  : (value) => _onRetrievalRatioChanged(ref, value),
            ),
          ),
        ),
        // v0.2.2 阶段 2-C 新增：单次请求 token 上限全局配置
        // 当 effectiveContextLimit < contextWindow 时，作为上下文管理基准
        //（替代 contextWindow 用于压缩触发线/检索区/原文区预算计算）
        const SizedBox(height: IntermediateSpacing.sMd),
        Material(
          color: colors.surface,
          borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
          child: Padding(
            padding: const EdgeInsets.all(IntermediateSpacing.sLg),
            child: _EffectiveContextLimitSlider(
              value: effectiveContextLimit,
              availableWindow: generatingWindow,
              enabled: !isLoading,
              onChanged: isLoading
                  ? null
                  : (v) => _onEffectiveContextLimitChanged(ref, v),
            ),
          ),
        ),
      ],
    );
  }

  /// effectiveContextLimit 变更：null 时 removeUserOverride（使用模型窗口），
  /// 非 null 时显式写入。
  ///
  /// v0.2.2 阶段 2-C 新增。当 effectiveContextLimit < 模型 contextWindow 时，
  /// IntermediateChatController._resolveContextWindow 会取较小值作为实际
  /// contextWindow，所有上下文预算计算基于此 smaller 值。
  Future<void> _onEffectiveContextLimitChanged(
    WidgetRef ref,
    int? value,
  ) async {
    final repo = ref.read(settingsRepositoryProvider);
    if (value == null || value <= 0) {
      await repo.removeUserOverride(
        'intermediate.context.effective_context_limit',
      );
    } else {
      await repo.setUserOverride(
        'intermediate.context.effective_context_limit',
        value,
      );
    }
    ref.invalidate(intermediateConfigProvider);
  }

  /// 下限比例变更：null 时 removeUserOverride（回到动态计算），
  /// 非 null 时显式写入。
  Future<void> _onMinRatioChanged(WidgetRef ref, double? value) async {
    final repo = ref.read(settingsRepositoryProvider);
    if (value == null) {
      await repo.removeUserOverride(
        'intermediate.contextBudget.recentMinRatio',
      );
    } else {
      await repo.setUserOverride(
        'intermediate.contextBudget.recentMinRatio',
        value,
      );
    }
    ref.invalidate(intermediateConfigProvider);
  }

  /// 检索区比例变更：始终显式写入。
  Future<void> _onRetrievalRatioChanged(WidgetRef ref, double value) async {
    final repo = ref.read(settingsRepositoryProvider);
    await repo.setUserOverride(
      'intermediate.contextBudget.retrievalRatio',
      value,
    );
    ref.invalidate(intermediateConfigProvider);
  }

  /// 压缩触发线变更（DOC-14 §3.3）：始终显式写入。
  Future<void> _onCompactionTriggerRatioChanged(
    WidgetRef ref,
    double value,
  ) async {
    final repo = ref.read(settingsRepositoryProvider);
    await repo.setUserOverride(
      'intermediate.contextBudget.compactionTriggerRatio',
      value,
    );
    ref.invalidate(intermediateConfigProvider);
  }
}

/// 单次请求 token 上限滑块（v0.2.2 阶段 2-C 新增）。
///
/// 控制 `intermediate.context.effective_context_limit` 配置项。
/// 用于应对 TPM 限制（如腾讯云 500万 TPM）：模型窗口虽大（如 GLM5.2 = 1M），
/// 但单次请求塞太多会触发 429。用户可通过此配置主动限制每次请求塞入的
/// token 数。
///
/// **作用范围**：仅影响 generating/reviewing 阶段的 token 预算缩减。
/// 实际生效值 = min(配置值, 模型窗口)，由
/// IntermediateChatController._resolveContextWindow 计算。
///
/// **快照语义**：本值为全局默认，会话级 effectiveContextLimit 字段在
/// 物化时读取此值并写入 chat_sessions.effective_context_limit。
///
/// 0 = 无限制（使用模型窗口）；其他值 = 实际 token 上限。
class _EffectiveContextLimitSlider extends StatelessWidget {
  const _EffectiveContextLimitSlider({
    required this.value,
    required this.availableWindow,
    required this.onChanged,
    this.enabled = true,
  });

  final int? value;
  final int availableWindow;
  final ValueChanged<int?>? onChanged;
  final bool enabled;

  /// 预设档位（按 2 倍递增，覆盖主流模型窗口量级）
  /// 0 = 无限制（使用模型窗口）；其他值 = 实际 token 上限。
  /// 与会话级 IntermediateEffectiveContextLimitSlider._options 保持一致，
  /// 避免全局/会话档位错位导致显示异常。
  static const _options = [
    0,
    4096,
    8192,
    16384,
    32768,
    65536,
    131072,
    262144,
    524288,
  ];

  String _formatK(int tokens) {
    if (tokens >= 1024) {
      final k = tokens ~/ 1024;
      return '${k}K';
    }
    return tokens.toString();
  }

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;
    final actualValue = value ?? 0;
    var sliderIndex = 0;
    if (actualValue > 0) {
      for (var i = _options.length - 1; i >= 0; i--) {
        if (_options[i] <= actualValue) {
          sliderIndex = i;
          break;
        }
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                t.settings.intermediate.effectiveContextLimitGlobal,
                style: IntermediateTextStyles.caption
                    .copyWith(color: colors.muted),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(
              actualValue == 0
                  ? t.settings.intermediate.effectiveContextLimitNoLimit
                  : _formatK(actualValue),
              style: IntermediateTextStyles.caption.copyWith(
                color: actualValue > 0 ? colors.ink : colors.faint,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        CommitSlider(
          value: sliderIndex.toDouble(),
          min: 0,
          max: (_options.length - 1).toDouble(),
          divisions: _options.length - 1,
          activeColor: colors.primary,
          inactiveColor: colors.primaryDim,
          enabled: enabled && onChanged != null,
          labelBuilder: (idx) {
            final option = _options[idx.round()];
            return option == 0
                ? t.settings.intermediate.effectiveContextLimitNoLimit
                : _formatK(option);
          },
          onCommit: (idx) {
            final v = _options[idx.round()];
            onChanged?.call(v == 0 ? null : v);
          },
        ),
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            t.settings.intermediate.effectiveContextLimitGlobalHint,
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
