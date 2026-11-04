import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';

/// Waiting feedback drawn on a tiny layer without rebuilding its parent.
///
/// The loop stops in the background, outside the viewport, under TickerMode,
/// and when the user requests reduced motion.
class LmActivityDots extends StatefulWidget {
  const LmActivityDots({
    this.color,
    this.label,
    this.dotSize = 6,
    this.count = 3,
    super.key,
  })  : assert(count > 0, 'At least one activity dot is required.'),
        assert(dotSize > 0, 'Activity dots need a positive size.');

  final Color? color;
  final String? label;
  final double dotSize;
  final int count;

  @override
  State<LmActivityDots> createState() => _LmActivityDotsState();
}

class _LmActivityDotsState extends State<LmActivityDots>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _controller;
  ScrollPosition? _position;
  var _visible = true;
  var _visibilityQueued = false;
  var _foreground = true;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.count == 1 ? LmMotion.breathe : LmMotion.loop,
    );
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final position = Scrollable.maybeOf(context)?.position;
    if (position != _position) {
      _position?.removeListener(_checkVisibility);
      _position = position;
      _position?.addListener(_checkVisibility);
    }
    _syncLoop();
    _queueVisibility();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (mounted) _syncLoop();
  }

  @override
  void didChangeMetrics() => _queueVisibility();

  void _syncLoop() {
    final allowed = LmMotion.shouldAnimate(context) &&
        TickerMode.valuesOf(context).enabled &&
        _foreground &&
        _visible;
    if (allowed) {
      if (!_controller.isAnimating) _controller.repeat();
    } else {
      _controller.stop();
      if (LmMotion.reducedMotion(context)) _controller.value = 0;
    }
  }

  void _queueVisibility() {
    if (_visibilityQueued) return;
    _visibilityQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _visibilityQueued = false;
      if (mounted) _checkVisibility();
    });
  }

  void _checkVisibility() {
    final position = _position;
    final box = context.findRenderObject();
    if (position == null ||
        !position.hasContentDimensions ||
        box is! RenderBox ||
        !box.hasSize) {
      return;
    }
    final viewport = RenderAbstractViewport.maybeOf(box);
    if (viewport == null) return;
    final start = viewport.getOffsetToReveal(box, 0).offset;
    final end =
        viewport.getOffsetToReveal(box, 1).offset + position.viewportDimension;
    final visible = end > position.pixels &&
        start < position.pixels + position.viewportDimension;
    if (visible != _visible) {
      _visible = visible;
      _syncLoop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _position?.removeListener(_checkVisibility);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _queueVisibility();
    return Semantics(
      label: widget.label,
      child: ExcludeSemantics(
        child: RepaintBoundary(
          child: SizedBox(
            width: widget.count * widget.dotSize + (widget.count - 1) * 4,
            height: widget.dotSize + (widget.count > 1 ? 4 : 0),
            child: CustomPaint(
              painter: _DotsPainter(
                animation: _controller,
                color: widget.color ?? context.lm.palette.primary,
                dotSize: widget.dotSize,
                count: widget.count,
                radius: context.lmUi.motionProfile.activityRadius,
                reduced: LmMotion.reducedMotion(context),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DotsPainter extends CustomPainter {
  _DotsPainter({
    required this.animation,
    required this.color,
    required this.dotSize,
    required this.count,
    required this.radius,
    required this.reduced,
  }) : super(repaint: animation);

  final Animation<double> animation;
  final Color color;
  final double dotSize;
  final int count;
  final double radius;
  final bool reduced;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    for (var i = 0; i < count; i++) {
      final phase = (animation.value - i * 0.18) % 1;
      final pulse = reduced
          ? 1.0
          : (phase < 0.5
              ? LmMotion.easeBoth.transform(phase * 2)
              : LmMotion.easeBoth.transform((1 - phase) * 2));
      paint.color = color.withValues(alpha: color.a * (0.4 + pulse * 0.6));
      final top = count > 1 ? 4 - pulse * 3 : 0.0;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(i * (dotSize + 4), top, dotSize, dotSize),
          Radius.circular(radius),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_DotsPainter oldDelegate) =>
      color != oldDelegate.color ||
      dotSize != oldDelegate.dotSize ||
      count != oldDelegate.count ||
      radius != oldDelegate.radius ||
      reduced != oldDelegate.reduced ||
      animation != oldDelegate.animation;
}
