import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_spacing.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/widgets/commit_slider.dart';
import 'package:lmstory/core/widgets/numeric_input_dialog.dart';
import 'package:lmstory/features/intermediate/presentation/widgets/collapsible_settings_section.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 导演设置页共享行组件与覆写写入助手（导演设置 P2）。
///
/// 交互约定沿用 DOC-14 §3.4：单项瓦片（[SettingsTile]）+ 数值常驻显示 +
/// 点按弹 [showNumericInputDialog] 直接输入；即时持久化（与故事模式
/// 全局配置一致——全局值即源头，无"重置为全局"概念）。

/// 写入/清除 advanced.* 覆写并刷新配置流。
///
/// [value] 为 null 时移除覆写（回落 default_config.json 默认值）。
Future<void> writeDirectorOverride(
  WidgetRef ref,
  String key,
  Object? value,
) async {
  final repo = ref.read(settingsRepositoryProvider);
  if (value == null) {
    await repo.removeUserOverride(key);
  } else {
    await repo.setUserOverride(key, value);
  }
  ref.invalidate(advancedConfigProvider);
}

/// 数值滑块行（小数显示两位；点按数值弹输入框）。
class DirectorSliderRow extends StatelessWidget {
  const DirectorSliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
    this.hint,
    this.valueLabel,
    this.decimals = 2,
    super.key,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;
  final String? hint;

  /// 数值显示覆写（如「0 = 不限」场景显示语义文案）。
  final String Function(double value)? valueLabel;
  final int decimals;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final displayValue = value.clamp(min, max);
    final text = valueLabel?.call(displayValue) ??
        (decimals == 0
            ? displayValue.toInt().toString()
            : displayValue.toStringAsFixed(decimals));

    return SettingsTile(
      child: Column(
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
              GestureDetector(
                onTap: () => showNumericInputDialog(
                  context: context,
                  title: label,
                  currentValue: displayValue,
                  min: min,
                  max: max,
                  onConfirmed: onChanged,
                ),
                child: Text(
                  text,
                  style: IntermediateTextStyles.bodyUi.copyWith(
                    color: colors.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          CommitSlider(
            value: displayValue,
            min: min,
            max: max,
            divisions: divisions,
            activeColor: colors.primary,
            inactiveColor: colors.primaryDim,
            labelBuilder: (v) =>
                valueLabel?.call(v) ?? v.toStringAsFixed(decimals),
            onCommit: onChanged,
          ),
          if (hint != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                hint!,
                style: IntermediateTextStyles.captionSm.copyWith(
                  color: colors.faint,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 整数步进行（- / + 步进器；点按数值弹输入框）。
class DirectorStepperRow extends StatelessWidget {
  const DirectorStepperRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.hint,
    this.valueLabel,
    super.key,
  });

  final String label;
  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;
  final String? hint;
  final String Function(int value)? valueLabel;

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;

    return SettingsTile(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: IntermediateTextStyles.caption
                      .copyWith(color: colors.muted),
                ),
              ),
              _StepButton(
                icon: Icons.remove,
                semanticLabel: t.common.decrease,
                onPressed: value > min ? () => onChanged(value - 1) : null,
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: IntermediateSpacing.sMd,
                ),
                child: GestureDetector(
                  onTap: () => showNumericInputDialog(
                    context: context,
                    title: label,
                    currentValue: value.toDouble(),
                    min: min.toDouble(),
                    max: max.toDouble(),
                    onConfirmed: (v) => onChanged(v.round()),
                  ),
                  child: Text(
                    valueLabel?.call(value) ?? value.toString(),
                    style: IntermediateTextStyles.bodyUi.copyWith(
                      color: colors.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              _StepButton(
                icon: Icons.add,
                semanticLabel: t.common.increase,
                onPressed: value < max ? () => onChanged(value + 1) : null,
              ),
            ],
          ),
          if (hint != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                hint!,
                style: IntermediateTextStyles.captionSm.copyWith(
                  color: colors.faint,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({
    required this.icon,
    required this.semanticLabel,
    required this.onPressed,
  });

  final IconData icon;

  /// 纯图标步进键的可读名（语义补完：此前读屏器只能播报「button N」）。
  final String semanticLabel;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    // 热区 44×44（图标视觉 16px 不变、居中），
    // 对齐 UA 批 8 收敛口径（侧边栏拖拽把手 28→44 同法）
    return SizedBox(
      width: 44,
      height: 44,
      child: IconButton(
        onPressed: onPressed,
        icon: Icon(icon, size: 16),
        tooltip: semanticLabel,
        color: colors.primary,
        disabledColor: colors.faint,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
        splashRadius: 22,
      ),
    );
  }
}

/// 分区间距。
const directorSectionGap = SizedBox(height: IntermediateSpacing.sXs);
