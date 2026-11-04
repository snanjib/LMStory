import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/config/intermediate_prompts_v2.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_spacing.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_layout.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/widgets/commit_slider.dart';
import 'package:lmstory/core/widgets/editable_value_text.dart';
import 'package:lmstory/core/widgets/numeric_input_dialog.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/settings/presentation/pages/intermediate_settings_page.dart'
    show IntermediateSettingsPage;
import 'package:lmstory/features/settings/presentation/widgets/intermediate_model_picker_sheet.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 故事模式设置 — 推荐回复配置子页（2026-07-29 新增）。
///
/// 配置输入框「推荐」按钮使用的模型、提示词和生成参数。
/// 从 [IntermediateSettingsPage] 顶层分类卡片进入。
///
/// 三大区块：
/// - 推荐回复模型：专用 preset + model，留空回退到 generating 阶段模型
/// - 推荐回复提示词：系统提示词，留空使用内置默认 kSuggestReplyDefaultPrompt
/// - 生成参数：温度 / maxTokens / 候选数量 / 单条最大字数
///
/// 持久化 key 前缀：`intermediate.suggest_reply.*`
/// - `intermediate.suggest_reply.preset_id`
/// - `intermediate.suggest_reply.model_id`
/// - `intermediate.suggest_reply.prompt`
/// - `intermediate.suggest_reply.temperature`
/// - `intermediate.suggest_reply.max_tokens`
/// - `intermediate.suggest_reply.candidate_count`
/// - `intermediate.suggest_reply.max_reply_length`
class IntermediateSuggestReplySettingsPage extends ConsumerStatefulWidget {
  const IntermediateSuggestReplySettingsPage({super.key});

  @override
  ConsumerState<IntermediateSuggestReplySettingsPage> createState() =>
      _IntermediateSuggestReplySettingsPageState();
}

class _IntermediateSuggestReplySettingsPageState
    extends ConsumerState<IntermediateSuggestReplySettingsPage> {
  final TextEditingController _promptController = TextEditingController();
  List<ApiPreset> _presets = const [];
  bool _isLoadingPresets = true;
  bool _promptInitialized = false;
  String _loadedPrompt = '';
  bool _isSavingPrompt = false;
  bool _staleCleared = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(_loadPresets);
  }

  @override
  void dispose() {
    _promptController.dispose();
    super.dispose();
  }

  Future<void> _loadPresets() async {
    try {
      final presets =
          await ref.read(apiPresetRepositoryProvider).getAllPresets();
      if (!mounted) return;
      setState(() {
        _presets = presets;
        _isLoadingPresets = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _isLoadingPresets = false);
    }
  }

  // ── 模型持久化 ────────────────────────────────────────────────────

  Future<void> _persistModel(String? presetId, String? modelId) async {
    final repo = ref.read<SettingsRepository>(settingsRepositoryProvider);
    if (presetId == null || modelId == null) {
      await repo.removeUserOverride('intermediate.suggest_reply.preset_id');
      await repo.removeUserOverride('intermediate.suggest_reply.model_id');
    } else {
      await repo.setUserOverride(
        'intermediate.suggest_reply.preset_id',
        presetId,
      );
      await repo.setUserOverride(
        'intermediate.suggest_reply.model_id',
        modelId,
      );
    }
    ref.invalidate(intermediateConfigProvider);
    if (!mounted) return;
    _showSnackbar(
      presetId == null
          ? Translations.of(context)
              .settings
              .intermediate
              .suggestReply
              .modelCleared
          : Translations.of(context)
              .settings
              .intermediate
              .suggestReply
              .modelSaved,
    );
  }

  Future<void> _clearStaleModelConfig() async {
    await Future.microtask(() async {
      if (!mounted) return;
      final repo = ref.read<SettingsRepository>(settingsRepositoryProvider);
      await repo.removeUserOverride('intermediate.suggest_reply.preset_id');
      await repo.removeUserOverride('intermediate.suggest_reply.model_id');
      ref.invalidate(intermediateConfigProvider);
    });
  }

  // ── 提示词持久化 ──────────────────────────────────────────────────

  /// 初始化提示词输入框。
  ///
  /// **永远显示当前生效的提示词内容**：
  /// - configValue 非空 → 显示 configValue
  /// - configValue 为空 → 显示内置默认 kSuggestReplyDefaultPrompt
  ///
  /// 这样输入框内容与运行时生效内容永远一致。
  /// 留空（用户手动清空）视为兜底情况，运行时回退到内置默认。
  void _ensurePromptInit(bool hasValue, String configValue) {
    if (_promptInitialized || !hasValue) return;
    _loadedPrompt =
        configValue.isEmpty ? kSuggestReplyDefaultPrompt : configValue;
    _promptController.text = _loadedPrompt;
    _promptInitialized = true;
  }

  bool _isPromptDirty() => _promptController.text != _loadedPrompt;

  Future<void> _savePrompt() async {
    if (!_isPromptDirty() || _isSavingPrompt) return;
    setState(() => _isSavingPrompt = true);
    try {
      final repo = ref.read(settingsRepositoryProvider);
      final text = _promptController.text.trim();
      if (text.isEmpty) {
        // 留空 = 兜底情况，移除覆盖，运行时回退到内置默认。
        // 保存后重新填入默认提示词，保持输入框与生效内容一致。
        await repo.removeUserOverride('intermediate.suggest_reply.prompt');
        _promptController.text = kSuggestReplyDefaultPrompt;
        _loadedPrompt = kSuggestReplyDefaultPrompt;
      } else {
        await repo.setUserOverride('intermediate.suggest_reply.prompt', text);
        // 回写 trim 后的值——此前输入框保持
        // 原文（含空白），_isPromptDirty 恒真，PopScope 反复拦截退出且
        // 保存按钮常亮，用户以为"保存没生效"
        _promptController.text = text;
        _loadedPrompt = text;
      }
      ref.invalidate(intermediateConfigProvider);
      if (mounted) {
        final t = Translations.of(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(
              t.settings.intermediate.suggestReply.promptSaved,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSavingPrompt = false);
    }
  }

  Future<void> _resetPrompt() async {
    final t = Translations.of(context);
    final confirmed = await showLmDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          t.settings.intermediate.reset,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        content: Text(
          t.settings.intermediate.suggestReply.promptResetConfirm,
          maxLines: 4,
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
              t.settings.intermediate.reset,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    // 将内置默认提示词填入输入框并保存，让用户能看到完整内容并基于它修改。
    // 保存后 prompt 字段 = 默认提示词副本，运行时直接使用此副本。
    // 未来内置默认更新时，用户可再次点「恢复默认」获取最新版本。
    const defaultPrompt = kSuggestReplyDefaultPrompt;
    final repo = ref.read(settingsRepositoryProvider);
    await repo.setUserOverride(
      'intermediate.suggest_reply.prompt',
      defaultPrompt,
    );
    ref.invalidate(intermediateConfigProvider);
    _promptController.text = defaultPrompt;
    _loadedPrompt = defaultPrompt;
    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            t.settings.intermediate.suggestReply.promptResetDone,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
    }
  }

  // ── 生成参数持久化 ────────────────────────────────────────────────

  Future<void> _persistNum(String key, num value) async {
    final repo = ref.read(settingsRepositoryProvider);
    await repo.setUserOverride(key, value);
    ref.invalidate(intermediateConfigProvider);
  }

  Future<void> _persistInt(String key, int value) async {
    final repo = ref.read(settingsRepositoryProvider);
    await repo.setUserOverride(key, value);
    ref.invalidate(intermediateConfigProvider);
  }

  // ── UI 辅助 ───────────────────────────────────────────────────────

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
    _ensurePromptInit(configAsync.hasValue, config?.suggestReply.prompt ?? '');

    return _buildScaffold(context, configAsync.isLoading);
  }

  Widget _buildScaffold(BuildContext context, bool isLoading) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    return Scaffold(
      backgroundColor:
          context.scaffoldBgOf(Theme.of(context).scaffoldBackgroundColor),
      appBar: AppBar(
        title: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            t.settings.intermediate.categories.suggestReply.title,
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
      body: PopScope(
        canPop: !_isPromptDirty(),
        onPopInvokedWithResult: (didPop, _) async {
          if (didPop) return;
          final shouldPop = await _confirmDiscard();
          if (!mounted) return;
          if (shouldPop) Navigator.pop(this.context);
        },
        child: LmMeasure(
          child: ListView(
            padding: const EdgeInsets.all(IntermediateSpacing.sLg),
            children: [
              _buildDescCard(colors, t),
              const SizedBox(height: IntermediateSpacing.sXl),
              _buildModelSection(colors, t, isLoading),
              const SizedBox(height: IntermediateSpacing.sXl),
              _buildPromptSection(colors, t, isLoading),
              const SizedBox(height: IntermediateSpacing.sXl),
              _buildGenerationSection(colors, t, isLoading),
              SizedBox(
                height: MediaQuery.of(context).padding.bottom +
                    IntermediateSpacing.sLg,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDescCard(LmPalette colors, Translations t) {
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
          Icon(Icons.lightbulb_outline, size: 18, color: colors.accent),
          const SizedBox(width: IntermediateSpacing.sSm),
          Expanded(
            child: Text(
              t.settings.intermediate.suggestReply.desc,
              style: IntermediateTextStyles.caption
                  .copyWith(color: colors.muted, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }

  // ── 模型区块 ──────────────────────────────────────────────────────

  Widget _buildModelSection(
    LmPalette colors,
    Translations t,
    bool isLoading,
  ) {
    final config = ref.watch(intermediateConfigProvider).valueOrNull;
    final currentPresetId = config?.suggestReply.presetId ?? '';
    final currentModelId = config?.suggestReply.modelId ?? '';
    final selectedPreset =
        _presets.where((p) => p.presetId == currentPresetId).firstOrNull;
    final presetExists = currentPresetId.isEmpty || selectedPreset != null;
    if (!presetExists && !_staleCleared && !_isLoadingPresets) {
      _staleCleared = true;
      _clearStaleModelConfig();
    }
    final selectedModel = selectedPreset?.cachedModels
        .where((m) => m.modelId == currentModelId)
        .firstOrNull;

    final String subtitle;
    if (presetExists &&
        currentPresetId.isNotEmpty &&
        selectedPreset != null &&
        selectedModel != null) {
      final modelDesc = selectedModel.displayName ?? selectedModel.modelId;
      subtitle = '${selectedPreset.name} · $modelDesc';
    } else {
      subtitle = t.settings.intermediate.suggestReply.notConfigured;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          t.settings.intermediate.suggestReply.modelSection,
          style: IntermediateTextStyles.title.copyWith(color: colors.ink),
        ),
        const SizedBox(height: IntermediateSpacing.s2xs),
        Text(
          t.settings.intermediate.suggestReply.modelDesc,
          style: IntermediateTextStyles.caption.copyWith(color: colors.muted),
        ),
        const SizedBox(height: IntermediateSpacing.sMd),
        Container(
          padding: const EdgeInsets.all(IntermediateSpacing.sLg),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius:
                BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
          ),
          child: _isLoadingPresets
              ? _loadingHint(colors, t)
              : context.lmUi.settingCard(
                  context,
                  narrative: true,
                  icon: Icons.smart_toy_outlined,
                  title: t.settings.intermediate.suggestReply.modelSection,
                  subtitle: subtitle,
                  onTap: () => _showModelPicker(t),
                ),
        ),
      ],
    );
  }

  void _showModelPicker(Translations t) {
    final config = ref.read(intermediateConfigProvider).valueOrNull;
    final currentPresetId = config?.suggestReply.presetId ?? '';
    final currentModelId = config?.suggestReply.modelId ?? '';

    showLmSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => IntermediateModelPickerSheet(
        selectedPresetId: currentPresetId.isEmpty ? null : currentPresetId,
        selectedModelId: currentModelId.isEmpty ? null : currentModelId,
        title: t.settings.intermediate.suggestReply.modelSection,
        successMessage: t.settings.intermediate.suggestReply.modelSaved,
        clearLabel: t.settings.intermediate.suggestReply.notConfigured,
        clearSuccessMessage: t.settings.intermediate.suggestReply.modelCleared,
        onModelSelected: _persistModel,
      ),
    );
  }

  // ── 提示词区块 ────────────────────────────────────────────────────

  Widget _buildPromptSection(
    LmPalette colors,
    Translations t,
    bool isLoading,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          t.settings.intermediate.suggestReply.promptSection,
          style: IntermediateTextStyles.title.copyWith(color: colors.ink),
        ),
        const SizedBox(height: IntermediateSpacing.s2xs),
        Text(
          t.settings.intermediate.suggestReply.promptDesc,
          style: IntermediateTextStyles.caption.copyWith(color: colors.muted),
        ),
        const SizedBox(height: IntermediateSpacing.sMd),
        Container(
          padding: const EdgeInsets.all(IntermediateSpacing.sLg),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius:
                BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
          ),
          child: _buildPromptEditor(colors, t),
        ),
      ],
    );
  }

  Widget _buildPromptEditor(LmPalette colors, Translations t) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _promptController,
          maxLines: 8,
          minLines: 3,
          style: IntermediateTextStyles.bodyUi.copyWith(color: colors.ink),
          decoration: InputDecoration(
            filled: true,
            fillColor: colors.surfaceVariant,
            border: OutlineInputBorder(
              borderRadius:
                  BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
              borderSide: BorderSide.none,
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: IntermediateSpacing.sMd,
              vertical: IntermediateSpacing.sSm,
            ),
            hintText: t.settings.intermediate.suggestReply.promptHint,
            hintStyle:
                IntermediateTextStyles.bodyUi.copyWith(color: colors.faint),
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: IntermediateSpacing.sSm),
        // 操作按钮右对齐，提示文案单独一行放上方，避免长文案挤掉按钮。
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (_isPromptDirty())
              TextButton(
                onPressed: _isSavingPrompt ? null : _savePrompt,
                child: Text(
                  t.settings.intermediate.save,
                  style: IntermediateTextStyles.label
                      .copyWith(color: colors.primary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            TextButton(
              onPressed: _resetPrompt,
              child: Text(
                t.settings.intermediate.suggestReply.restoreDefault,
                style:
                    IntermediateTextStyles.label.copyWith(color: colors.faint),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ── 生成参数区块 ──────────────────────────────────────────────────

  Widget _buildGenerationSection(
    LmPalette colors,
    Translations t,
    bool isLoading,
  ) {
    final config = ref.watch(intermediateConfigProvider).valueOrNull;
    final suggest = config?.suggestReply;
    final temperature = suggest?.temperature ?? 0.8;
    final maxTokens = suggest?.maxTokens ?? 600;
    final candidateCount = suggest?.candidateCount ?? 3;
    final maxReplyLength = suggest?.maxReplyLength ?? 150;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          t.settings.intermediate.suggestReply.generationSection,
          style: IntermediateTextStyles.title.copyWith(color: colors.ink),
        ),
        const SizedBox(height: IntermediateSpacing.sMd),
        Container(
          padding: const EdgeInsets.all(IntermediateSpacing.sLg),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius:
                BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _DeferredSliderTile(
                colors: colors,
                label: t.settings.intermediate.suggestReply.temperature,
                value: temperature,
                min: 0,
                max: 2,
                divisions: 200,
                hint: t.settings.intermediate.suggestReply.temperatureHint,
                onChanged: (v) => _persistNum(
                  'intermediate.suggest_reply.temperature',
                  v,
                ),
              ),
              const SizedBox(height: IntermediateSpacing.sMd),
              Divider(height: 1, color: colors.divider),
              const SizedBox(height: IntermediateSpacing.sMd),
              _DeferredSliderTile(
                colors: colors,
                label: t.settings.intermediate.suggestReply.maxTokens,
                value: maxTokens.toDouble(),
                min: 100,
                max: 2000,
                divisions: 19,
                hint: t.settings.intermediate.suggestReply.maxTokensHint(
                  count: candidateCount,
                ),
                displayAsInt: true,
                onChanged: (v) => _persistInt(
                  'intermediate.suggest_reply.max_tokens',
                  v.round(),
                ),
              ),
              const SizedBox(height: IntermediateSpacing.sMd),
              Divider(height: 1, color: colors.divider),
              const SizedBox(height: IntermediateSpacing.sMd),
              _DeferredSliderTile(
                colors: colors,
                label: t.settings.intermediate.suggestReply.candidateCount,
                value: candidateCount.toDouble(),
                min: 1,
                max: 5,
                divisions: 4,
                hint: t.settings.intermediate.suggestReply.candidateCountHint,
                displayAsInt: true,
                onChanged: (v) => _persistInt(
                  'intermediate.suggest_reply.candidate_count',
                  v.round(),
                ),
              ),
              const SizedBox(height: IntermediateSpacing.sMd),
              Divider(height: 1, color: colors.divider),
              const SizedBox(height: IntermediateSpacing.sMd),
              _DeferredSliderTile(
                colors: colors,
                label: t.settings.intermediate.suggestReply.maxReplyLength,
                value: maxReplyLength.toDouble(),
                min: 20,
                max: 500,
                divisions: 48,
                hint: t.settings.intermediate.suggestReply.maxReplyLengthHint,
                displayAsInt: true,
                onChanged: (v) => _persistInt(
                  'intermediate.suggest_reply.max_reply_length',
                  v.round(),
                ),
              ),
            ],
          ),
        ),
      ],
    );
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

  Future<bool> _confirmDiscard() async {
    if (!_isPromptDirty()) return true;
    final t = Translations.of(context);
    final confirmed = await showLmDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          t.settings.intermediate.confirmDiscardTitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        content: Text(
          t.settings.intermediate.confirmDiscardContent,
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              t.settings.intermediate.keepEditing,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              t.settings.intermediate.discard,
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

/// Keeps drag feedback local and commits the setting once when the thumb is
/// released. This avoids a database write, provider invalidation and full page
/// rebuild for every intermediate tick.
class _DeferredSliderTile extends StatelessWidget {
  const _DeferredSliderTile({
    required this.colors,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.hint,
    required this.onChanged,
    this.displayAsInt = false,
  });

  final LmPalette colors;
  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String hint;
  final ValueChanged<double> onChanged;
  final bool displayAsInt;

  String _format(double value) =>
      displayAsInt ? value.round().toString() : value.toStringAsFixed(2);

  @override
  Widget build(BuildContext context) {
    final displayValue = value.clamp(min, max);

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
            const SizedBox(width: IntermediateSpacing.sSm),
            // 可点按编辑改可视（图标+Tooltip+按钮语义）。
            EditableValueText(
              value: _format(displayValue),
              label: label,
              textStyle:
                  IntermediateTextStyles.caption.copyWith(color: colors.ink),
              iconColor: colors.faint,
              onTap: () => showNumericInputDialog(
                context: context,
                title: label,
                currentValue: displayValue,
                min: min,
                max: max,
                decimals: displayAsInt ? 0 : 2,
                onConfirmed: onChanged,
              ),
            ),
          ],
        ),
        const SizedBox(height: IntermediateSpacing.sXs),
        CommitSlider(
          value: displayValue,
          min: min,
          max: max,
          divisions: divisions,
          activeColor: colors.primary,
          inactiveColor: colors.primaryDim,
          labelBuilder: _format,
          onCommit: onChanged,
        ),
        Text(
          hint,
          style: IntermediateTextStyles.caption.copyWith(color: colors.faint),
        ),
      ],
    );
  }
}
