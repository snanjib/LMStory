import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';

/// Short feedback for a discrete state; outgoing controls cannot receive input.
class LmStateTransition extends StatelessWidget {
  const LmStateTransition({
    required this.stateKey,
    required this.child,
    this.alignment = Alignment.centerLeft,
    super.key,
  });

  final Object stateKey;
  final Widget child;
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
        duration: LmMotion.durationFor(context, LmMotion.fast),
        reverseDuration: LmMotion.durationFor(context, LmMotion.micro),
        switchInCurve: LmMotion.easeSnap,
        switchOutCurve: LmMotion.easeStandard,
        layoutBuilder: (current, previous) => Stack(
          alignment: alignment,
          children: [
            for (final outgoing in previous)
              ExcludeSemantics(child: IgnorePointer(child: outgoing)),
            if (current != null) current,
          ],
        ),
        child: KeyedSubtree(key: ValueKey(stateKey), child: child),
      );
}
