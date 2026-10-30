import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/shared/components/lm_activity_dots.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';

/// Sidebar activity feedback shares viewport and lifecycle gating with loaders.
class BreathingDot extends StatelessWidget {
  const BreathingDot({this.size = 8.0, super.key});

  final double size;

  @override
  Widget build(BuildContext context) => Opacity(
        opacity: LmMotion.reducedMotion(context) ? 0.7 : 1,
        child: LmActivityDots(count: 1, dotSize: size),
      );
}
