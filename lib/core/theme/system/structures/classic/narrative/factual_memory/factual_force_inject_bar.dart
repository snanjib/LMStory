import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/system/lm_narrative_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/memory/domain/entities/force_inject_target.dart';
import 'package:lmstory/i18n/strings.g.dart';

// 从 factual_memory_tab.dart 拆出（原 _buildForceInjectBar /
// _buildForceInjectAction，逐字符搬运；批量落库动作经回调交回 Tab State）。

/// 强制注入批量操作栏（多选模式下显示）。
/// （原 _FactualMemoryTabState._buildForceInjectBar）
class FactualForceInjectBar extends StatelessWidget {
  const FactualForceInjectBar({
    required this.colors,
    required this.t,
    required this.selectedCount,
    required this.showMergeAction,
    required this.onAiMergeSelected,
    required this.onApplyForceInject,
    super.key,
  });

  final LmPalette colors;
  final Translations t;

  /// 已选实体数（原 _selectedEntityIds.length）
  final int selectedCount;

  /// 是否提供"AI 合并"入口（原 widget.mergeService != null）
  final bool showMergeAction;
  final VoidCallback onAiMergeSelected;
  final void Function(ForceInjectTarget) onApplyForceInject;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: LmSpacing.sLg,
        vertical: LmSpacing.sSm,
      ),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(top: BorderSide(color: colors.divider)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              t.intermediate.memoryBrowser
                  .forceInjectSelected(n: selectedCount),
              style:
                  LmNarrativeTextStyles.caption.copyWith(color: colors.muted),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (showMergeAction) ...[
            TextButton(
              onPressed: onAiMergeSelected,
              child: Text(
                t.intermediate.memoryBrowser.mergeAction,
                style: LmNarrativeTextStyles.caption.copyWith(
                  color: colors.primary,
                ),
              ),
            ),
            const SizedBox(width: LmSpacing.sXs),
          ],
          _buildForceInjectAction(
            colors,
            t,
            ForceInjectTarget.none,
            t.intermediate.memoryBrowser.forceInjectOff,
          ),
          const SizedBox(width: LmSpacing.sXs),
          _buildForceInjectAction(
            colors,
            t,
            ForceInjectTarget.world,
            t.intermediate.memoryBrowser.forceInjectWorld,
          ),
          const SizedBox(width: LmSpacing.sXs),
          _buildForceInjectAction(
            colors,
            t,
            ForceInjectTarget.directive,
            t.intermediate.memoryBrowser.forceInjectDirective,
          ),
        ],
      ),
    );
  }

  Widget _buildForceInjectAction(
    LmPalette colors,
    Translations t,
    ForceInjectTarget target,
    String label,
  ) {
    return TextButton(
      onPressed: () => onApplyForceInject(target),
      child: Text(
        label,
        style: LmNarrativeTextStyles.caption.copyWith(color: colors.primary),
      ),
    );
  }
}
