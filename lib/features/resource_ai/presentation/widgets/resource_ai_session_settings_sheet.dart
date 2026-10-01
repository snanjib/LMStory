/// resource_ai 会话设置面板 + 完成创建确认流。
///
/// 面板（全高 modal bottom sheet）：模型（嵌套 DefaultModelPickerSheet）、
/// 生成参数（温度/单轮步数，释放时提交）、实时草稿预览、完成创建入口。
/// 面板监听 controller：agent 轮内改稿即时反映到预览。
///
/// 完成流：确认对话框（另存/覆盖）→ controller.save → 失败弹 snackbar
/// 返回 false；成功返回 true（saved 终态由页面的 saved 监听自动退出）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/resource_ai/domain/entities/draft_entities.dart';
import 'package:lmstory/features/resource_ai/presentation/controllers/resource_ai_controller.dart';
import 'package:lmstory/features/resource_ai/presentation/widgets/draft_preview_content.dart';
import 'package:lmstory/features/settings/presentation/controllers/settings_controller.dart';
import 'package:lmstory/features/settings/presentation/widgets/default_model_picker_sheet.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 会话设置面板入口（全高 modal bottom sheet）。
Future<void> showResourceAiSessionSettingsSheet(
  BuildContext context, {
  required ResourceAiController controller,
}) {
  return showLmSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => ResourceAiSessionSettingsSheet(controller: controller),
  );
}

/// 完成创建确认流：返回 true=已保存（saved 终态，页面自行退出）。
///
/// 失败时自行弹 snackbar(saveFailed) 并返回 false；取消返回 false。
Future<bool> showResourceAiFinishFlow(
  BuildContext context, {
  required ResourceAiController controller,
}) async {
  final t = Translations.of(context);
  final draft = controller.state.draft;
  final isCard = controller.kind == DraftKind.characterCard;
  final rawName = isCard ? draft?.card?.name : draft?.book?.name;
  final draftName = (rawName ?? '').isNotEmpty
      ? rawName!
      : (isCard ? t.resourceAi.unnamedCard : t.resourceAi.unnamedBook);
  final isEditing =
      controller.targetCardId != null || controller.targetBookId != null;

  final choice = await showLmDialog<_FinishChoice>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => AlertDialog(
      title: Text(t.resourceAi.finishCreate),
      content: Text(
        isEditing
            ? t.resourceAi.finishEditBody
            : t.resourceAi.finishCreateBody(name: draftName),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: Text(t.common.cancel),
        ),
        if (isEditing) ...[
          TextButton(
            onPressed: () =>
                Navigator.pop(dialogContext, _FinishChoice.saveNew),
            child: Text(t.resourceAi.finishSaveAsNew),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, _FinishChoice.overwrite),
            child: Text(t.resourceAi.finishUpdate),
          ),
        ] else
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, _FinishChoice.saveNew),
            child: Text(t.resourceAi.finishConfirm),
          ),
      ],
    ),
  );
  if (choice == null) return false;

  final error =
      await controller.save(overwrite: choice == _FinishChoice.overwrite);
  if (error != null) {
    if (!context.mounted) return false;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(t.resourceAi.saveFailed(error: error.detail)),
        ),
      );
    return false;
  }
  return true;
}

/// 完成流对话框的选择结果（null=取消）。
enum _FinishChoice { saveNew, overwrite }

class ResourceAiSessionSettingsSheet extends ConsumerStatefulWidget {
  const ResourceAiSessionSettingsSheet({
    required this.controller,
    super.key,
  });

  final ResourceAiController controller;

  @override
  ConsumerState<ResourceAiSessionSettingsSheet> createState() =>
      _ResourceAiSessionSettingsSheetState();
}

class _ResourceAiSessionSettingsSheetState
    extends ConsumerState<ResourceAiSessionSettingsSheet> {
  /// 拖动中的温度（释放提交；null=未拖动，显示状态值）。
  double? _dragTemperature;

  /// 拖动中的步数（释放提交；null=未拖动，显示状态值）。
  int? _dragMaxSteps;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;
    final state = widget.controller.state;

    return Material(
      // 琉璃下面层让位 GlassBottomSheet 工厂；经典保持原槽位零变化。
      color: context.lmSheetFaceColor(colors.surface),
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(context.lmUi.radius(LmCorner.lg)),
      ),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 拖拽把手
            Padding(
              padding: const EdgeInsets.only(top: SimpleSpacing.sSm),
              child: Container(
                width: 32,
                height: 4,
                decoration: BoxDecoration(
                  color: colors.faint.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            // 标题行
            Padding(
              padding: const EdgeInsets.all(SimpleSpacing.sLg),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      t.resourceAi.settingsTitle,
                      style: SimpleTextStyles.title2.copyWith(
                        color: colors.ink,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    //  语义缺口：复用 common.close（不新增 i18n key）。
                    tooltip: t.common.close,
                    icon: Icon(Icons.close, color: colors.muted, size: 20),
                    onPressed: () => Navigator.of(context).pop(),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 44,
                      minHeight: 44,
                    ),
                  ),
                ],
              ),
            ),
            // 内容区（滚动）
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: SimpleSpacing.sLg,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _section(t.resourceAi.sectionModel, _buildModelRow(t)),
                    const SizedBox(height: SimpleSpacing.sLg),
                    _section(
                      t.resourceAi.sectionGeneration,
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildTemperatureRow(t, colors),
                          _buildMaxStepsRow(t, colors),
                        ],
                      ),
                    ),
                    const SizedBox(height: SimpleSpacing.sLg),
                    _section(
                      t.resourceAi.sectionDraft,
                      DraftPreviewContent(draft: state.draft),
                    ),
                    const SizedBox(height: SimpleSpacing.sLg),
                  ],
                ),
              ),
            ),
            _buildBottomBar(t, state),
          ],
        ),
      ),
    );
  }

  /// 区块：title3 标题 + 内容。
  Widget _section(String label, Widget content) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: SimpleSpacing.sXs),
            child: Text(label, style: SimpleTextStyles.title3),
          ),
          content,
        ],
      );

  // ── 模型行 ────────────────────────────────────────────────────────────

  Widget _buildModelRow(Translations t) {
    final colors = context.lm.palette;
    final state = widget.controller.state;
    // watch（而非 read）：嵌套选择器刷新 presets 后行内名称实时更新。
    final presets = ref.watch(
      settingsNotifierProvider.select((s) => s.presets),
    );
    // 生成/落库中换模型会被控制器拒绝（下一轮才可换），先行禁用入口，
    // 避免选择器报「成功」但实际未写入的误导（终审 P2）。
    final busy = state.phase == ResourceAiPhase.generating ||
        state.phase == ResourceAiPhase.saving;

    final presetId = state.modelPresetId;
    final String value;
    if (presetId == null) {
      value = t.resourceAi.modelNotSelected;
    } else {
      final preset = presets.where((p) => p.presetId == presetId).firstOrNull;
      final model = preset?.cachedModels
          .where((m) => m.modelId == state.modelId)
          .firstOrNull;
      // 查不到预设时兜底显示原始 id（快照引用仍可辨识）。
      value =
          '${preset?.name ?? presetId} / ${model?.displayName ?? state.modelId ?? ''}';
    }

    return Material(
      color: colors.surfaceElevated,
      borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: busy ? null : _pickModel,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
        child: Padding(
          padding: const EdgeInsets.all(SimpleSpacing.sMd),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t.resourceAi.modelSelect,
                      style: SimpleTextStyles.body.copyWith(
                        color: colors.ink,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      value,
                      style: SimpleTextStyles.caption
                          .copyWith(color: colors.muted),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, size: 20, color: colors.faint),
            ],
          ),
        ),
      ),
    );
  }

  /// 嵌套弹出模型选择器（选中即持久化 override，下一轮生效）。
  Future<void> _pickModel() async {
    await showLmSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DefaultModelPickerSheet(
        selectedPresetId: widget.controller.state.modelPresetId,
        selectedModelId: widget.controller.state.modelId,
        onModelSelected: (presetId, modelId) async {
          if (presetId != null && modelId != null) {
            await widget.controller.updateModel(
              presetId: presetId,
              modelId: modelId,
            );
          }
        },
      ),
    );
  }

  // ── 生成参数 ──────────────────────────────────────────────────────────

  double get _temperatureValue =>
      _dragTemperature ?? (widget.controller.state.temperature ?? 0.7);

  int get _maxStepsValue => _dragMaxSteps ?? widget.controller.state.maxSteps;

  Widget _buildTemperatureRow(Translations t, LmPalette colors) {
    final value = _temperatureValue.clamp(0.0, 2.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                t.resourceAi.temperatureLabel,
                style: SimpleTextStyles.caption.copyWith(color: colors.muted),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Spacer(),
            Text(
              value.toStringAsFixed(1),
              style: SimpleTextStyles.caption.copyWith(color: colors.ink),
            ),
            IconButton(
              icon: Icon(Icons.refresh, size: 16, color: colors.faint),
              onPressed: () => widget.controller.resetTemperatureToBroadcast(),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              tooltip: t.resourceAi.temperatureReset,
            ),
          ],
        ),
        Slider(
          value: value,
          max: 2,
          divisions: 20,
          activeColor: colors.primary,
          inactiveColor: colors.primaryDim,
          label: value.toStringAsFixed(1),
          // 拖动只更新本地显示值，释放才提交（下一轮生效）。
          onChanged: (v) => setState(() => _dragTemperature = v),
          onChangeEnd: (v) {
            setState(() => _dragTemperature = null);
            widget.controller.updateGenerationParams(temperature: v);
          },
        ),
      ],
    );
  }

  Widget _buildMaxStepsRow(Translations t, LmPalette colors) {
    final value = _maxStepsValue.clamp(2, 12);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                t.resourceAi.maxStepsLabel,
                style: SimpleTextStyles.caption.copyWith(color: colors.muted),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Spacer(),
            Text(
              '$value',
              style: SimpleTextStyles.caption.copyWith(color: colors.ink),
            ),
            IconButton(
              icon: Icon(Icons.refresh, size: 16, color: colors.faint),
              onPressed: () =>
                  widget.controller.updateGenerationParams(maxSteps: 6),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              tooltip: t.resourceAi.maxStepsReset,
            ),
          ],
        ),
        Slider(
          value: value.toDouble(),
          min: 2,
          max: 12,
          divisions: 10,
          activeColor: colors.primary,
          inactiveColor: colors.primaryDim,
          label: '$value',
          onChanged: (v) => setState(() => _dragMaxSteps = v.round()),
          onChangeEnd: (v) {
            setState(() => _dragMaxSteps = null);
            widget.controller.updateGenerationParams(maxSteps: v.round());
          },
        ),
      ],
    );
  }

  // ── 底部完成栏 ────────────────────────────────────────────────────────

  Widget _buildBottomBar(Translations t, ResourceAiState state) {
    final canFinish = state.canSave && state.phase != ResourceAiPhase.saved;
    // RA13-1：编辑会话的按钮文案与确认弹窗
    // （finishUpdate「完成并更新原资源」）对齐——此前入口写「完成创建」、
    // 点开却问「另存/更新」，动宾不接。
    final isEditing = widget.controller.targetCardId != null ||
        widget.controller.targetBookId != null;
    final finishLabel =
        isEditing ? t.resourceAi.finishUpdate : t.resourceAi.finishCreate;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: SimpleSpacing.sLg,
          vertical: SimpleSpacing.s2xs,
        ),
        child: canFinish
            ? SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () async {
                    // 成功（saved）时页面的 saved 监听已同步弹出面板与本页
                    //（popUntil+pop）；此处不得再 pop——本路由已在退出中，
                    // 再 pop 会误弹库页（终审 P1 双弹）。
                    await showResourceAiFinishFlow(
                      context,
                      controller: widget.controller,
                    );
                  },
                  child: Text(finishLabel),
                ),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: null,
                      child: Text(finishLabel),
                    ),
                  ),
                  const SizedBox(height: SimpleSpacing.s2xs),
                  Text(
                    state.phase == ResourceAiPhase.fatal
                        ? t.resourceAi.finishFatalHint
                        : t.resourceAi.finishDisabledHint,
                    style: SimpleTextStyles.caption.copyWith(
                      color: context.lm.palette.muted,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
      ),
    );
  }
}
