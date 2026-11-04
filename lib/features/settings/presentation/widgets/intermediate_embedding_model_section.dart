import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_spacing.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/entities/model_capability.dart';
import 'package:lmstory/features/settings/presentation/widgets/intermediate_model_picker_sheet.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 故事模式设置 — 嵌入模型区块（夜航主题）。
///
/// 用于配置语义检索的嵌入模型，独立于聊天模型（IntermediateDefaultModelSection）。
/// 配置后启用 Vector 语义检索（DOC-08 §3.4）；留空则仅用关键词检索（FTS5 兜底）。
///
/// **2026-07-24 双菜单→单菜单改造**：
/// - 删除原"供应商 dropdown + 模型 dropdown"双 dropdown 设计
/// - 改为单个 叙事设置卡（context.lmUi.settingCard）入口，点击弹出
///   [IntermediateModelPickerSheet]（modelType: embedding）
/// - 切换前确认对话框通过 [IntermediateModelPickerSheet.onBeforeSelect] 钩子实现
/// - 保留 stale 清理逻辑（供应商被删除后悬空引用清理）
///
/// 持久化：SettingsRepository.user_overrides
/// - `intermediate.embedding_preset_id`：空串/移除 = 未配置 embedding
/// - `intermediate.embedding_model_id`：空串/移除 = 未配置 embedding
///
/// 约束：嵌入模型属于全局配置，无会话级覆盖（与 phase_models 不同）。
/// 切换会让已有向量失效 → 选择前弹确认对话框让用户知情。
class IntermediateEmbeddingModelSection extends ConsumerStatefulWidget {
  const IntermediateEmbeddingModelSection({super.key});

  @override
  ConsumerState<IntermediateEmbeddingModelSection> createState() =>
      _IntermediateEmbeddingModelSectionState();
}

class _IntermediateEmbeddingModelSectionState
    extends ConsumerState<IntermediateEmbeddingModelSection> {
  List<ApiPreset> _presets = const [];
  bool _isLoading = true;
  bool _hasError = false;

  /// 标记本帧是否已触发 stale 配置清理，避免 invalidate 导致 build 循环。
  /// 2026-07-17 修复：详见 IntermediateDefaultModelSection 同名字段说明。
  bool _staleCleared = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(_loadPresets);
  }

  Future<void> _loadPresets() async {
    try {
      final presets =
          await ref.read(apiPresetRepositoryProvider).getAllPresets();
      if (!mounted) return;
      setState(() {
        _presets = presets;
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _hasError = true;
        _isLoading = false;
      });
    }
  }

  /// 切换嵌入模型前的确认对话框。
  ///
  /// 若当前已有完整 embedding 配置（presetId + modelId 都非空），
  /// 切换会让已有向量失效，先弹确认对话框让用户知情。
  /// 返回 true 表示用户确认切换，false 表示取消。
  Future<bool> _confirmSwitchIfNeeded() async {
    final config = ref.read(intermediateConfigProvider).valueOrNull;
    final currentPresetId = config?.embeddingPresetId ?? '';
    final currentModelId = config?.embeddingModelId ?? '';
    if (currentPresetId.isEmpty || currentModelId.isEmpty) {
      // 当前未配完整 embedding → 无需确认
      return true;
    }
    return _showConfirmSwitch();
  }

  /// 切换嵌入模型确认对话框。
  ///
  /// 告知用户「切换后已有记忆的向量将不再参与语义检索」，避免静默失效。
  Future<bool> _showConfirmSwitch() async {
    final t = Translations.of(context);
    final confirmed = await showLmDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          t.settings.intermediate.embeddingSwitchConfirmTitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        content: Text(
          t.settings.intermediate.embeddingSwitchConfirmContent,
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
              t.settings.intermediate.embeddingSwitchConfirmAction,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  /// 持久化嵌入模型选择（presetId + modelId 一起写）。
  ///
  /// 此方法由 [IntermediateModelPickerSheet.onModelSelected] 调用，
  /// 接受具体 presetId/modelId（非 null，因为嵌入模型无"使用全局"语义）。
  Future<void> _persistEmbedding(String? presetId, String? modelId) async {
    final repo = ref.read(settingsRepositoryProvider);
    if (presetId == null || modelId == null) {
      // 理论上不会进入此分支（embedding 不提供 clearLabel），
      // 但保持参数语义完整以匹配 IntermediateModelPickerSheet 签名。
      await repo.removeUserOverride('intermediate.embedding_preset_id');
      await repo.removeUserOverride('intermediate.embedding_model_id');
    } else {
      await repo.setUserOverride('intermediate.embedding_preset_id', presetId);
      await repo.setUserOverride('intermediate.embedding_model_id', modelId);
    }
    ref.invalidate(intermediateConfigProvider);
    if (!mounted) return;
    _showSnackbar(
      Translations.of(context).settings.intermediate.embeddingModelSaved,
    );
  }

  void _showSnackbar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(
          message,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final configAsync = ref.watch(intermediateConfigProvider);
    final config = configAsync.valueOrNull;
    final colors = context.lm.palette;
    final t = Translations.of(context);

    final currentPresetId = config?.embeddingPresetId ?? '';
    final currentModelId = config?.embeddingModelId ?? '';
    final selectedPreset =
        _presets.where((p) => p.presetId == currentPresetId).firstOrNull;
    // 2026-07-17 修复：供应商被删除后 preset_id 变成悬空引用，
    // 检测到悬空时降级显示"未配置"，并异步清理 stale key。
    //
    // 2026-07-21 修复 stale 误清理 bug：原实现在首次 build 时 _presets = const []
    // （_loadPresets 异步加载未完成），导致 selectedPreset = null → presetExists = false
    // → 误触发清理 → 永久删除用户已保存的 embedding 配置。
    // 现仅在 _presets 已加载（_isLoading == false）后才检测并清理悬空引用。
    final presetExists = currentPresetId.isEmpty || selectedPreset != null;
    if (!presetExists && !_staleCleared && !_isLoading) {
      _staleCleared = true;
      _clearStaleEmbeddingConfig();
    }
    final selectedModel = selectedPreset?.cachedModels
        .where((m) => m.modelId == currentModelId)
        .firstOrNull;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          t.settings.intermediate.embeddingModel,
          style: IntermediateTextStyles.title.copyWith(color: colors.ink),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: IntermediateSpacing.s2xs),
        Text(
          t.settings.intermediate.embeddingModelDesc,
          style: IntermediateTextStyles.caption.copyWith(color: colors.muted),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: IntermediateSpacing.sMd),
        Container(
          padding: const EdgeInsets.all(IntermediateSpacing.sLg),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius:
                BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
          ),
          child: _buildBody(
            colors: colors,
            t: t,
            isLoading: _isLoading,
            hasError: _hasError,
            currentPresetId: currentPresetId,
            currentModelId: currentModelId,
            selectedPreset: selectedPreset,
            selectedModel: selectedModel,
            presetExists: presetExists,
          ),
        ),
      ],
    );
  }

  Widget _buildBody({
    required LmPalette colors,
    required Translations t,
    required bool isLoading,
    required bool hasError,
    required String currentPresetId,
    required String currentModelId,
    required ApiPreset? selectedPreset,
    required ModelInfo? selectedModel,
    required bool presetExists,
  }) {
    if (isLoading) {
      return _loadingHint(colors, t);
    }
    if (hasError) {
      return _errorHint(colors, t);
    }
    return _buildEmbeddingCard(
      colors: colors,
      t: t,
      currentPresetId: currentPresetId,
      currentModelId: currentModelId,
      selectedPreset: selectedPreset,
      selectedModel: selectedModel,
      presetExists: presetExists,
    );
  }

  /// 嵌入模型选择卡片入口。
  ///
  /// 卡片副标题显示规则：
  /// - 已配 preset+model → "供应商名 · 模型名"
  /// - 未配 → "未配置（仅用关键词检索）"
  Widget _buildEmbeddingCard({
    required LmPalette colors,
    required Translations t,
    required String currentPresetId,
    required String currentModelId,
    required ApiPreset? selectedPreset,
    required ModelInfo? selectedModel,
    required bool presetExists,
  }) {
    final String subtitle;
    if (presetExists &&
        currentPresetId.isNotEmpty &&
        selectedPreset != null &&
        selectedModel != null) {
      final modelDesc = selectedModel.displayName ?? selectedModel.modelId;
      subtitle = '${selectedPreset.name} · $modelDesc';
    } else {
      subtitle = t.settings.intermediate.embeddingModelNotConfigured;
    }

    return context.lmUi.settingCard(
      context,
      narrative: true,
      icon: Icons.account_tree_outlined,
      title: t.settings.intermediate.embeddingModel,
      subtitle: subtitle,
      onTap: () => _showEmbeddingModelPicker(t),
    );
  }

  /// 弹出 IntermediateModelPickerSheet 选择嵌入模型。
  ///
  /// - modelType: ModelType.embedding（仅展示嵌入类型模型，旧数据 fallback 全部）
  /// - onBeforeSelect: 切换前确认（已有完整配置时弹对话框）
  /// - 不提供 clearLabel（嵌入模型无"使用全局"语义）
  void _showEmbeddingModelPicker(Translations t) {
    final config = ref.read(intermediateConfigProvider).valueOrNull;
    final currentPresetId = config?.embeddingPresetId ?? '';
    final currentModelId = config?.embeddingModelId ?? '';

    showLmSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => IntermediateModelPickerSheet(
        selectedPresetId: currentPresetId.isEmpty ? null : currentPresetId,
        selectedModelId: currentModelId.isEmpty ? null : currentModelId,
        title: t.settings.intermediate.embeddingModel,
        modelType: ModelType.embedding,
        successMessage: t.settings.intermediate.embeddingModelSaved,
        onBeforeSelect: (_, __) => _confirmSwitchIfNeeded(),
        onModelSelected: _persistEmbedding,
      ),
    );
  }

  /// 异步清理嵌入模型的悬空配置（preset_id + model_id）。
  ///
  /// 仅在检测到 currentPresetId 指向已删除的供应商时调用。
  /// 通过 microtask 避免在 build 中同步触发 setState/invalidate 导致循环。
  Future<void> _clearStaleEmbeddingConfig() async {
    await Future.microtask(() async {
      if (!mounted) return;
      final repo = ref.read(settingsRepositoryProvider);
      await repo.removeUserOverride('intermediate.embedding_preset_id');
      await repo.removeUserOverride('intermediate.embedding_model_id');
      ref.invalidate(intermediateConfigProvider);
    });
  }

  Widget _loadingHint(LmPalette colors, Translations t) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: IntermediateSpacing.sMd),
      child: Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: colors.faint,
            ),
          ),
          const SizedBox(width: IntermediateSpacing.sSm),
          Expanded(
            child: Text(
              t.settings.intermediate.loading,
              style:
                  IntermediateTextStyles.caption.copyWith(color: colors.faint),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _errorHint(LmPalette colors, Translations t) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: IntermediateSpacing.sMd),
      child: Text(
        t.settings.intermediate.presetsLoadFailed,
        style: IntermediateTextStyles.caption.copyWith(color: colors.error),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
