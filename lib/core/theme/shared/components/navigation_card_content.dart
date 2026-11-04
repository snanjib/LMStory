import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/shared/components/lm_interactive_motion.dart';
import 'package:lmstory/core/theme/system/lm_narrative_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/system/lm_ui_text_styles.dart';

/// Shared hierarchy for a destination; the active kit owns its surface.
class NavigationCardContent extends StatelessWidget {
  const NavigationCardContent({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.titleStyle,
    super.key,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final TextStyle? titleStyle;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    return LmInteractiveMotion(
      child: Row(
        children: [
          ExcludeSemantics(
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: colors.primaryDim,
                borderRadius: BorderRadius.circular(
                  context.lmUi.radius(LmCorner.sm),
                ),
              ),
              child: Icon(icon, color: colors.primary, size: 20),
            ),
          ),
          const SizedBox(width: LmSpacing.sMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: (titleStyle ??
                          LmNarrativeTextStyles.narrativeDisplay
                              .copyWith(fontSize: 20, height: 1.35))
                      .copyWith(color: colors.ink),
                ),
                if (subtitle.isNotEmpty) ...[
                  const SizedBox(height: LmSpacing.s2xs),
                  Text(
                    subtitle,
                    style: LmUiTextStyles.caption.copyWith(color: colors.muted),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: LmSpacing.sSm),
          ExcludeSemantics(
            child: Icon(Icons.arrow_forward, color: colors.faint, size: 18),
          ),
        ],
      ),
    );
  }
}
