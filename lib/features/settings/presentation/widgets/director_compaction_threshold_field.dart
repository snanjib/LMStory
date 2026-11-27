import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_spacing.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/utils/token_format.dart';
import 'package:lmstory/core/widgets/commit_slider.dart';
import 'package:lmstory/core/widgets/numeric_input_dialog.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 导演「上下文压缩阈值」字段：单一旋钮、双显示（上下文配置收敛 §2.1-1）。
///
/// 百分比滑杆（30%-80%，步长 1%）+ 生效 token 旁显（= 生效窗口 × 百分比，
/// k/M 格式）；token 值点按直接输入，反推百分比（= 输入值 / 生效窗口，
/// clamp 后按 1% 网格落滑杆）。分母 = 生效窗口 = min(模型窗口, 窗口上限)，
/// 由调用方解析传入（全局页走 advancedGlobalContextWindowProvider）。
///
/// 排布对齐 ContextBudgetSlider 预算行约定：caption 标签 + 百分比主读数
///（ink）+ token 次读数（primary，点按可输入——导演设置「数值点按可输入」
/// 约定， 统一走 token_format 唯一入口）。
class DirectorCompactionThresholdField extends StatefulWidget {
  const DirectorCompactionThresholdField({
    required this.ratio,
    required this.effectiveWindow,
    required this.onChanged,
    this.enabled = true,
    this.trailing,
    super.key,
  });

  /// 压缩阈值比例（advanced.contextBudget.compactionTriggerRatio）。
  final double ratio;

  /// 生效窗口（token）：min(模型窗口, 窗口上限)。
  final int effectiveWindow;

  /// Persists a committed ratio and returns whether it was saved.
  final Future<bool> Function(double) onChanged;

  /// 是否启用交互（生成中禁用）。
  final bool enabled;

  /// 标签行尾随控件（会话面板的「全局/自定义」模式 chip）。
  final Widget? trailing;

  @override
  State<DirectorCompactionThresholdField> createState() =>
      _DirectorCompactionThresholdFieldState();
}

class _DirectorCompactionThresholdFieldState
    extends State<DirectorCompactionThresholdField> {
  /// 拖动范围与故事侧压缩触发线同口径（DOC-14 §3.3）；上限 0.80 必须
  /// 小于轮中软着陆线 0.85（收敛计划 §2.2 次序约束）。
  static const double _ratioFloor = 0.30;
  static const double _ratioCeil = 0.80;
  static const int _divisions = 50; // 0.30 → 0.80，步长 0.01

  // CC-2：与百分比读数同一钳制值——存量会话
  // 列合法存在 <0.30 的值（收敛前滑杆 0.2-0.8），读数若用原值会出现
  // 「显示 30%」旁挂「≈19.2k tokens」的自相矛盾，且预填值非法。
  double? _previewRatio;
  double? _pendingRatio;
  int _sliderGeneration = 0;

  double get _savedRatio => widget.ratio.clamp(_ratioFloor, _ratioCeil);
  double get _displayRatio => _pendingRatio ?? _previewRatio ?? _savedRatio;
  bool get _enabled => widget.enabled && _pendingRatio == null;

  int get _thresholdTokens => (widget.effectiveWindow * _displayRatio).floor();

  String _formatPercent(double value) => '${(value * 100).toStringAsFixed(0)}%';

  Future<void> _commitRatio(double ratio) async {
    if (!_enabled || ratio == _savedRatio) return;
    setState(() => _pendingRatio = ratio);
    var saved = false;
    try {
      saved = await widget.onChanged(ratio);
    } finally {
      if (mounted) {
        setState(() {
          _previewRatio = null;
          _pendingRatio = null;
          if (!saved) _sliderGeneration++;
        });
      }
    }
  }

  void _showTokenInputDialog(BuildContext context) {
    final t = Translations.of(context);
    showNumericInputDialog(
      context: context,
      title: t.settings.director.context.thresholdTokenInputTitle,
      currentValue: _thresholdTokens.toDouble(),
      min: (widget.effectiveWindow * _ratioFloor).floorToDouble(),
      max: (widget.effectiveWindow * _ratioCeil).floorToDouble(),
      decimals: 0,
      onConfirmed: (tokens) {
        // 反推百分比：clamp 到滑杆范围后按 1% 网格取整，与 divisions 对齐
        final raw = tokens / widget.effectiveWindow;
        _commitRatio(
          (raw.clamp(_ratioFloor, _ratioCeil) * 100).round() / 100,
        );
      },
    );
  }

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
                t.settings.director.context.threshold,
                style: IntermediateTextStyles.caption
                    .copyWith(color: colors.muted),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(
              _formatPercent(_displayRatio),
              style: IntermediateTextStyles.bodyUi.copyWith(
                color: colors.ink,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: IntermediateSpacing.sXs),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _enabled ? () => _showTokenInputDialog(context) : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  vertical: IntermediateSpacing.s2xs,
                ),
                child: Text(
                  '≈ ${formatTokenCount(_thresholdTokens)} '
                  '${t.settings.director.context.thresholdTokensUnit}',
                  style: IntermediateTextStyles.caption.copyWith(
                    color: _enabled ? colors.primary : colors.faint,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            if (widget.trailing != null) ...[
              const SizedBox(width: IntermediateSpacing.sXs),
              widget.trailing!,
            ],
          ],
        ),
        CommitSlider(
          key: ValueKey(_sliderGeneration),
          value: _pendingRatio ?? _savedRatio,
          min: _ratioFloor,
          max: _ratioCeil,
          divisions: _divisions,
          activeColor: colors.primary,
          inactiveColor: colors.primaryDim,
          enabled: _enabled,
          labelBuilder: _formatPercent,
          onPreviewChanged: (ratio) => setState(() => _previewRatio = ratio),
          onCommit: _commitRatio,
        ),
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            t.settings.director.context.thresholdHint,
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
