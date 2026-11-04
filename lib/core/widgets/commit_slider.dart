import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A slider that keeps drag feedback local and commits once on release.
///
/// Use this for values whose callback persists data or invalidates providers.
/// The thumb remains fully responsive while expensive work is deferred until
/// the gesture ends.
///
/// 与 Flutter 原生 [Slider] 的关键差异：仅当手势起始于圆点附近时才改变数值，
/// 点击轨道不会跳值——避免在会话设置页上下滑动时误触（DOC-14 §3.1）。
///
/// 键盘可达性：自绘组件此前无 Focus 支持，桌面端方向键
/// 被框架方向焦点遍历抢走（焦点逃逸到相邻控件）。现指针按下即获焦，获得
/// 焦点后方向键步进并提交、Home/End 跳到 min/max，与原生 Slider 对齐。
class CommitSlider extends StatefulWidget {
  const CommitSlider({
    required this.value,
    required this.min,
    required this.max,
    required this.onCommit,
    this.divisions,
    this.enabled = true,
    this.activeColor,
    this.inactiveColor,
    this.labelBuilder,
    super.key,
  });

  final double value;
  final double min;
  final double max;
  final int? divisions;
  final bool enabled;
  final Color? activeColor;
  final Color? inactiveColor;
  final String Function(double value)? labelBuilder;
  final ValueChanged<double> onCommit;

  @override
  State<CommitSlider> createState() => _CommitSliderState();
}

class _CommitSliderState extends State<CommitSlider> {
  late double _draftValue;
  bool _dragging = false;

  /// 最近一次提交的值（键盘步进去重基线）。
  ///
  /// 键盘连续步进时父层可能尚未回写 [CommitSlider.value]（异步持久化），
  /// 以 prop 值去重会误吞合法提交；以本地已提交值为基线，didUpdateWidget
  /// 在父层回写（含钳制/改写）时同步。
  late double _lastCommitted;

  @override
  void initState() {
    super.initState();
    _draftValue = widget.value.clamp(widget.min, widget.max);
    _lastCommitted = _draftValue;
  }

  @override
  void didUpdateWidget(covariant CommitSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_dragging &&
        (widget.value != oldWidget.value ||
            widget.min != oldWidget.min ||
            widget.max != oldWidget.max)) {
      _draftValue = widget.value.clamp(widget.min, widget.max);
      _lastCommitted = _draftValue;
    }
  }

  @override
  Widget build(BuildContext context) {
    return _ThumbOnlySlider(
      value: _draftValue,
      min: widget.min,
      max: widget.max,
      divisions: widget.divisions,
      enabled: widget.enabled,
      activeColor: widget.activeColor,
      inactiveColor: widget.inactiveColor,
      labelBuilder: widget.labelBuilder,
      onChangeStart: widget.enabled ? (_) => _dragging = true : null,
      // onChanged 始终传入：_ThumbOnlySlider 在 !enabled 时不触发手势回调，
      // 因此禁用态下此处不会被调用。
      onChanged: (value) => setState(() => _draftValue = value),
      onChangeEnd: widget.enabled
          ? (value) {
              _dragging = false;
              if (value != _lastCommitted) {
                _lastCommitted = value;
                widget.onCommit(value);
              }
            }
          : null,
    );
  }
}

// ── 仅拖圆点的自绘滑块 ───────────────────────────────────────────────
// Flutter 原生 Slider 在轨道任意位置点击即跳值，会话设置页上下滑动时易误触。
// 此组件仅当水平拖动手势起始于圆点命中半径内时才更新数值；点击或从轨道起拖均为
// 空操作。命中半径沿用 Material overlay 量级，保证圆点易抓取。

const double _kTouchHeight = 36;
const double _kTrackHeight = 4;
const double _kThumbRadius = 7;
const double _kHitRadius = 24;
const double _kTrackPadding = _kThumbRadius;

class _ThumbOnlySlider extends StatefulWidget {
  const _ThumbOnlySlider({
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.divisions,
    this.enabled = true,
    this.activeColor,
    this.inactiveColor,
    this.labelBuilder,
    this.onChangeStart,
    this.onChangeEnd,
  });

  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;
  final int? divisions;
  final bool enabled;
  final Color? activeColor;
  final Color? inactiveColor;
  final String Function(double value)? labelBuilder;
  final ValueChanged<double>? onChangeStart;
  final ValueChanged<double>? onChangeEnd;

  @override
  State<_ThumbOnlySlider> createState() => _ThumbOnlySliderState();
}

class _ThumbOnlySliderState extends State<_ThumbOnlySlider> {
  bool _armed = false;
  bool _dragging = false;
  double _dragValue = 0;

  late final FocusNode _focusNode = FocusNode()
    ..addListener(_handleFocusChanged);
  bool _hasFocus = false;

  void _handleFocusChanged() {
    final hasFocus = _focusNode.hasFocus;
    if (hasFocus != _hasFocus) {
      setState(() => _hasFocus = hasFocus);
    }
  }

  @override
  void dispose() {
    _focusNode
      ..removeListener(_handleFocusChanged)
      ..dispose();
    super.dispose();
  }

  double get _span => widget.max - widget.min;

  double _thumbX(double width, double v) {
    final span = _span == 0 ? 1 : _span;
    final t = ((v - widget.min) / span).clamp(0.0, 1.0);
    return _kTrackPadding + t * (width - 2 * _kTrackPadding);
  }

  double _valueFromX(double x, double width) {
    final usable = width - 2 * _kTrackPadding;
    final t =
        usable <= 0 ? 0.0 : ((x - _kTrackPadding) / usable).clamp(0.0, 1.0);
    var v = widget.min + t * _span;
    final divisions = widget.divisions;
    if (divisions != null && _span > 0) {
      final step = _span / divisions;
      v = widget.min + ((v - widget.min) / step).round() * step;
    }
    return v.clamp(widget.min, widget.max);
  }

  double _stepSize() {
    if (widget.divisions != null && _span > 0) {
      return _span / widget.divisions!;
    }
    return _span > 0 ? _span / 100 : 1.0;
  }

  double _stepped(double base, int direction) =>
      (base + direction * _stepSize()).clamp(widget.min, widget.max);

  String _labelFor(double v) =>
      widget.labelBuilder?.call(v) ?? v.toStringAsFixed(2);

  void _semanticStep(int direction) {
    if (!widget.enabled) {
      return;
    }
    _commitValue(_stepped(widget.value, direction));
  }

  /// 走一遍完整提交流水线（onChangeStart → onChanged → onChangeEnd），
  /// 键盘步进与 a11y increase/decrease 同语义：立即落值并提交。
  void _commitValue(double v) {
    if (v == widget.value) {
      return;
    }
    widget.onChangeStart?.call(widget.value);
    widget.onChanged(v);
    widget.onChangeEnd?.call(v);
  }

  /// 键盘处理：方向键步进、Home/End 跳 min/max。
  /// 必须 handled 吃掉事件，否则框架方向焦点遍历会把焦点移走
  /// （探索实测焦点逃逸到主题选项的根因）。
  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (!widget.enabled) {
      return KeyEventResult.ignored;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowRight:
      case LogicalKeyboardKey.arrowUp:
        _semanticStep(1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowLeft:
      case LogicalKeyboardKey.arrowDown:
        _semanticStep(-1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.home:
        _commitValue(widget.min);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.end:
        _commitValue(widget.max);
        return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final alpha = widget.enabled ? 1.0 : 0.4;
    final active = (widget.activeColor ?? theme.colorScheme.primary)
        .withValues(alpha: alpha);
    final inactive =
        (widget.inactiveColor ?? theme.colorScheme.surfaceContainerHighest)
            .withValues(alpha: alpha);
    final displayValue = _dragging ? _dragValue : widget.value;

    return Semantics(
      container: true,
      slider: true,
      enabled: widget.enabled,
      value: _labelFor(displayValue),
      increasedValue: _labelFor(_stepped(displayValue, 1)),
      decreasedValue: _labelFor(_stepped(displayValue, -1)),
      onIncrease: () => _semanticStep(1),
      onDecrease: () => _semanticStep(-1),
      child: Focus(
        focusNode: _focusNode,
        canRequestFocus: widget.enabled,
        onKeyEvent: _handleKeyEvent,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            // Listener 不参与手势竞技场（TapGestureRecognizer 会干扰拖拽
            // 识别，见  测试二分）：仅借原始指针按下事件
            // 给滑块获焦
            return Listener(
              onPointerDown:
                  widget.enabled ? (_) => _focusNode.requestFocus() : null,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                // 纯点击轨道只获焦不跳值（DOC-14 §3.1 设计保留）
                onHorizontalDragStart: widget.enabled
                    ? (details) {
                        final thumbX = _thumbX(width, widget.value);
                        _armed = (details.localPosition.dx - thumbX).abs() <=
                            _kHitRadius;
                        if (!_armed) {
                          return;
                        }
                        _dragValue = widget.value;
                        _dragging = true;
                        widget.onChangeStart?.call(widget.value);
                        setState(() {});
                      }
                    : null,
                onHorizontalDragUpdate: widget.enabled
                    ? (details) {
                        if (!_armed) {
                          return;
                        }
                        _dragValue =
                            _valueFromX(details.localPosition.dx, width);
                        widget.onChanged(_dragValue);
                        setState(() {});
                      }
                    : null,
                onHorizontalDragEnd: widget.enabled
                    ? (_) {
                        if (!_armed) {
                          return;
                        }
                        final v = _dragValue;
                        _armed = false;
                        _dragging = false;
                        setState(() {});
                        widget.onChangeEnd?.call(v);
                      }
                    : null,
                child: SizedBox(
                  height: _kTouchHeight,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Positioned.fill(
                        child: CustomPaint(
                          painter: _SliderPainter(
                            value: displayValue,
                            min: widget.min,
                            max: widget.max,
                            trackPadding: _kTrackPadding,
                            trackHeight: _kTrackHeight,
                            thumbRadius: _kThumbRadius,
                            activeColor: active,
                            inactiveColor: inactive,
                            focused: _hasFocus,
                          ),
                        ),
                      ),
                      if (_dragging && widget.labelBuilder != null)
                        Positioned(
                          left: _thumbX(width, _dragValue).clamp(0.0, width),
                          top: 0,
                          child: FractionalTranslation(
                            translation: const Offset(-0.5, -1),
                            child: _DragLabel(
                              text: widget.labelBuilder!(_dragValue),
                              color: active,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _DragLabel extends StatelessWidget {
  const _DragLabel({
    required this.text,
    required this.color,
  });

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

class _SliderPainter extends CustomPainter {
  const _SliderPainter({
    required this.value,
    required this.min,
    required this.max,
    required this.trackPadding,
    required this.trackHeight,
    required this.thumbRadius,
    required this.activeColor,
    required this.inactiveColor,
    this.focused = false,
  });

  final double value;
  final double min;
  final double max;
  final double trackPadding;
  final double trackHeight;
  final double thumbRadius;
  final Color activeColor;
  final Color inactiveColor;

  /// 滑块持有键盘焦点时在圆点外画一圈光环（可达性）
  final bool focused;

  @override
  void paint(Canvas canvas, Size size) {
    final span = max - min;
    final t = span == 0 ? 0.0 : ((value - min) / span).clamp(0.0, 1.0);
    final usable = size.width - 2 * trackPadding;
    final thumbCenter = trackPadding + t * usable;
    final centerY = size.height / 2;
    final trackTop = centerY - trackHeight / 2;
    final trackRadius = trackHeight / 2;

    final inactiveRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, trackTop, size.width, trackHeight),
      Radius.circular(trackRadius),
    );
    canvas.drawRRect(inactiveRect, Paint()..color = inactiveColor);

    final activeWidth = thumbCenter;
    if (activeWidth > 0) {
      final activeRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(0, trackTop, activeWidth, trackHeight),
        Radius.circular(trackRadius),
      );
      canvas.drawRRect(activeRect, Paint()..color = activeColor);
    }

    canvas.drawCircle(
      Offset(thumbCenter, centerY),
      thumbRadius,
      Paint()..color = activeColor,
    );

    if (focused) {
      canvas.drawCircle(
        Offset(thumbCenter, centerY),
        thumbRadius + 4,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = activeColor.withValues(alpha: 0.45),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SliderPainter old) {
    return old.value != value ||
        old.min != min ||
        old.max != max ||
        old.activeColor != activeColor ||
        old.inactiveColor != inactiveColor ||
        old.trackPadding != trackPadding ||
        old.trackHeight != trackHeight ||
        old.thumbRadius != thumbRadius ||
        old.focused != focused;
  }
}
