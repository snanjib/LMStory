import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/entities/model_capability.dart';
import 'package:lmstory/features/settings/presentation/controllers/settings_controller.dart';
import 'package:lmstory/features/settings/presentation/widgets/default_model_picker_sheet.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 回退模型预览数据（仅用于副标题显示，不参与持久化）。
class _FallbackModel {
  const _FallbackModel({required this.presetName, required this.modelName});

  final String presetName;
  final String modelName;
}

/// 对话模式设置 — 默认模型入口卡片。
///
/// 卡片显示当前选中的默认模型（供应商名 · 模型名），点击后弹出
/// [DefaultModelPickerSheet] 底部选择面板。
///
/// 持久化于 `broadcast_chat.preset_id` 与 `broadcast_chat.model_id`
/// （计划从 `default_preset_id` / `broadcast_chat.model_id` 统一 key）。
///
/// 设计取舍：相对故事模式 IntermediateDefaultModelSection 的 Dropdown 形式，
/// 这里采用"卡片入口 + 底部 sheet"，因为对话模型列表通常较长，sheet
/// 提供更大的展示空间和更好的分组浏览体验。
class ChatDefaultModelSection extends ConsumerWidget {
  const ChatDefaultModelSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 仅订阅默认模型相关切片：其它设置字段变更不触发本节重建
    final presets = ref.watch(
      settingsNotifierProvider.select((s) => s.presets),
    );
    final defaultPresetId = ref.watch(
      settingsNotifierProvider.select((s) => s.defaultPresetId),
    );
    final defaultModelId = ref.watch(
      settingsNotifierProvider.select((s) => s.defaultModelId),
    );
    final t = Translations.of(context);

    final preset =
        presets.where((p) => p.presetId == defaultPresetId).firstOrNull;
    final model = preset?.cachedModels
        .where((m) => m.modelId == defaultModelId)
        .firstOrNull;

    final hasSelection = preset != null && model != null;
    // 2026-07-19 修复：未设置默认模型时，不能只显示"未设置"——用户不知道
    // 新会话会用什么。回退逻辑：第一个有 chat 类型模型的 preset 的首个 chat 模型。
    // 若所有供应商都没有 chat 模型，提示"暂无可用供应商"。
    final String subtitle;
    if (hasSelection) {
      subtitle = '${preset.name} · ${model.displayName ?? model.modelId}';
    } else {
      final fallback = _findFallbackModel(presets);
      if (fallback != null) {
        subtitle = t.settings.chatSettings.defaultModel.notSelectedWithCurrent(
          current: '${fallback.presetName} · ${fallback.modelName}',
        );
      } else {
        subtitle = t.settings.chatSettings.defaultModel.noProviderAvailable;
      }
    }

    return context.lmUi.settingCard(
      context,
      icon: Icons.smart_toy_outlined,
      title: t.settings.chatSettings.defaultModel.title,
      subtitle: subtitle,
      onTap: () => _showPicker(
        context,
        selectedPresetId: defaultPresetId,
        selectedModelId: defaultModelId,
      ),
    );
  }

  /// 查找回退模型：第一个有 chat 类型模型的 preset 的首个 chat 模型。
  ///
  /// 优先级链（ConfigurationResolver）：preset_id 为空时取第一个 preset，
  /// model_id 为空时取 broadcastChat.modelId。但 broadcastChat.modelId
  /// 也可能为空——这种情况下完全无可用模型。本方法仅返回第一个可用 chat 模型
  /// 作为预览，让用户知道"新会话建立时会用这个"。
  /// 若所有 preset 都没有 chat 类型模型，返回 null。
  _FallbackModel? _findFallbackModel(List<ApiPreset> presets) {
    for (final preset in presets) {
      for (final model in preset.cachedModels) {
        if (model.type == ModelType.chat) {
          return _FallbackModel(
            presetName: preset.name,
            modelName: model.displayName ?? model.modelId,
          );
        }
      }
    }
    return null;
  }

  void _showPicker(
    BuildContext context, {
    required String? selectedPresetId,
    required String? selectedModelId,
  }) {
    final t = Translations.of(context);
    showLmSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DefaultModelPickerSheet(
        selectedPresetId: selectedPresetId,
        selectedModelId: selectedModelId,
        // 配置后无清除路径——setDefaultModel 的 null
        // 分支（removeUserOverride 双键）早已就绪但 UI 从未传 clearLabel。
        // 不传 clearSuccessMessage：无现成键（本批不改 yaml），静默清除后
        // 卡片副标题立即回退为「未设置（将使用 X）」，反馈由副标题承担。
        clearLabel: t.settings.chatSettings.defaultModel.clear,
      ),
    );
  }
}
