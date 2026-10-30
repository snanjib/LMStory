import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/system/lm_layout.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';

/// An opaque writing surface aligned with the reading column.
class ComposerSurface extends StatelessWidget {
  const ComposerSurface({
    required this.child,
    required this.color,
    required this.borderColor,
    this.borderWidth = 1,
    super.key,
  });

  final Widget child;
  final Color color;
  final Color borderColor;
  final double borderWidth;

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.bottomCenter,
        heightFactor: 1,
        child: ConstrainedBox(
          constraints:
              BoxConstraints(maxWidth: LmLayout.readingWidthOf(context)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              LmSpacing.sSm,
              LmSpacing.sXs,
              LmSpacing.sSm,
              LmSpacing.sSm,
            ),
            child: AnimatedContainer(
              duration: LmMotion.durationFor(context, LmMotion.focus),
              curve: LmMotion.easeColor,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(
                  context.lmUi.radius(LmCorner.lg),
                ),
                border: Border.all(color: borderColor, width: borderWidth),
              ),
              child: child,
            ),
          ),
        ),
      );
}
