import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';

/// Paint-only feedback; the enclosed Kit control retains gestures and semantics.
class LmInteractiveMotion extends StatefulWidget {
  const LmInteractiveMotion({required this.child, super.key});

  final Widget child;

  @override
  State<LmInteractiveMotion> createState() => _LmInteractiveMotionState();
}

class _LmInteractiveMotionState extends State<LmInteractiveMotion> {
  var _hovered = false;
  var _focused = false;
  var _pressed = false;

  void _press(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final profile = context.lmUi.motionProfile;
    final offset = _hovered || _focused ? profile.hoverOffset : Offset.zero;
    final scale = _pressed ? profile.pressScale : 1.0;
    final transform = Matrix4.identity()
      ..translateByDouble(offset.dx, offset.dy, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1);
    return Focus(
      canRequestFocus: false,
      onFocusChange: (value) => setState(() => _focused = value),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Listener(
          onPointerDown: (_) => _press(true),
          onPointerUp: (_) => _press(false),
          onPointerCancel: (_) => _press(false),
          child: AnimatedContainer(
            duration: LmMotion.durationFor(context, LmMotion.press),
            curve: profile.curve,
            transform: transform,
            transformAlignment: Alignment.center,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
