import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';

/// Geometry supplied by the active structure; timing stays in [LmMotion].
@immutable
class LmMotionProfile {
  const LmMotionProfile({
    this.enterOffset = const Offset(0, 6),
    this.hoverOffset = const Offset(0, -1),
    this.pressScale = 0.99,
    this.activityRadius = 6,
    this.curve = LmMotion.easeSnap,
  });

  final Offset enterOffset;
  final Offset hoverOffset;
  final double pressScale;
  final double activityRadius;
  final Curve curve;
}
