import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_spacing.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/utils/token_format.dart';
import 'package:lmstory/core/widgets/commit_slider.dart';
import 'package:lmstory/features/story_runtime/presentation/widgets/session_settings_fields.dart'
    show IntermediateSliderField;
import 'package:lmstory/i18n/strings.g.dart';

/// 上下文预算百分比条组件（/ DOC-06B §6 夜航主题）。
///
/// 可视化配置故事模式上下文窗口的 token 预算分配：
/// - **压缩触发线**（compactionTriggerRatio）：总占用达此比例触发压缩。
///   传入 [onCompactionTriggerRatioChanged] 时可拖动（范围 30%-80%，默认 50%），
///   否则只读展示（DOC-14 §3.3 由固定 50% 改为可调）。
/// - **原文区下限**（recentMinRatio）：默认动态（null，基于 32K token 反推），
///   可切换为自定义百分比。滑块常驻显示，拖动范围 10%-45%。
/// - **检索区比例**（retrievalRatio）：可拖动，默认 15%。范围 0%-30%。
///
/// 切换模型时下限自动重算：父组件传入新的 [availableWindow]，
/// 动态模式下显示的百分比和 token 预估会随之更新。
///
/// 设计参考 [IntermediateSliderField]：surface 卡片 + caption 标签 +
/// Slider 控件 + 重置按钮。所有 Text 在有限宽度容器中均设置 overflow。
class ContextBudgetSlider extends StatelessWidget {
  const ContextBudgetSlider({
    required this.compactionTriggerRatio,
    required this.recentMinRatio,
    required this.retrievalRatio,
    required this.availableWindow,
    this.secondaryWindow,
    this.recentMinTokenTarget = 32000,
    this.onCompactionTriggerRatioChanged,
    this.onMinRatioChanged,
    this.onRetrievalRatioChanged,
    this.enabled = true,
    super.key,
  });

  /// 压缩触发线（总占用达此比例触发压缩，默认 0.5）。
  /// 仅当传入 [onCompactionTriggerRatioChanged] 时可调（DOC-14 §3.3）。
  final double compactionTriggerRatio;

  /// 原文区下限。null = 动态计算（基于 [recentMinTokenTarget] / [availableWindow]）。
  final double? recentMinRatio;

  /// 检索区比例（默认 0.15）。
  final double retrievalRatio;

  /// 可用窗口（token），来自当前模型的 contextWindow。
  /// 用于动态计算下限百分比和预估各区域 token 数。
  final int availableWindow;

  /// 审查阶段可用窗口（token），null 或与 [availableWindow] 相同时
  /// 不展示第二组 token 预估。
  /// 用于分别展示生成阶段和审查阶段的 token 分配。
  final int? secondaryWindow;

  /// 动态计算下限时的目标 token 数（默认 32000）。
  final int recentMinTokenTarget;

  /// 下限比例变更回调。null 表示不可变更（只读展示）。
  ///
  /// 传 null 值表示切回"动态"模式。
  final ValueChanged<double?>? onMinRatioChanged;

  /// 检索区比例变更回调。
  final ValueChanged<double>? onRetrievalRatioChanged;

  /// 压缩触发线变更回调（DOC-14 §3.3）。null 表示只读展示（不可调）。
  final ValueChanged<double>? onCompactionTriggerRatioChanged;

  /// 是否启用交互（生成中禁用）。
  final bool enabled;

  /// 下限百分比拖动范围（对齐 ContextBudget.computeRecentMinRatio 的 clamp）。
  static const double _minRatioFloor = 0.10;
  static const double _minRatioCeil = 0.45;

  /// 检索区百分比拖动范围（v0.2.2 阶段 2-E 修订：下限从 0.05 改为 0，
  /// 允许用户完全关闭检索注入；divisions 同步改为 30）
  static const double _retrievalRatioFloor = 0;
  static const double _retrievalRatioCeil = 0.30;

  /// 压缩触发线拖动范围（DOC-14 §3.3：由固定 0.5 改为 0.30-0.80 可调）。
  static const double _triggerFloor = 0.30;
  static const double _triggerCeil = 0.80;

  /// 动态计算下限百分比（对齐 ContextBudget.computeRecentMinRatio 逻辑）。
  double _computeDynamicMinRatio() {
    final raw = recentMinTokenTarget / availableWindow;
    return raw.clamp(_minRatioFloor, _minRatioCeil);
  }

  String _formatPercent(double ratio) {
    return '${(ratio * 100).toStringAsFixed(0)}%';
  }

  /// 统一走 core/utils/token_format.dart 唯一入口。
  String _formatTokens(int tokens) => formatTokenCount(tokens);

  /// 是否需要展示审查阶段的第二组 token 预估。
  bool get _hasSecondary =>
      secondaryWindow != null && secondaryWindow != availableWindow;

  /// 生成审查阶段 token 预估文案（仅在 _hasSecondary 时调用）。
  String _secondaryTokenText(double ratio, Translations t) {
    final tokens = (secondaryWindow! * ratio).floor();
    return '${t.settings.intermediate.contextBudgetReviewing} ${_formatTokens(tokens)} ${t.settings.intermediate.contextBudgetTokens}';
  }

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;
    final isDynamic = recentMinRatio == null;
    final effectiveMinRatio =
        isDynamic ? _computeDynamicMinRatio() : recentMinRatio!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── 可用窗口信息行 ──
        Row(
          children: [
            Expanded(
              child: Text(
                t.settings.intermediate.contextBudgetAvailableWindow,
                style: IntermediateTextStyles.caption
                    .copyWith(color: colors.muted),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (_hasSecondary) ...[
              Text(
                '${t.settings.intermediate.contextBudgetGenerating} ${_formatTokens(availableWindow)}',
                style:
                    IntermediateTextStyles.caption.copyWith(color: colors.ink),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(width: IntermediateSpacing.sSm),
              Text(
                '${t.settings.intermediate.contextBudgetReviewing} ${_formatTokens(secondaryWindow!)}',
                style: IntermediateTextStyles.caption
                    .copyWith(color: colors.faint),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ] else
              Text(
                _formatTokens(availableWindow),
                style:
                    IntermediateTextStyles.caption.copyWith(color: colors.ink),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
        const SizedBox(height: IntermediateSpacing.sMd),

        // ── 压缩触发线（DOC-14 §3.3：可调；未传回调时只读）──
        _BudgetRow(
          label: t.settings.intermediate.contextBudgetRecentMax,
          percentText: _formatPercent(compactionTriggerRatio),
          tokenText:
              '${_formatTokens((availableWindow * compactionTriggerRatio).floor())} ${t.settings.intermediate.contextBudgetTokens}',
          secondaryTokenText: _hasSecondary
              ? _secondaryTokenText(compactionTriggerRatio, t)
              : null,
          colors: colors,
          isFixed: onCompactionTriggerRatioChanged == null,
        ),
        if (onCompactionTriggerRatioChanged != null)
          CommitSlider(
            value: compactionTriggerRatio.clamp(_triggerFloor, _triggerCeil),
            min: _triggerFloor,
            max: _triggerCeil,
            divisions: 50, // 0.30 → 0.80，步长 0.01
            activeColor: colors.primary,
            inactiveColor: colors.primaryDim,
            enabled: enabled,
            labelBuilder: _formatPercent,
            onCommit: onCompactionTriggerRatioChanged!,
          )
        else
          _FixedSliderMark(colors: colors, value: compactionTriggerRatio),
        const SizedBox(height: IntermediateSpacing.sMd),

        // ── 原文区下限（动态/自定义切换 + 滑块）──
        _BudgetRow(
          label: t.settings.intermediate.contextBudgetRecentMin,
          percentText: _formatPercent(effectiveMinRatio),
          tokenText:
              '${_formatTokens((availableWindow * effectiveMinRatio).floor())} ${t.settings.intermediate.contextBudgetTokens}',
          secondaryTokenText:
              _hasSecondary ? _secondaryTokenText(effectiveMinRatio, t) : null,
          colors: colors,
          trailing: onMinRatioChanged != null
              ? _DynamicCustomToggle(
                  isDynamic: isDynamic,
                  onChanged: enabled
                      ? (dynamicMode) => onMinRatioChanged!(
                            dynamicMode ? null : _computeDynamicMinRatio(),
                          )
                      : null,
                  colors: colors,
                  t: t,
                )
              : null,
        ),
        if (onMinRatioChanged != null)
          CommitSlider(
            value: effectiveMinRatio.clamp(_minRatioFloor, _minRatioCeil),
            min: _minRatioFloor,
            max: _minRatioCeil,
            divisions: 35, // 0.10 → 0.45，步长 0.01
            activeColor: colors.primary,
            inactiveColor: colors.primaryDim,
            enabled: enabled,
            labelBuilder: _formatPercent,
            onCommit: onMinRatioChanged!,
          )
        else
          _FixedSliderMark(colors: colors, value: effectiveMinRatio),
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            t.settings.intermediate.contextBudgetRecentMinHint,
            style: IntermediateTextStyles.caption.copyWith(
              color: colors.faint,
              fontSize: 11,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(height: IntermediateSpacing.sMd),

        // ── 检索区比例（可拖动，v0.2.2 阶段 2-E：下限改为 0 允许完全关闭）──
        _BudgetRow(
          label: t.settings.intermediate.contextBudgetRetrieval,
          percentText: _formatPercent(retrievalRatio),
          tokenText:
              '${_formatTokens((availableWindow * retrievalRatio).floor())} ${t.settings.intermediate.contextBudgetTokens}',
          secondaryTokenText:
              _hasSecondary ? _secondaryTokenText(retrievalRatio, t) : null,
          colors: colors,
        ),
        CommitSlider(
          value:
              retrievalRatio.clamp(_retrievalRatioFloor, _retrievalRatioCeil),
          min: _retrievalRatioFloor,
          max: _retrievalRatioCeil,
          divisions: 30, // 0.00 → 0.30，步长 0.01
          activeColor: colors.primary,
          inactiveColor: colors.primaryDim,
          enabled: enabled && onRetrievalRatioChanged != null,
          labelBuilder: _formatPercent,
          onCommit: onRetrievalRatioChanged ?? (_) {},
        ),
        // v0.2.2 阶段 2-E：检索区比例 = 0 时显示"已完全关闭检索"明确提示
        if (retrievalRatio <= 0.0)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              t.settings.intermediate.contextBudgetRetrievalDisabledHint,
              style: IntermediateTextStyles.caption.copyWith(
                color: colors.warning,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              t.settings.intermediate.contextBudgetRetrievalHint,
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

/// 预算行：标签 + 百分比 + token 预估（+ 可选 trailing 控件）。
class _BudgetRow extends StatelessWidget {
  const _BudgetRow({
    required this.label,
    required this.percentText,
    required this.tokenText,
    required this.colors,
    this.secondaryTokenText,
    this.isFixed = false,
    this.trailing,
  });

  final String label;
  final String percentText;
  final String tokenText;
  final LmPalette colors;
  final String? secondaryTokenText;
  final bool isFixed;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
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
            if (trailing != null) trailing!,
            const SizedBox(width: IntermediateSpacing.sXs),
            Text(
              percentText,
              style: IntermediateTextStyles.caption.copyWith(
                color: isFixed ? colors.faint : colors.ink,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(width: IntermediateSpacing.sXs),
            Text(
              tokenText,
              style: IntermediateTextStyles.caption
                  .copyWith(color: colors.faint, fontSize: 11),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        if (secondaryTokenText != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              secondaryTokenText!,
              style: IntermediateTextStyles.caption
                  .copyWith(color: colors.faint, fontSize: 11),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );
  }
}

/// 固定标记线（灰色不可拖动滑块的视觉占位）。
class _FixedSliderMark extends StatelessWidget {
  const _FixedSliderMark({required this.colors, required this.value});

  final LmPalette colors;
  final double value;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        // 占位对齐 Slider 左边距
        Expanded(
          child: Stack(
            alignment: Alignment.centerLeft,
            children: [
              // 底部细线（模拟 inactiveColor 轨道）
              Container(
                height: 4,
                decoration: BoxDecoration(
                  color: colors.divider,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              // 固定位置标记圆点
              FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: value.clamp(0.0, 1.0),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Container(
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(
                      color: colors.faint,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// "动态/自定义" 切换按钮（小型 chip 风格）。
class _DynamicCustomToggle extends StatelessWidget {
  const _DynamicCustomToggle({
    required this.isDynamic,
    required this.onChanged,
    required this.colors,
    required this.t,
  });

  final bool isDynamic;
  final ValueChanged<bool>? onChanged;
  final LmPalette colors;
  final Translations t;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: colors.surfaceVariant,
      borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onChanged == null ? null : () => onChanged!(!isDynamic),
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: IntermediateSpacing.sSm,
            vertical: 2,
          ),
          child: Text(
            isDynamic
                ? t.settings.intermediate.contextBudgetDynamic
                : t.settings.intermediate.contextBudgetCustom,
            style: IntermediateTextStyles.caption.copyWith(
              color: isDynamic ? colors.faint : colors.primary,
              fontSize: 11,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }
}
