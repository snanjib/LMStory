import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/config/config_level.dart';
import 'package:lmstory/core/config/config_visibility.dart';
import 'package:lmstory/core/config/output_token_policy.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_spacing.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/widgets/commit_slider.dart';
import 'package:lmstory/core/widgets/editable_value_text.dart';
import 'package:lmstory/core/widgets/numeric_input_dialog.dart';
import 'package:lmstory/features/chat/domain/entities/reasoning_effort.dart';
import 'package:lmstory/features/settings/presentation/widgets/intermediate_context_budget_section.dart'
    show IntermediateContextBudgetSection;
import 'package:lmstory/features/story_runtime/presentation/widgets/session_settings_fields.dart'
    show IntermediateReasoningEffortSelector, IntermediateSliderField;
import 'package:lmstory/i18n/strings.g.dart';

/// 故事模式设置 — 生成参数全局配置（v0.2.2 阶段 2-B 新增，夜航主题）。
///
/// 控制 `intermediate.generation` 配置项（5 个生成参数 + 思考预算）：
/// - **温度**（temperature，0.0-2.0，默认 0.8）：控制生成随机性
/// - **Top P**（top_p，0.0-1.0，默认 0.95）：核采样阈值
/// - **最大 Token 数**（max_tokens，默认 8192）：0 表示不设置应用层输出上限
/// - **存在惩罚**（presence_penalty，-2.0~2.0，默认 0.6）：鼓励新话题
/// - **频率惩罚**（frequency_penalty，-2.0~2.0，默认 0.3）：减少重复用词
/// - **思考预算**（reasoning_effort，v0.2.2 新增）：4 档 + 未配置
///
/// 持久化：SettingsRepository.user_overrides
/// - `intermediate.generation.temperature`
/// - `intermediate.generation.top_p`
/// - `intermediate.generation.max_tokens`
/// - `intermediate.generation.presence_penalty`
/// - `intermediate.generation.frequency_penalty`
/// - `intermediate.generation.reasoning_effort`（null 时 removeUserOverride）
///
/// 交互模式：即时持久化（slider 变更即保存），与 [IntermediateContextBudgetSection]
/// 一致——因为数值变更无需 dirty state。
///
/// **快照语义**：本区块配置的是新会话物化时的"快照源"——会话级字段在物化时
/// 读取当前全局值并写入 `chat_sessions` 对应字段。修改全局参数不会影响
/// 已物化的会话（与"重置为全局"按钮语义一致）。
///
/// **作用范围**：生成参数作用于 generating（生成）与 reviewing（审查）
/// 两个阶段；extracting（关键词提取）/summarizing（事件摘要）
/// 等结构化输出阶段不消费这些参数。
///
/// 行级按配置显示模式过滤（全局页行级混排首例）：区块标题恒显
/// （思考预算属生成参数族），区内 6 行逐行标注——简单模式仅保留
/// 思考预算行，采样参数 5 行进阶模式渲染。过滤只动展示层。
class IntermediateGenerationSection extends ConsumerWidget {
  const IntermediateGenerationSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final configAsync = ref.watch(intermediateConfigProvider);
    final config = configAsync.valueOrNull;
    final colors = context.lm.palette;
    final t = Translations.of(context);
    final level = ref.watch(configLevelProvider);

    final generation = config?.generation;
    final temperature = generation?.temperature ?? 0.8;
    final topP = generation?.topP ?? 0.95;
    final maxTokens =
        generation?.maxTokens ?? OutputTokenPolicy.storyDefaultLimit;
    final presencePenalty = generation?.presencePenalty ?? 0.6;
    final frequencyPenalty = generation?.frequencyPenalty ?? 0.3;
    final reasoningEffortStr = generation?.reasoningEffort;
    final reasoningEffort = reasoningEffortStr != null
        ? ReasoningEffort.fromString(reasoningEffortStr)
        : null;
    final isLoading = configAsync.isLoading;

    final rows = <Widget>[
      if (ConfigVisibility.of(
        ConfigVisibilityKeys.storyGlobalGenerationTemperature,
        level,
      ))
        _SliderRow(
          label: t.settings.intermediate.generation.temperature,
          value: temperature,
          min: 0,
          max: 2,
          divisions: 200,
          hint: t.settings.intermediate.generation.temperatureDesc,
          enabled: !isLoading,
          onChanged: isLoading ? null : (v) => _persist(ref, 'temperature', v),
        ),
      if (ConfigVisibility.of(
        ConfigVisibilityKeys.storyGlobalGenerationTopP,
        level,
      ))
        _SliderRow(
          label: t.settings.intermediate.generation.topP,
          value: topP,
          min: 0,
          max: 1,
          divisions: 100,
          hint: t.settings.intermediate.generation.topPDesc,
          enabled: !isLoading,
          onChanged: isLoading ? null : (v) => _persist(ref, 'top_p', v),
        ),
      if (ConfigVisibility.of(
        ConfigVisibilityKeys.storyGlobalGenerationMaxTokens,
        level,
      ))
        _MaxTokensInput(
          label: t.settings.intermediate.generation.maxTokens,
          value: maxTokens,
          hint: t.settings.intermediate.generation.maxTokensDesc,
          enabled: !isLoading,
          onChanged: isLoading ? null : (v) => _persist(ref, 'max_tokens', v),
        ),
      if (ConfigVisibility.of(
        ConfigVisibilityKeys.storyGlobalGenerationPresencePenalty,
        level,
      ))
        _SliderRow(
          label: t.settings.intermediate.generation.presencePenalty,
          value: presencePenalty,
          min: -2,
          max: 2,
          divisions: 400,
          hint: t.settings.intermediate.generation.presencePenaltyDesc,
          enabled: !isLoading,
          onChanged:
              isLoading ? null : (v) => _persist(ref, 'presence_penalty', v),
        ),
      if (ConfigVisibility.of(
        ConfigVisibilityKeys.storyGlobalGenerationFrequencyPenalty,
        level,
      ))
        _SliderRow(
          label: t.settings.intermediate.generation.frequencyPenalty,
          value: frequencyPenalty,
          min: -2,
          max: 2,
          divisions: 400,
          hint: t.settings.intermediate.generation.frequencyPenaltyDesc,
          enabled: !isLoading,
          onChanged:
              isLoading ? null : (v) => _persist(ref, 'frequency_penalty', v),
        ),
      if (ConfigVisibility.of(
        ConfigVisibilityKeys.storyGlobalGenerationReasoningEffort,
        level,
      ))
        _ReasoningEffortPicker(
          value: reasoningEffort,
          enabled: !isLoading,
          onChanged:
              isLoading ? null : (v) => _onReasoningEffortChanged(ref, v),
        ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          t.settings.intermediate.generation.title,
          style: IntermediateTextStyles.title.copyWith(color: colors.ink),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: IntermediateSpacing.s2xs),
        Text(
          t.settings.intermediate.generation.desc,
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
                for (var i = 0; i < rows.length; i++) ...[
                  if (i > 0) const SizedBox(height: IntermediateSpacing.sMd),
                  rows[i],
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 持久化单个生成参数到 user_overrides。
  ///
  /// key 形如 `intermediate.generation.temperature`，由
  /// SettingsRepository 合并到 default_config.json 的 `intermediate.generation`
  /// 子节点上。写入后 invalidate provider 刷新 UI。
  Future<void> _persist(WidgetRef ref, String field, dynamic value) async {
    final repo = ref.read(settingsRepositoryProvider);
    await repo.setUserOverride('intermediate.generation.$field', value);
    ref.invalidate(intermediateConfigProvider);
  }

  /// 思考预算变更：null 时 removeUserOverride（回到"未配置"），
  /// 非 null 时写入枚举 name 字符串。
  ///
  /// v0.2.2 新增。作用范围：仅 generating/reviewing 阶段消费。
  Future<void> _onReasoningEffortChanged(
    WidgetRef ref,
    ReasoningEffort? value,
  ) async {
    final repo = ref.read(settingsRepositoryProvider);
    if (value == null) {
      await repo.removeUserOverride(
        'intermediate.generation.reasoning_effort',
      );
    } else {
      await repo.setUserOverride(
        'intermediate.generation.reasoning_effort',
        value.toJson(),
      );
    }
    ref.invalidate(intermediateConfigProvider);
  }
}

/// 故事模式全局输出 Token 上限编辑器。
///
/// `0` 表示 LMStory 不设置应用层输出上限；任意正整数均可输入，常见的 2 次幂
/// 数值同时提供快捷选项。
class _MaxTokensInput extends StatefulWidget {
  const _MaxTokensInput({
    required this.label,
    required this.value,
    required this.hint,
    required this.onChanged,
    this.enabled = true,
  });

  final String label;
  final int value;
  final String hint;
  final ValueChanged<int>? onChanged;
  final bool enabled;

  @override
  State<_MaxTokensInput> createState() => _MaxTokensInputState();
}

class _MaxTokensInputState extends State<_MaxTokensInput> {
  static const _presets = [0, 4096, 8192, 16384, 32768, 65536, 131072];

  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value.toString());
  }

  @override
  void didUpdateWidget(covariant _MaxTokensInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != oldWidget.value &&
        _controller.text != widget.value.toString()) {
      _controller.text = widget.value.toString();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _commit() {
    final parsed = int.tryParse(_controller.text);
    if (parsed == null || parsed < 0) {
      _controller.text = widget.value.toString();
      return;
    }
    if (parsed != widget.value) widget.onChanged?.call(parsed);
  }

  void _selectPreset(int value) {
    _controller.text = value.toString();
    if (value != widget.value) widget.onChanged?.call(value);
  }

  String _formatPreset(int value) {
    if (value == 0) return '0';
    return '${value ~/ 1024}K';
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.label,
          style: IntermediateTextStyles.caption.copyWith(color: colors.muted),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: IntermediateSpacing.sXs),
        SizedBox(
          width: 160,
          child: TextField(
            controller: _controller,
            enabled: widget.enabled,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.done,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            style: IntermediateTextStyles.bodyUi.copyWith(color: colors.ink),
            decoration: InputDecoration(
              filled: true,
              fillColor: colors.bg,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: IntermediateSpacing.sMd,
                vertical: IntermediateSpacing.sSm,
              ),
              border: OutlineInputBorder(
                borderRadius:
                    BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
                borderSide: BorderSide(color: colors.divider),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius:
                    BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
                borderSide: BorderSide(color: colors.divider),
              ),
            ),
            onSubmitted: (_) => _commit(),
            onTapOutside: (_) {
              _commit();
              FocusManager.instance.primaryFocus?.unfocus();
            },
          ),
        ),
        const SizedBox(height: IntermediateSpacing.sXs),
        Wrap(
          spacing: IntermediateSpacing.sXs,
          runSpacing: IntermediateSpacing.s2xs,
          children: [
            for (final preset in _presets)
              ChoiceChip(
                label: Text(_formatPreset(preset)),
                selected: widget.value == preset,
                onSelected:
                    widget.enabled ? (_) => _selectPreset(preset) : null,
                visualDensity: VisualDensity.compact,
              ),
          ],
        ),
        const SizedBox(height: IntermediateSpacing.s2xs),
        Text(
          widget.hint,
          style: IntermediateTextStyles.caption.copyWith(
            color: colors.faint,
            fontSize: 11,
          ),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

/// 全局思考预算选择器（5 档：未配置 / 禁用 / 低 / 中 / 高）。
///
/// 与会话级 [IntermediateReasoningEffortSelector] 区别：
/// - 全局级有"未配置"档（null = 跟随模型默认，不发送 reasoning 参数）
/// - 无"重置为全局"按钮（全局本身就是源头）
///
/// 作用范围说明通过 hint 文案传达：仅生成与审查阶段生效。
class _ReasoningEffortPicker extends StatelessWidget {
  const _ReasoningEffortPicker({
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  /// null = 未配置（跟随模型默认）
  final ReasoningEffort? value;
  final ValueChanged<ReasoningEffort?>? onChanged;
  final bool enabled;

  static const _notSetKey = '__not_set__';
  static const _disabledKey = 'disabled';
  static const _lowKey = 'low';
  static const _mediumKey = 'medium';
  static const _highKey = 'high';

  String get _dropdownValue {
    if (value == null) return _notSetKey;
    switch (value!) {
      case ReasoningEffort.disabled:
        return _disabledKey;
      case ReasoningEffort.low:
        return _lowKey;
      case ReasoningEffort.medium:
        return _mediumKey;
      case ReasoningEffort.high:
        return _highKey;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;
    final g = t.settings.intermediate.generation;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                g.reasoningEffort,
                style: IntermediateTextStyles.caption
                    .copyWith(color: colors.muted),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: IntermediateSpacing.sXs),
        DropdownButtonFormField<String>(
          initialValue: _dropdownValue,
          isExpanded: true,
          decoration: InputDecoration(
            filled: true,
            fillColor: colors.bg,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: IntermediateSpacing.sMd,
              vertical: IntermediateSpacing.sSm,
            ),
            border: OutlineInputBorder(
              borderRadius:
                  BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
              borderSide: BorderSide(color: colors.divider),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius:
                  BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
              borderSide: BorderSide(color: colors.divider),
            ),
          ),
          style: IntermediateTextStyles.bodyUi.copyWith(color: colors.ink),
          iconEnabledColor: colors.muted,
          items: [
            DropdownMenuItem(
              value: _notSetKey,
              child: Text(
                g.reasoningEffortNotSet,
                style:
                    IntermediateTextStyles.bodyUi.copyWith(color: colors.faint),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            DropdownMenuItem(
              value: _disabledKey,
              child: Text(
                g.reasoningEffortDisabled,
                style:
                    IntermediateTextStyles.bodyUi.copyWith(color: colors.ink),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            DropdownMenuItem(
              value: _lowKey,
              child: Text(
                g.reasoningEffortLow,
                style:
                    IntermediateTextStyles.bodyUi.copyWith(color: colors.ink),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            DropdownMenuItem(
              value: _mediumKey,
              child: Text(
                g.reasoningEffortMedium,
                style:
                    IntermediateTextStyles.bodyUi.copyWith(color: colors.ink),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            DropdownMenuItem(
              value: _highKey,
              child: Text(
                g.reasoningEffortHigh,
                style:
                    IntermediateTextStyles.bodyUi.copyWith(color: colors.ink),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
          onChanged: enabled && onChanged != null
              ? (v) => onChanged!(_mapFromDropdown(v))
              : null,
        ),
        const SizedBox(height: IntermediateSpacing.s2xs),
        Text(
          g.reasoningEffortDesc,
          style: IntermediateTextStyles.caption.copyWith(
            color: colors.faint,
            fontSize: 11,
          ),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }

  ReasoningEffort? _mapFromDropdown(String? v) {
    switch (v) {
      case _disabledKey:
        return ReasoningEffort.disabled;
      case _lowKey:
        return ReasoningEffort.low;
      case _mediumKey:
        return ReasoningEffort.medium;
      case _highKey:
        return ReasoningEffort.high;
      default:
        return null;
    }
  }
}

/// 全局设置中的滑块行（无重置按钮，区别于会话级 [IntermediateSliderField]）。
///
/// 全局配置本身就是"源头"，没有"重置为全局"概念。用户调整即直接持久化。
class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.hint,
    required this.onChanged,
    this.enabled = true,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String hint;
  final ValueChanged<double>? onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final displayValue = value.clamp(min, max);
    final canEdit = enabled && onChanged != null;

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
            // 可点按编辑改可视（图标+Tooltip+按钮语义）。
            EditableValueText(
              value: displayValue.toStringAsFixed(2),
              label: label,
              enabled: canEdit,
              textStyle:
                  IntermediateTextStyles.caption.copyWith(color: colors.ink),
              iconColor: colors.faint,
              onTap: () => showNumericInputDialog(
                context: context,
                title: label,
                currentValue: displayValue,
                min: min,
                max: max,
                onConfirmed: onChanged!,
              ),
            ),
          ],
        ),
        CommitSlider(
          value: displayValue,
          min: min,
          max: max,
          divisions: divisions,
          enabled: canEdit,
          activeColor: colors.primary,
          inactiveColor: colors.primaryDim,
          labelBuilder: (value) => value.toStringAsFixed(2),
          onCommit: onChanged ?? (_) {},
        ),
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            hint,
            style: IntermediateTextStyles.caption.copyWith(
              color: colors.faint,
              fontSize: 11,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
