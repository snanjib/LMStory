import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_spacing.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/widgets/commit_slider.dart';
import 'package:lmstory/core/widgets/editable_value_text.dart';
import 'package:lmstory/core/widgets/numeric_input_dialog.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart'
    show ChatSession;
import 'package:lmstory/features/chat/domain/entities/reasoning_effort.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart'
    show ConfigurationResolver;
import 'package:lmstory/features/intermediate/presentation/controllers/intermediate_chat_controller.dart'
    show IntermediateChatController;
import 'package:lmstory/features/settings/presentation/widgets/intermediate_review_enabled_section.dart'
    show IntermediateReviewEnabledSection;
import 'package:lmstory/features/templates/domain/entities/template.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 中级模式会话设置 — 工具调用开关（夜航主题，2 态下拉）。
///
/// 2026-07-22 重构（快照语义）：
/// - 移除"使用全局设置"选项和 globalToolCallingEnabled 参数
/// - [value] 改为 non-nullable，始终显示具体状态
/// - 新增 onReset 回调用于重置为全局当前值
///
/// 2 态语义（V2 四步流程，DOC-09B §8.6 / §10.2）：
/// - `true`（"启用"）：工具调用（extracting/summarizing 通过工具调用返回结构化数据）
/// - `false`（"禁用"）：直接输出 JSON 文本，适用于不支持工具调用的模型
class IntermediateJsonModeSelector extends StatelessWidget {
  const IntermediateJsonModeSelector({
    required this.value,
    required this.onChanged,
    required this.onReset,
    this.enabled = true,
    super.key,
  });

  final bool value;
  final ValueChanged<bool?> onChanged;
  final VoidCallback onReset;
  final bool enabled;

  static const _enabledKey = '__enabled__';
  static const _disabledKey = '__disabled__';

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;
    final dropdownValue = _mapToDropdown(value);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                t.intermediate.chat.sessionSettings.jsonMode,
                style: IntermediateTextStyles.caption
                    .copyWith(color: colors.muted),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              icon: Icon(Icons.refresh, size: 16, color: colors.faint),
              onPressed: enabled ? onReset : null,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              tooltip: t.intermediate.chat.sessionSettings.resetToGlobal,
            ),
          ],
        ),
        const SizedBox(height: IntermediateSpacing.sXs),
        DropdownButtonFormField<String>(
          initialValue: dropdownValue,
          isExpanded: true,
          decoration: inputDecoration(context, colors),
          style: IntermediateTextStyles.bodyUi.copyWith(color: colors.ink),
          iconEnabledColor: colors.muted,
          items: [
            DropdownMenuItem<String>(
              value: _enabledKey,
              child: Text(
                t.intermediate.chat.sessionSettings.jsonModeEnabled,
                style:
                    IntermediateTextStyles.bodyUi.copyWith(color: colors.ink),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            DropdownMenuItem<String>(
              value: _disabledKey,
              child: Text(
                t.intermediate.chat.sessionSettings.jsonModeDisabled,
                style:
                    IntermediateTextStyles.bodyUi.copyWith(color: colors.ink),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
          onChanged: enabled ? (v) => onChanged(_mapFromDropdown(v)) : null,
        ),
        const SizedBox(height: IntermediateSpacing.s2xs),
        Text(
          t.intermediate.chat.sessionSettings.jsonModeHint,
          style: IntermediateTextStyles.caption.copyWith(color: colors.faint),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }

  String _mapToDropdown(bool v) {
    return v ? _enabledKey : _disabledKey;
  }

  bool? _mapFromDropdown(String? v) {
    switch (v) {
      case _enabledKey:
        return true;
      case _disabledKey:
        return false;
      default:
        return null;
    }
  }
}

// ── 共享 InputDecoration 工厂 ────────────────────────────────────────
//  修复：圆角 rMd/rFull→rXs（4px 微圆角），对齐用户偏好"直角边缘"

/// 夜航主题输入装饰（dropdown/text field 共享）
InputDecoration inputDecoration(BuildContext context, LmPalette colors) {
  return InputDecoration(
    filled: true,
    fillColor: colors.surfaceVariant,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
      borderSide: BorderSide.none,
    ),
    contentPadding: const EdgeInsets.symmetric(
      horizontal: IntermediateSpacing.sMd,
      vertical: IntermediateSpacing.sSm,
    ),
  );
}

// ── 区段标题 ────────────────────────────────────────────────────────

/// 会话设置区段标题（带分隔线）
///
/// 用于在 sheet 内分隔不同类别（模型/提示词/生成参数/上下文/工具调用）。
class IntermediateSectionHeader extends StatelessWidget {
  const IntermediateSectionHeader({
    required this.title,
    super.key,
  });

  final String title;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    return Padding(
      padding: const EdgeInsets.only(top: IntermediateSpacing.sLg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: IntermediateTextStyles.label.copyWith(color: colors.primary),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: IntermediateSpacing.s2xs),
          Divider(height: 1, color: colors.divider),
        ],
      ),
    );
  }
}

// ── 系统提示词 ──────────────────────────────────────────────────────

/// 系统提示词模板选择对话框。
///
/// 故事模式会话设置（[IntermediateSystemPromptField]）与导演模式
/// 项目规则（DirectorSessionSettingsSheet）共用同一模板库与交互。
void showSystemPromptTemplatePicker(
  BuildContext context, {
  required List<Template> templates,
  required ValueChanged<Template> onTemplateSelected,
}) {
  final t = Translations.of(context);
  final colors = context.lm.palette;

  showLmDialog<void>(
    context: context,
    builder: (ctx) {
      return AlertDialog(
        title: Text(
          t.intermediate.chat.sessionSettings.selectTemplate,
          style: IntermediateTextStyles.title.copyWith(color: colors.ink),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        backgroundColor: colors.surfaceElevated,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
        ),
        contentPadding: const EdgeInsets.only(top: IntermediateSpacing.sSm),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: templates.length,
            separatorBuilder: (_, __) =>
                Divider(height: 1, color: colors.divider),
            itemBuilder: (_, index) {
              final template = templates[index];
              return ListTile(
                title: Text(
                  template.name,
                  style: IntermediateTextStyles.bodyUi.copyWith(
                    color: colors.ink,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  template.content,
                  style: IntermediateTextStyles.caption
                      .copyWith(color: colors.muted),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: IntermediateSpacing.sLg,
                  vertical: IntermediateSpacing.sXs,
                ),
                onTap: () {
                  onTemplateSelected(template);
                  Navigator.pop(ctx);
                },
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(t.common.cancel),
          ),
        ],
      );
    },
  );
}

/// 系统提示词输入框（带模板选择按钮和重置按钮）
///
/// 2026-07-22 重构（快照语义）：新增 onReset 回调用于重置为全局当前值。
/// hint 文案改为简单输入提示（当输入为空时显示内置默认角色设定预览）。
class IntermediateSystemPromptField extends StatelessWidget {
  const IntermediateSystemPromptField({
    required this.controller,
    required this.defaultPromptPreview,
    required this.templates,
    required this.onChanged,
    required this.onTemplateSelected,
    required this.onReset,
    this.enabled = true,
    super.key,
  });

  final TextEditingController controller;
  final String? defaultPromptPreview;
  final List<Template> templates;
  final ValueChanged<String> onChanged;
  final ValueChanged<Template> onTemplateSelected;
  final VoidCallback onReset;
  final bool enabled;

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
                t.intermediate.chat.sessionSettings.systemPrompt,
                style: IntermediateTextStyles.caption
                    .copyWith(color: colors.muted),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (templates.isNotEmpty)
              TextButton.icon(
                onPressed: enabled ? () => _showTemplatePicker(context) : null,
                icon: Icon(
                  Icons.bookmark_outline,
                  size: 16,
                  color: colors.primary,
                ),
                label: Flexible(
                  child: Text(
                    t.intermediate.chat.sessionSettings.selectTemplate,
                    style: IntermediateTextStyles.caption
                        .copyWith(color: colors.primary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: IntermediateSpacing.sXs,
                  ),
                  minimumSize: const Size(0, 32),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            IconButton(
              icon: Icon(Icons.refresh, size: 16, color: colors.faint),
              onPressed: enabled ? onReset : null,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              tooltip: t.intermediate.chat.sessionSettings.resetToGlobal,
            ),
          ],
        ),
        const SizedBox(height: IntermediateSpacing.sXs),
        TextField(
          controller: controller,
          maxLines: 5,
          minLines: 1,
          enabled: enabled,
          style: IntermediateTextStyles.bodyUi.copyWith(color: colors.ink),
          decoration: inputDecoration(context, colors).copyWith(
            hintText: defaultPromptPreview != null
                ? t.intermediate.chat.sessionSettings.systemPromptHint(
                    preview: defaultPromptPreview!,
                  )
                : t.intermediate.chat.sessionSettings.systemPromptEmptyHint,
            hintStyle:
                IntermediateTextStyles.bodyUi.copyWith(color: colors.faint),
          ),
          onChanged: onChanged,
        ),
      ],
    );
  }

  void _showTemplatePicker(BuildContext context) {
    showSystemPromptTemplatePicker(
      context,
      templates: templates,
      onTemplateSelected: onTemplateSelected,
    );
  }
}

// ── 生成参数 ────────────────────────────────────────────────────────

/// 通用数值滑块（带重置为全局当前值按钮）。
///
/// 用于 temperature / topP / presencePenalty / frequencyPenalty。
/// 2026-07-22 重构（快照语义）：
/// - [value] 改为 non-nullable，始终显示具体值（会话字段在物化时已被快照填充）
/// - 移除"使用默认（当前：xxx）"文案和长按重置手势
/// - 标题右侧显示重置图标按钮，点击后由父组件快照全局当前值覆盖会话字段
/// - 点击数值标签弹出精确输入对话框
class IntermediateSliderField extends StatelessWidget {
  const IntermediateSliderField({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
    required this.onReset,
    this.hint,
    this.enabled = true,
    this.isCustomized = true,
    this.globalValueText,
    super.key,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;
  final VoidCallback onReset;
  final String? hint;
  final bool enabled;

  /// 会话级是否已自定义。false 时值旁标注
  /// 「全局 {value}」且重置按钮禁用（已是全局态，重置无意义——
  /// 对齐思考预算选择器的既有三态范式）。
  final bool isCustomized;

  /// 未自定义时展示的全局生效值文本（isCustomized=false 时必传）。
  final String? globalValueText;

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;
    final displayValue = value.clamp(min, max);
    final showGlobalBadge =
        !isCustomized && globalValueText != null && globalValueText!.isNotEmpty;

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
            if (showGlobalBadge) ...[
              Text(
                t.common.followingGlobal(value: globalValueText!),
                style: IntermediateTextStyles.captionSm
                    .copyWith(color: colors.faint),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(width: IntermediateSpacing.s2xs),
            ],
            EditableValueText(
              value: displayValue.toStringAsFixed(2),
              label: label,
              enabled: enabled,
              tooltip: enabled
                  ? t.common.numericInput.hint(
                      min: min.toStringAsFixed(1),
                      max: max.toStringAsFixed(1),
                    )
                  : '',
              textStyle: IntermediateTextStyles.caption.copyWith(
                color: isCustomized ? colors.ink : colors.muted,
              ),
              iconColor: colors.faint,
              onTap: () => showNumericInputDialog(
                context: context,
                title: label,
                currentValue: displayValue,
                min: min,
                max: max,
                onConfirmed: onChanged,
              ),
            ),
            IconButton(
              icon: Icon(Icons.refresh, size: 16, color: colors.faint),
              // 未自定义时重置无意义 → 禁用。
              onPressed: enabled && isCustomized ? onReset : null,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              tooltip: t.intermediate.chat.sessionSettings.resetToGlobal,
            ),
          ],
        ),
        CommitSlider(
          value: displayValue,
          min: min,
          max: max,
          divisions: divisions,
          enabled: enabled,
          activeColor: colors.primary,
          inactiveColor: colors.primaryDim,
          labelBuilder: (value) => value.toStringAsFixed(2),
          onCommit: onChanged,
        ),
        if (hint != null) ...[
          const SizedBox(height: IntermediateSpacing.s2xs),
          Text(
            hint!,
            style: IntermediateTextStyles.caption.copyWith(color: colors.faint),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ],
    );
  }
}

// ── 最大 Token 数 ──────────────────────────────────────────────────

/// 最大 Token 数输入框
///
/// 2026-07-22 重构（快照语义）：移除 defaultMaxTokens 参数和"使用默认"hint，
/// 改为简单输入提示。新增 onReset 回调用于重置为全局当前值。
class IntermediateMaxTokensField extends StatelessWidget {
  const IntermediateMaxTokensField({
    required this.controller,
    required this.onSubmitted,
    required this.onReset,
    this.focusNode,
    this.enabled = true,
    this.isCustomized = true,
    this.globalValueText,
    super.key,
  });

  final TextEditingController controller;

  /// 失焦提交（导演侧接线；对齐 chat 侧）。
  final FocusNode? focusNode;
  final ValueChanged<int?> onSubmitted;
  final VoidCallback onReset;
  final bool enabled;

  /// 会话级是否已自定义（null=跟随全局时标注全局值、
  /// 重置按钮禁用）。见 [IntermediateSliderField] 同名参数。
  final bool isCustomized;
  final String? globalValueText;

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;
    final showGlobalBadge =
        !isCustomized && globalValueText != null && globalValueText!.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                t.intermediate.chat.sessionSettings.maxTokens,
                style: IntermediateTextStyles.caption
                    .copyWith(color: colors.muted),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (showGlobalBadge) ...[
              Text(
                t.common.followingGlobal(value: globalValueText!),
                style: IntermediateTextStyles.captionSm
                    .copyWith(color: colors.faint),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(width: IntermediateSpacing.s2xs),
            ],
            IconButton(
              icon: Icon(Icons.refresh, size: 16, color: colors.faint),
              onPressed: enabled && isCustomized ? onReset : null,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              tooltip: t.intermediate.chat.sessionSettings.resetToGlobal,
            ),
          ],
        ),
        const SizedBox(height: IntermediateSpacing.sXs),
        TextField(
          controller: controller,
          focusNode: focusNode,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          enabled: enabled,
          style: IntermediateTextStyles.bodyUi.copyWith(color: colors.ink),
          decoration: inputDecoration(context, colors).copyWith(
            hintText: t.intermediate.chat.sessionSettings.maxTokensHint,
            hintStyle:
                IntermediateTextStyles.bodyUi.copyWith(color: colors.faint),
            helperText: t.intermediate.chat.sessionSettings.maxTokensZeroHint,
            helperMaxLines: 2,
            helperStyle: IntermediateTextStyles.caption.copyWith(
              color: colors.faint,
              fontSize: 11,
            ),
          ),
          onSubmitted: (v) {
            final parsed = int.tryParse(v);
            onSubmitted(parsed);
          },
        ),
      ],
    );
  }
}

// v0.2.2 阶段 2-F：IntermediateMaxContextMessagesSlider 已删除。
// 故事模式引入 CompactionPoint 压缩机制后，原文区由 recentMinRatio +
// compactionTriggerRatio 动态控制，不再需要"最近 n 轮原文"的硬性消息数截断。
// Simple 模式仍保留 maxContextMessages 配置（Simple 无压缩机制）。

// ── 单次请求 token 上限（v0.2，2026-07-29 新增）────────────────────

/// 单次请求 token 上限滑块（离散档位，故事模式专用）
///
/// 用于应对 TPM 限制（如腾讯云 500万 TPM）：模型窗口虽大（如 GLM5.2 = 1M），
/// 但单次请求塞太多会触发 429。用户可通过此配置主动限制每次请求塞入的
/// token 数。实际生效值 = min(配置值, 模型窗口)。
///
/// 仅影响 generating/reviewing 阶段的 token 预算缩减。
/// 详见 [ConfigurationResolver.resolveIntermediateSettings] 和
/// [IntermediateChatController._resolveContextWindow]。
class IntermediateEffectiveContextLimitSlider extends StatelessWidget {
  const IntermediateEffectiveContextLimitSlider({
    required this.value,
    required this.onChanged,
    required this.onReset,
    this.enabled = true,
    this.isCustomized = true,
    super.key,
  });

  final int? value;
  final ValueChanged<int?> onChanged;
  final VoidCallback onReset;
  final bool enabled;

  /// 会话级是否已自定义（null=跟随全局）。
  final bool isCustomized;

  /// 预设档位（按 2 倍递增，覆盖主流模型窗口量级）
  ///
  /// 0 = 无限制（使用模型窗口）；其他值 = 实际 token 上限。
  /// 上限 524288 (512K) 覆盖 GLM5.2 / Claude 等大窗口模型，
  /// 但又远低于 1M，避免单次请求就触发 TPM 429。
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

  /// 将 token 数格式化为 K 单位显示（如 4096 → "4K"，524288 → "512K"）
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
                t.intermediate.chat.sessionSettings.effectiveContextLimit,
                style: IntermediateTextStyles.caption
                    .copyWith(color: colors.muted),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (!isCustomized) ...[
              Text(
                t.common.followingGlobal(
                  value: t.intermediate.chat.sessionSettings
                      .effectiveContextLimitNoLimit,
                ),
                style: IntermediateTextStyles.captionSm
                    .copyWith(color: colors.faint),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(width: IntermediateSpacing.s2xs),
            ],
            Text(
              actualValue == 0
                  ? t.intermediate.chat.sessionSettings
                      .effectiveContextLimitNoLimit
                  : _formatK(actualValue),
              style: IntermediateTextStyles.caption.copyWith(
                color: actualValue > 0 ? colors.ink : colors.faint,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            IconButton(
              icon: Icon(Icons.refresh, size: 16, color: colors.faint),
              onPressed: enabled && isCustomized ? onReset : null,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              tooltip: t.intermediate.chat.sessionSettings.resetToGlobal,
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
          enabled: enabled,
          labelBuilder: (idx) {
            final option = _options[idx.round()];
            return option == 0
                ? t.intermediate.chat.sessionSettings
                    .effectiveContextLimitNoLimit
                : _formatK(option);
          },
          onCommit: (idx) {
            final v = _options[idx.round()];
            onChanged(v == 0 ? null : v);
          },
        ),
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            t.intermediate.chat.sessionSettings.effectiveContextLimitHint,
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

// ── 思考预算（reasoningEffort，2026-07-19 Phase B 新增）──────────────

/// 思考预算选择器（夜航主题，5 态下拉）。
///
/// 2026-08-12（DOC-14 §3.2）：[value] 改回可空，新增"跟随全局"选项；
/// null 表示继承全局故事默认（全局再为 null 时即模型默认行为），与其它会话级
/// 可空覆盖字段语义一致。
///
/// 5 态语义：
/// - `null`（"跟随全局"）：继承全局 `intermediate.generation.reasoning_effort`
/// - `ReasoningEffort.disabled`：禁用思考
/// - `ReasoningEffort.low`：低预算
/// - `ReasoningEffort.medium`：中预算
/// - `ReasoningEffort.high`：高预算
class IntermediateReasoningEffortSelector extends StatelessWidget {
  const IntermediateReasoningEffortSelector({
    required this.value,
    required this.effectiveValue,
    required this.onChanged,
    required this.onReset,
    this.enabled = true,
    super.key,
  });

  /// 会话级覆盖值：null = 跟随全局。
  final ReasoningEffort? value;

  /// 当前生效的全局值，用于 value == null 时展示"当前生效：…"。
  final ReasoningEffort? effectiveValue;

  final ValueChanged<ReasoningEffort?> onChanged;
  final VoidCallback onReset;
  final bool enabled;

  static const _notSetKey = '__not_set__';
  static const _disabledKey = 'disabled';
  static const _lowKey = 'low';
  static const _mediumKey = 'medium';
  static const _highKey = 'high';

  String _optionLabel(ReasoningEffort v, Translations t) {
    final options = t.settings.intermediate.sessionReasoningEffortOptions;
    switch (v) {
      case ReasoningEffort.disabled:
        return options.disabled;
      case ReasoningEffort.low:
        return options.low;
      case ReasoningEffort.medium:
        return options.medium;
      case ReasoningEffort.high:
        return options.high;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;
    final dropdownValue = _mapToDropdown(value);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                t.settings.intermediate.sessionReasoningEffort,
                style: IntermediateTextStyles.caption
                    .copyWith(color: colors.muted),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              icon: Icon(Icons.refresh, size: 16, color: colors.faint),
              // value == null 时已是"跟随全局"，重置无意义 → 禁用
              onPressed: (enabled && value != null) ? onReset : null,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              tooltip: t.intermediate.chat.sessionSettings.resetToGlobal,
            ),
          ],
        ),
        const SizedBox(height: IntermediateSpacing.sXs),
        DropdownButtonFormField<String>(
          initialValue: dropdownValue,
          isExpanded: true,
          decoration: inputDecoration(context, colors),
          style: IntermediateTextStyles.bodyUi.copyWith(color: colors.ink),
          iconEnabledColor: colors.muted,
          items: [
            DropdownMenuItem<String>(
              value: _notSetKey,
              child: Text(
                t.settings.intermediate.sessionReasoningEffortOptions.notSet,
                style:
                    IntermediateTextStyles.bodyUi.copyWith(color: colors.ink),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            DropdownMenuItem<String>(
              value: _disabledKey,
              child: Text(
                t.settings.intermediate.sessionReasoningEffortOptions.disabled,
                style:
                    IntermediateTextStyles.bodyUi.copyWith(color: colors.ink),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            DropdownMenuItem<String>(
              value: _lowKey,
              child: Text(
                t.settings.intermediate.sessionReasoningEffortOptions.low,
                style:
                    IntermediateTextStyles.bodyUi.copyWith(color: colors.ink),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            DropdownMenuItem<String>(
              value: _mediumKey,
              child: Text(
                t.settings.intermediate.sessionReasoningEffortOptions.medium,
                style:
                    IntermediateTextStyles.bodyUi.copyWith(color: colors.ink),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            DropdownMenuItem<String>(
              value: _highKey,
              child: Text(
                t.settings.intermediate.sessionReasoningEffortOptions.high,
                style:
                    IntermediateTextStyles.bodyUi.copyWith(color: colors.ink),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
          onChanged: enabled ? (v) => onChanged(_mapFromDropdown(v)) : null,
        ),
        const SizedBox(height: IntermediateSpacing.s2xs),
        Text(
          t.settings.intermediate.sessionReasoningEffortHint,
          style: IntermediateTextStyles.caption.copyWith(color: colors.faint),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        if (value == null) ...[
          const SizedBox(height: IntermediateSpacing.s2xs),
          Text(
            t.settings.intermediate.sessionReasoningEffortCurrentEffect(
              prefix: effectiveValue != null
                  ? _optionLabel(effectiveValue!, t)
                  : t.settings.intermediate.generation.reasoningEffortNotSet,
            ),
            style: IntermediateTextStyles.caption.copyWith(color: colors.muted),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ],
    );
  }

  String _mapToDropdown(ReasoningEffort? v) {
    switch (v) {
      case null:
        return _notSetKey;
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

  ReasoningEffort? _mapFromDropdown(String? v) {
    switch (v) {
      case _notSetKey:
        return null;
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

// ── 审查会话级覆盖（审查  新增）──────────────────────────────

/// 审查会话级三态选择器（夜航主题）。
///
/// 控制 [ChatSession.reviewEnabledOverride] 字段，三态语义：
/// - `null`（"跟随全局设置"）：使用全局 `intermediate.reviewEnabled` 配置
/// - `true`（"开启"）：强制启用审查阶段（reviewing，4 次 LLM 调用）
/// - `false`（"关闭"）：强制跳过审查阶段（3 次 LLM 调用）
///
/// 视觉与交互复刻 [IntermediateJsonModeSelector]：标题 + 下拉 + hint，
/// 但下拉包含 3 个选项（含"跟随全局"），value 为可空 `bool?`。
/// 重置按钮在 value != null 时可点击（点击后置 null，回到"跟随全局"）。
///
/// 优先级：会话级 reviewEnabledOverride > 全局 intermediate.reviewEnabled。
/// 全局开关由 [IntermediateReviewEnabledSection] 控制。
class IntermediateReviewEnabledSelector extends StatelessWidget {
  const IntermediateReviewEnabledSelector({
    required this.value,
    required this.onChanged,
    required this.onReset,
    this.enabled = true,
    super.key,
  });

  /// 三态值：true=开启 / false=关闭 / null=使用全局设置（
  /// 选中首项经回调写入全局当前值快照，不再持久化 NULL 跟随态）
  final bool? value;
  final ValueChanged<bool?> onChanged;
  final VoidCallback onReset;
  final bool enabled;

  static const _followGlobalKey = '__follow_global__';
  static const _enabledKey = '__enabled__';
  static const _disabledKey = '__disabled__';

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;
    final dropdownValue = _mapToDropdown(value);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                t.intermediate.chat.sessionSettings.reviewEnabled,
                style: IntermediateTextStyles.caption
                    .copyWith(color: colors.muted),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              icon: Icon(Icons.refresh, size: 16, color: colors.faint),
              // value == null 时已是全局快照态，重置按钮无意义 → 禁用
              onPressed: (enabled && value != null) ? onReset : null,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              tooltip: t.intermediate.chat.sessionSettings.resetToGlobal,
            ),
          ],
        ),
        const SizedBox(height: IntermediateSpacing.sXs),
        DropdownButtonFormField<String>(
          initialValue: dropdownValue,
          isExpanded: true,
          decoration: inputDecoration(context, colors),
          style: IntermediateTextStyles.bodyUi.copyWith(color: colors.ink),
          iconEnabledColor: colors.muted,
          items: [
            DropdownMenuItem<String>(
              value: _followGlobalKey,
              child: Text(
                t.intermediate.chat.sessionSettings.reviewEnabledSessionDefault,
                style:
                    IntermediateTextStyles.bodyUi.copyWith(color: colors.ink),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            DropdownMenuItem<String>(
              value: _enabledKey,
              child: Text(
                t.intermediate.chat.sessionSettings.reviewEnabledEnabled,
                style:
                    IntermediateTextStyles.bodyUi.copyWith(color: colors.ink),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            DropdownMenuItem<String>(
              value: _disabledKey,
              child: Text(
                t.intermediate.chat.sessionSettings.reviewEnabledDisabled,
                style:
                    IntermediateTextStyles.bodyUi.copyWith(color: colors.ink),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
          onChanged: enabled ? (v) => onChanged(_mapFromDropdown(v)) : null,
        ),
        const SizedBox(height: IntermediateSpacing.s2xs),
        Text(
          t.intermediate.chat.sessionSettings.reviewEnabledHint,
          style: IntermediateTextStyles.caption.copyWith(color: colors.faint),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }

  String _mapToDropdown(bool? v) {
    switch (v) {
      case null:
        return _followGlobalKey;
      case true:
        return _enabledKey;
      case false:
        return _disabledKey;
    }
  }

  bool? _mapFromDropdown(String? v) {
    switch (v) {
      case _followGlobalKey:
        return null;
      case _enabledKey:
        return true;
      case _disabledKey:
        return false;
      default:
        return null;
    }
  }
}

// ── 上下文预算会话级覆盖（审查  修复，2026-07-31 新增）──────────────
