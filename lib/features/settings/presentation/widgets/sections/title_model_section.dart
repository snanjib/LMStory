import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/theme/simple/components/simple_setting_card.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/features/settings/presentation/controllers/settings_controller.dart';
import 'package:lmstory/features/settings/presentation/widgets/default_model_picker_sheet.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 通用设置 → 高级 — 会话标题模型入口卡片（2026-07-21 新增）。
///
/// 卡片显示当前选中的标题模型（供应商名 · 模型名），点击后弹出
/// [DefaultModelPickerSheet] 底部选择面板（复用，传入 onModelSelected 回调）。
///
/// 持久化于 `common.title_model.preset_id` 与 `common.title_model.model_id`。
///
/// 设计取舍：独立于业务模式（对话/故事），所有模式的会话标题自动生成都使用此配置。
/// 未配置时先用该会话生成正文的模型起标题，仍失败才降级为回复内容前几个字
/// （SessionTitleGenerator.fallbackTitle，三级优先级）。
class TitleModelSection extends ConsumerWidget {
  const TitleModelSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 仅订阅标题模型相关切片：其它设置字段变更不触发本节重建
    final presets = ref.watch(
      settingsNotifierProvider.select((s) => s.presets),
    );
    final titlePresetId = ref.watch(
      settingsNotifierProvider.select((s) => s.titleModelPresetId),
    );
    final titleModelId = ref.watch(
      settingsNotifierProvider.select((s) => s.titleModelModelId),
    );
    final t = Translations.of(context);

    final preset =
        presets.where((p) => p.presetId == titlePresetId).firstOrNull;
    final model = preset?.cachedModels
        .where((m) => m.modelId == titleModelId)
        .firstOrNull;

    final hasSelection = preset != null && model != null;
    final String subtitle;
    if (hasSelection) {
      subtitle = '${preset.name} · ${model.displayName ?? model.modelId}';
    } else {
      // 未配置：提示先用当前生成模型起标题，失败时截取回复前缀（三级优先级）
      subtitle = t.settings.general.titleModelNotConfigured;
    }

    return SimpleSettingCard(
      icon: Icons.title_outlined,
      title: t.settings.general.titleModel,
      subtitle: subtitle,
      onTap: () => _showPicker(context, ref),
    );
  }

  void _showPicker(BuildContext context, WidgetRef ref) {
    final state = ref.read(settingsNotifierProvider);
    final t = Translations.of(context);
    showLmSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DefaultModelPickerSheet(
        selectedPresetId: state.titleModelPresetId,
        selectedModelId: state.titleModelModelId,
        title: t.settings.general.titleModel,
        successMessage: t.settings.general.titleModelSaved,
        // 配置后无清除路径——setTitleModel 的 null
        // 分支（removeUserOverride 双键）早已就绪但 UI 从未传 clearLabel。
        // 清除 tile 改标题模型专用键——此前复用
        // 「清除默认模型」在本面板语境错位。
        clearLabel: t.settings.general.titleModelClear,
        clearSuccessMessage: t.settings.general.titleModelNotConfigured,
        onModelSelected: (presetId, modelId) => ref
            .read(settingsNotifierProvider.notifier)
            .setTitleModel(presetId: presetId, modelId: modelId),
      ),
    );
  }
}
