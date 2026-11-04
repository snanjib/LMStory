import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/system/lm_ui_text_styles.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// Simple mode fork navigator.
///
/// Compact inline widget showing "1/3 ◀ ▶" for messages with multiple
/// fork branches. Uses caption text size and faint colours to stay
/// unobtrusive.
class SimpleForkNav extends StatelessWidget {
  const SimpleForkNav({
    required this.currentIndex,
    required this.totalCount,
    required this.onPrev,
    required this.onNext,
    super.key,
  });

  /// Current branch index (1-based for display).
  final int currentIndex;

  /// Total number of branches.
  final int totalCount;

  /// Callback when the user taps the previous arrow.
  final VoidCallback onPrev;

  /// Callback when the user taps the next arrow.
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: LmSpacing.s2xs),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Previous arrow
          _NavButton(
            icon: Icons.chevron_left,
            size: 16,
            color: colors.muted,
            tooltip: t.chat.branch.switchLeft,
            onTap: onPrev,
          ),
          const SizedBox(width: LmSpacing.s3xs),
          // Indicator text: "1/3"
          Text(
            t.chat.branch.indicator(
              current: currentIndex,
              total: totalCount,
            ),
            style: LmUiTextStyles.caption.copyWith(color: colors.faint),
          ),
          const SizedBox(width: LmSpacing.s3xs),
          // Next arrow
          _NavButton(
            icon: Icons.chevron_right,
            size: 16,
            color: colors.muted,
            tooltip: t.chat.branch.switchRight,
            onTap: onNext,
          ),
        ],
      ),
    );
  }
}

class _NavButton extends StatelessWidget {
  const _NavButton({
    required this.icon,
    required this.size,
    required this.color,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final double size;
  final Color color;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
        child: Padding(
          // 扩大点击区域至 48x48（满足 Material Design 触控目标要求）
          padding: const EdgeInsets.all(LmSpacing.sLg),
          child: Icon(icon, size: size, color: color),
        ),
      ),
    );
  }
}
