import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';

/// A finite entrance with a stable footprint and a separately painted child.
///
/// Change [trigger] for a new event, never for each streaming text delta.
class LmArrival extends StatefulWidget {
  const LmArrival({
    required this.child,
    this.trigger,
    this.animate = true,
    this.animateInitial = true,
    this.delay = Duration.zero,
    super.key,
  });

  final Widget child;
  final Object? trigger;
  final bool animate;
  final bool animateInitial;
  final Duration delay;

  @override
  State<LmArrival> createState() => _LmArrivalState();
}

class _LmArrivalState extends State<LmArrival>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  var _initialized = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: LmMotion.enter);
  }

  void _enter() {
    _controller.duration = LmMotion.enter + widget.delay;
    if (widget.animate && LmMotion.shouldAnimate(context)) {
      _controller.forward(from: 0);
    } else {
      _controller
        ..stop()
        ..value = 1;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialized) {
      _initialized = true;
      if (widget.animateInitial) {
        _enter();
      } else {
        _controller.value = 1;
      }
    } else if (!LmMotion.shouldAnimate(context)) {
      _controller
        ..stop()
        ..value = 1;
    }
  }

  @override
  void didUpdateWidget(LmArrival oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.trigger != oldWidget.trigger) _enter();
    if (!widget.animate) {
      _controller
        ..stop()
        ..value = 1;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final profile = context.lmUi.motionProfile;
    final total = LmMotion.enter + widget.delay;
    final start = widget.delay.inMicroseconds / total.inMicroseconds;
    return AnimatedBuilder(
      animation: _controller,
      child: RepaintBoundary(child: widget.child),
      builder: (context, child) {
        final progress =
            ((_controller.value - start) / (1 - start)).clamp(0.0, 1.0);
        final eased = profile.curve.transform(progress);
        return Transform.translate(
          offset: profile.enterOffset * (1 - eased),
          child: Opacity(opacity: eased, child: child),
        );
      },
    );
  }
}
