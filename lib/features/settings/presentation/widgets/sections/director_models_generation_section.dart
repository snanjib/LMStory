import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/config/config_level.dart';
import 'package:lmstory/core/config/config_visibility.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_spacing.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/widgets/numeric_input_dialog.dart';
import 'package:lmstory/features/advanced/domain/entities/narrative_pacing.dart';
import 'package:lmstory/features/intermediate/presentation/widgets/collapsible_settings_section.dart';
import 'package:lmstory/features/settings/presentation/controllers/settings_controller.dart';
import 'package:lmstory/features/settings/presentation/widgets/intermediate_model_picker_sheet.dart';
import 'package:lmstory/features/settings/presentation/widgets/sections/director_setting_rows.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 导演设置 — 模型与生成分区（常驻置顶，导演设置）。
///
/// 内容：GM 默认模型（写 `advanced.phase_models.generating_*`，可清除=未配置）
/// + 生成参数默认（`advanced.generation.*`：温度/Top P/上限/双惩罚/思考档）
/// + 组尾推荐回复轻量组（`advanced.suggest_reply.*`：模型/提示词/温度/上限）。
/// 即时持久化；新值经 resolveAdvancedSettings 成为新会话的快照源。
///
/// 行级按配置显示模式过滤（思考档行级保留）：简单模式保留
/// GM 模型、剧情节奏与思考档行，采样参数行与推荐回复组尾进阶模式渲染。
/// 过滤只动展示层，被隐藏行已有用户值继续生效。
class DirectorModelsGenerationSection extends ConsumerWidget {
  const DirectorModelsGenerationSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(advancedConfigProvider).valueOrNull;
    final colors = context.lm.palette;
    final t = Translations.of(context);
    final level = ref.watch(configLevelProvider);

    final generation = config?.generation;
    final suggest = config?.suggestReply;

    final rows = <Widget>[
      // ── GM 默认模型 ──────────────────────────────────────────
      if (ConfigVisibility.of(ConfigVisibilityKeys.directorGmModel, level))
        SettingsTile(
          child: _GmModelTile(
            presetId: config?.generatingPresetId ?? '',
            modelId: config?.generatingModelId ?? '',
          ),
        ),

      // ── 生成参数默认 ─────────────────────────────────────────
      if (ConfigVisibility.of(
        ConfigVisibilityKeys.directorGenerationTemperature,
        level,
      ))
        DirectorSliderRow(
          label: t.settings.director.generation.temperature,
          value: generation?.temperature ?? 0.8,
          min: 0,
          max: 2,
          // 对齐导演会话面板粒度（0.01）——
          // 此前 0.05 步长全局设不出的值会话能设，重置对齐后回显步进对不上
          divisions: 200,
          onChanged: (v) =>
              writeDirectorOverride(ref, 'advanced.generation.temperature', v),
        ),
      if (ConfigVisibility.of(
        ConfigVisibilityKeys.directorGenerationTopP,
        level,
      ))
        DirectorSliderRow(
          label: t.settings.director.generation.topP,
          value: generation?.topP ?? 0.95,
          min: 0,
          max: 1,
          // 同温度（0.01）
          divisions: 100,
          onChanged: (v) =>
              writeDirectorOverride(ref, 'advanced.generation.top_p', v),
        ),
      if (ConfigVisibility.of(
        ConfigVisibilityKeys.directorGenerationMaxTokens,
        level,
      ))
        SettingsTile(
          child: _MaxTokensTile(
            value: generation?.maxTokens ?? 8192,
          ),
        ),
      if (ConfigVisibility.of(
        ConfigVisibilityKeys.directorGenerationPresencePenalty,
        level,
      ))
        DirectorSliderRow(
          label: t.settings.director.generation.presencePenalty,
          value: generation?.presencePenalty ?? 0.6,
          min: -2,
          max: 2,
          // 对齐导演会话面板粒度（0.02，会话面板 ±2÷100）
          divisions: 200,
          onChanged: (v) => writeDirectorOverride(
            ref,
            'advanced.generation.presence_penalty',
            v,
          ),
        ),
      if (ConfigVisibility.of(
        ConfigVisibilityKeys.directorGenerationFrequencyPenalty,
        level,
      ))
        DirectorSliderRow(
          label: t.settings.director.generation.frequencyPenalty,
          value: generation?.frequencyPenalty ?? 0.3,
          min: -2,
          max: 2,
          // 同存在惩罚（0.02）
          divisions: 200,
          onChanged: (v) => writeDirectorOverride(
            ref,
            'advanced.generation.frequency_penalty',
            v,
          ),
        ),
      // 思考档行（行级保留，行打标仍 advanced 同 C-102 先例）
      if (ConfigVisibility.of(
        ConfigVisibilityKeys.directorGenerationReasoningEffort,
        level,
      ))
        SettingsTile(
          child: _ReasoningEffortTile(
            value: generation?.reasoningEffort,
          ),
        ),
      if (ConfigVisibility.of(ConfigVisibilityKeys.directorPacing, level))
        SettingsTile(
          child: _PacingTile(value: config?.narrativePacing),
        ),

      // ── 组尾：推荐回复轻量组（C-83/C-84 整组进阶）──────────
      if (ConfigVisibility.of(
        ConfigVisibilityKeys.directorSuggestReply,
        level,
      )) ...[
        Text(
          t.settings.director.suggestReply.title,
          style: IntermediateTextStyles.label.copyWith(color: colors.primary),
        ),
        const SizedBox(height: IntermediateSpacing.sXs),
        SettingsTile(
          child: _SuggestModelTile(
            presetId: suggest?.presetId ?? '',
            modelId: suggest?.modelId ?? '',
          ),
        ),
        SettingsTile(
          child: _SuggestPromptTile(prompt: suggest?.prompt ?? ''),
        ),
        DirectorSliderRow(
          label: t.settings.director.suggestReply.temperature,
          value: suggest?.temperature ?? 0.8,
          min: 0,
          max: 2,
          divisions: 40,
          onChanged: (v) => writeDirectorOverride(
            ref,
            'advanced.suggest_reply.temperature',
            v,
          ),
        ),
        SettingsTile(
          child: _SuggestMaxTokensTile(value: suggest?.maxTokens ?? 600),
        ),
        // ── ：候选数量/单条字数入口 ─────────
        DirectorStepperRow(
          label: t.settings.director.suggestReply.candidateCount,
          value: suggest?.candidateCount ?? 3,
          min: 1,
          max: 5,
          onChanged: (v) => writeDirectorOverride(
            ref,
            'advanced.suggest_reply.candidate_count',
            v,
          ),
          hint: t.settings.director.suggestReply.candidateCountHint,
        ),
        DirectorStepperRow(
          label: t.settings.director.suggestReply.maxReplyLength,
          value: suggest?.maxReplyLength ?? 150,
          min: 20,
          max: 500,
          onChanged: (v) => writeDirectorOverride(
            ref,
            'advanced.suggest_reply.max_reply_length',
            v,
          ),
          hint: t.settings.director.suggestReply.maxReplyLengthHint,
        ),
      ],
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) directorSectionGap,
          rows[i],
        ],
      ],
    );
  }
}

/// GM 默认模型瓦片（点击弹选择器；清除 = 未配置）。
class _GmModelTile extends ConsumerWidget {
  const _GmModelTile({required this.presetId, required this.modelId});

  final String presetId;
  final String modelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    final configured = presetId.isNotEmpty && modelId.isNotEmpty;
    // 显示名优先（同名模型/网关别名场景可辨），带供应商归属——与对话
    // 模式默认模型瓦片「preset.name · displayName」口径一致
    final presets = ref.watch(
      settingsNotifierProvider.select((s) => s.presets),
    );
    final preset = presets.where((p) => p.presetId == presetId).firstOrNull;
    final model =
        preset?.cachedModels.where((m) => m.modelId == modelId).firstOrNull;
    final display = preset == null
        ? modelId
        : '${preset.name} · ${model?.displayName ?? modelId}';

    return InkWell(
      onTap: () => _openPicker(context, ref),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  t.settings.director.models.gm,
                  style: IntermediateTextStyles.caption
                      .copyWith(color: colors.muted),
                ),
              ),
              Icon(Icons.chevron_right, size: 18, color: colors.muted),
            ],
          ),
          const SizedBox(height: IntermediateSpacing.s2xs),
          Text(
            configured ? display : t.settings.director.models.gmEmpty,
            style: IntermediateTextStyles.bodyUi.copyWith(
              color: configured ? colors.ink : colors.faint,
              fontWeight: FontWeight.w600,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            t.settings.director.models.gmDesc,
            style: IntermediateTextStyles.captionSm.copyWith(
              color: colors.faint,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          // 模型槽位消费者清单（换模型前看「影响」）
          Text(
            t.settings.intermediate.phaseModels.consumers(
              items: t.settings.director.models.gmConsumers,
            ),
            style: IntermediateTextStyles.captionSm.copyWith(
              color: colors.faint,
            ),
            maxLines: 2,
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
      builder: (_) => IntermediateModelPickerSheet(
        selectedPresetId: (presetId.isEmpty) ? null : presetId,
        selectedModelId: (modelId.isEmpty) ? null : modelId,
        title: t.settings.director.models.gm,
        clearLabel: t.settings.director.models.clear,
        clearSuccessMessage: t.settings.director.models.cleared,
        onModelSelected: (p, m) async {
          final key = p == null || m == null;
          await writeDirectorOverride(
            ref,
            'advanced.phase_models.generating_preset_id',
            key ? null : p,
          );
          await writeDirectorOverride(
            ref,
            'advanced.phase_models.generating_model_id',
            key ? null : m,
          );
        },
      ),
    );
  }
}

/// 单次生成上限瓦片（点按数值弹输入框；写 advanced.generation.max_tokens）。
class _MaxTokensTile extends ConsumerWidget {
  const _MaxTokensTile({required this.value});

  final int value;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                t.settings.director.generation.maxTokens,
                style: IntermediateTextStyles.caption
                    .copyWith(color: colors.muted),
              ),
              Text(
                t.settings.director.generation.maxTokensHint,
                style: IntermediateTextStyles.captionSm.copyWith(
                  color: colors.faint,
                ),
              ),
            ],
          ),
        ),
        GestureDetector(
          onTap: () => showNumericInputDialogForInt(
            context: context,
            title: t.settings.director.generation.maxTokens,
            currentValue: value,
            min: 0,
            max: 1000000,
            onConfirmed: (v) => writeDirectorOverride(
              ref,
              'advanced.generation.max_tokens',
              v,
            ),
          ),
          child: Text(
            value.toString(),
            style: IntermediateTextStyles.bodyUi.copyWith(
              color: colors.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

/// 思考档位瓦片（无/低/中/高；写 advanced.generation.reasoning_effort）。
///
/// 内部以哨兵键区分「未配置」（null，跟随模型默认）与「禁用」——
/// 两者文案同为「无」但语义不同。
class _ReasoningEffortTile extends ConsumerWidget {
  const _ReasoningEffortTile({required this.value});

  final String? value;

  static const _kNotSet = '__notSet__';
  static const _kDisabled = 'disabled';

  String get _dropdownKey {
    // 停用「禁用归一到未配置」——
    // 原注释「未配置与禁用表现一致（不发送参数）」不成立：wire 层
    // ThinkingParamBuilder 对官方端点会为 disabled 发显式关闭参数。
    // 三模式对齐：chat 全局与导演会话级均有禁用档。
    if (value == null) return _kNotSet;
    return value!;
  }

  String? _toOverride(String? key) =>
      key == _kNotSet || key == null ? null : key;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    final g = t.settings.director.generation;

    return Row(
      children: [
        Expanded(
          child: Text(
            g.reasoningEffort,
            style: IntermediateTextStyles.caption.copyWith(color: colors.muted),
          ),
        ),
        DropdownButton<String>(
          value: _dropdownKey,
          underline: const SizedBox.shrink(),
          isDense: true,
          items: [
            DropdownMenuItem(
              value: _kNotSet,
              child: _dropdownText(context, g.reasoningNone),
            ),
            DropdownMenuItem(
              value: _kDisabled,
              child: _dropdownText(context, g.reasoningDisabled),
            ),
            DropdownMenuItem(
              value: 'low',
              child: _dropdownText(context, g.reasoningLow),
            ),
            DropdownMenuItem(
              value: 'medium',
              child: _dropdownText(context, g.reasoningMedium),
            ),
            DropdownMenuItem(
              value: 'high',
              child: _dropdownText(context, g.reasoningHigh),
            ),
          ],
          onChanged: (v) => writeDirectorOverride(
            ref,
            'advanced.generation.reasoning_effort',
            _toOverride(v),
          ),
        ),
      ],
    );
  }

  Widget _dropdownText(BuildContext context, String text) {
    final colors = context.lm.palette;
    return Text(
      text,
      style: IntermediateTextStyles.bodyUi.copyWith(color: colors.ink),
    );
  }
}

/// 剧情节奏瓦片（三档；写 advanced.narrative_pacing，剧情节奏档位设计 §5.7）。
class _PacingTile extends ConsumerWidget {
  const _PacingTile({required this.value});

  final String? value;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    final p = t.settings.director.pacing;
    final current =
        NarrativePacing.tryFromConfigValue(value) ?? NarrativePacing.balanced;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          p.title,
          style: IntermediateTextStyles.caption.copyWith(color: colors.muted),
        ),
        const SizedBox(height: IntermediateSpacing.s2xs),
        Text(
          p.desc,
          style: IntermediateTextStyles.captionSm.copyWith(
            color: colors.faint,
          ),
        ),
        const SizedBox(height: IntermediateSpacing.sXs),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<String>(
            segments: [
              for (final tier in NarrativePacing.values)
                ButtonSegment(
                  value: tier.configValue,
                  label: Text(
                    switch (tier) {
                      NarrativePacing.conservative => p.conservative,
                      NarrativePacing.balanced => p.balanced,
                      NarrativePacing.aggressive => p.aggressive,
                    },
                    style: TextStyle(
                      fontSize: 12,
                      color: current == tier ? colors.bg : colors.muted,
                    ),
                  ),
                ),
            ],
            selected: {current.configValue},
            showSelectedIcon: false,
            style: ButtonStyle(
              visualDensity: VisualDensity.compact,
              side: WidgetStatePropertyAll(
                BorderSide(color: colors.divider),
              ),
              backgroundColor: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.selected)
                    ? colors.primary
                    : null,
              ),
              foregroundColor: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.selected)
                    ? colors.bg
                    : colors.ink,
              ),
              shape: WidgetStatePropertyAll(
                RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(
                    context.lmUi.radius(LmCorner.xs),
                  ),
                ),
              ),
            ),
            onSelectionChanged: (selection) => writeDirectorOverride(
              ref,
              'advanced.narrative_pacing',
              selection.first,
            ),
          ),
        ),
        const SizedBox(height: IntermediateSpacing.s2xs),
        Text(
          switch (current) {
            NarrativePacing.conservative => p.conservativeDesc,
            NarrativePacing.balanced => p.balancedDesc,
            NarrativePacing.aggressive => p.aggressiveDesc,
          },
          style: IntermediateTextStyles.captionSm.copyWith(
            color: colors.faint,
          ),
        ),
      ],
    );
  }
}

/// 推荐回复模型瓦片（留空跟随 GM）。
class _SuggestModelTile extends ConsumerWidget {
  const _SuggestModelTile({required this.presetId, required this.modelId});

  final String presetId;
  final String modelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    final configured = presetId.isNotEmpty && modelId.isNotEmpty;
    // 显示名优先（同名模型/网关别名场景可辨），带供应商归属——与对话
    // 模式默认模型瓦片「preset.name · displayName」口径一致
    final presets = ref.watch(
      settingsNotifierProvider.select((s) => s.presets),
    );
    final preset = presets.where((p) => p.presetId == presetId).firstOrNull;
    final model =
        preset?.cachedModels.where((m) => m.modelId == modelId).firstOrNull;
    final display = preset == null
        ? modelId
        : '${preset.name} · ${model?.displayName ?? modelId}';

    return InkWell(
      onTap: () => _openPicker(context, ref),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  t.settings.director.suggestReply.model,
                  style: IntermediateTextStyles.caption
                      .copyWith(color: colors.muted),
                ),
              ),
              Icon(Icons.chevron_right, size: 18, color: colors.muted),
            ],
          ),
          const SizedBox(height: IntermediateSpacing.s2xs),
          Text(
            configured ? display : t.settings.director.suggestReply.modelDesc,
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
      builder: (_) => IntermediateModelPickerSheet(
        selectedPresetId: presetId.isEmpty ? null : presetId,
        selectedModelId: modelId.isEmpty ? null : modelId,
        title: t.settings.director.suggestReply.model,
        clearLabel: t.settings.director.models.clear,
        onModelSelected: (p, m) async {
          final clear = p == null || m == null;
          await writeDirectorOverride(
            ref,
            'advanced.suggest_reply.preset_id',
            clear ? null : p,
          );
          await writeDirectorOverride(
            ref,
            'advanced.suggest_reply.model_id',
            clear ? null : m,
          );
        },
      ),
    );
  }
}

/// 推荐回复提示词瓦片（失焦/提交保存）。
class _SuggestPromptTile extends ConsumerStatefulWidget {
  const _SuggestPromptTile({required this.prompt});

  final String prompt;

  @override
  ConsumerState<_SuggestPromptTile> createState() => _SuggestPromptTileState();
}

class _SuggestPromptTileState extends ConsumerState<_SuggestPromptTile> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.prompt);
  }

  @override
  void didUpdateWidget(covariant _SuggestPromptTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 外部值变化（如清除覆写）同步到输入框（光标不在编辑态时）
    if (widget.prompt != oldWidget.prompt &&
        _controller.text != widget.prompt) {
      _controller.text = widget.prompt;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          t.settings.director.suggestReply.prompt,
          style: IntermediateTextStyles.caption.copyWith(color: colors.muted),
        ),
        const SizedBox(height: IntermediateSpacing.sXs),
        TextField(
          controller: _controller,
          minLines: 2,
          maxLines: 4,
          style: IntermediateTextStyles.bodyUi.copyWith(color: colors.ink),
          decoration: InputDecoration(
            hintText: t.settings.director.suggestReply.promptHint,
            hintStyle:
                IntermediateTextStyles.caption.copyWith(color: colors.faint),
            isDense: true,
            border: OutlineInputBorder(
              borderRadius:
                  BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
              borderSide: BorderSide(color: colors.divider),
            ),
          ),
          onSubmitted: _save,
          onTapOutside: (_) => _save(_controller.text),
        ),
      ],
    );
  }

  void _save(String text) {
    final trimmed = text.trim();
    writeDirectorOverride(
      ref,
      'advanced.suggest_reply.prompt',
      trimmed.isEmpty ? null : trimmed,
    );
  }
}

/// 推荐回复生成上限瓦片。
class _SuggestMaxTokensTile extends ConsumerWidget {
  const _SuggestMaxTokensTile({required this.value});

  final int value;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    return Row(
      children: [
        Expanded(
          child: Text(
            t.settings.director.suggestReply.maxTokens,
            style: IntermediateTextStyles.caption.copyWith(color: colors.muted),
          ),
        ),
        GestureDetector(
          onTap: () => showNumericInputDialogForInt(
            context: context,
            title: t.settings.director.suggestReply.maxTokens,
            currentValue: value,
            min: 100,
            max: 100000,
            onConfirmed: (v) => writeDirectorOverride(
              ref,
              'advanced.suggest_reply.max_tokens',
              v,
            ),
          ),
          child: Text(
            value.toString(),
            style: IntermediateTextStyles.bodyUi.copyWith(
              color: colors.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

/// 整数输入弹窗薄封装（showNumericInputDialog 的 round 适配）。
Future<void> showNumericInputDialogForInt({
  required BuildContext context,
  required String title,
  required int currentValue,
  required int min,
  required int max,
  required ValueChanged<int> onConfirmed,
}) {
  return showNumericInputDialog(
    context: context,
    title: title,
    currentValue: currentValue.toDouble(),
    min: min.toDouble(),
    max: max.toDouble(),
    decimals: 0,
    onConfirmed: (v) => onConfirmed(v.round()),
  );
}
