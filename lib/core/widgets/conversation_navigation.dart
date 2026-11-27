import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:lmstory/core/theme/api/lm_component_kit.dart';

/// Keeps reading shortcuts independent of programmatic layout and live following.
class ConversationNavigation extends StatefulWidget {
  const ConversationNavigation({
    required this.controller,
    required this.child,
    required this.onTop,
    required this.onBottom,
    required this.canJumpRound,
    required this.jumpRound,
    this.onUserScroll,
    this.hasReadingTail,
    this.narrative = false,
    super.key,
  });

  final ScrollController controller;
  final Widget child;
  final VoidCallback onTop;
  final VoidCallback onBottom;
  final bool Function({required bool forward}) canJumpRound;
  final void Function({required bool forward}) jumpRound;
  final VoidCallback? onUserScroll;
  final bool Function()? hasReadingTail;
  final bool narrative;

  @override
  State<ConversationNavigation> createState() => _ConversationNavigationState();
}

typedef _Targets = ({
  bool scrollable,
  bool top,
  bool bottom,
  bool previous,
  bool next
});

class _ConversationNavigationState extends State<ConversationNavigation> {
  static const _idleDelay = Duration(seconds: 3);
  static const _empty = (
    scrollable: false,
    top: false,
    bottom: false,
    previous: false,
    next: false
  );
  _Targets _targets = _empty;
  Timer? _idle;
  bool _expanded = false;
  bool _hasBrowsed = false;
  bool _userSequence = false;
  bool _moved = false;
  bool _focus = false;
  bool _accessibilityFocus = false;
  bool _refreshPending = false;

  void _refreshAfterLayout() {
    if (_refreshPending) return;
    _refreshPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshPending = false;
      if (!mounted) return;
      final controller = widget.controller;
      var targets = _empty;
      if (controller.hasClients && controller.position.hasContentDimensions) {
        final p = controller.position;
        final away =
            p.extentAfter > 2 || (widget.hasReadingTail?.call() ?? false);
        targets = (
          scrollable: p.maxScrollExtent - p.minScrollExtent > 1 || away,
          top: p.extentBefore > 1,
          bottom: away,
          previous: _expanded && widget.canJumpRound(forward: false),
          next: _expanded && widget.canJumpRound(forward: true),
        );
      }
      if (targets != _targets) setState(() => _targets = targets);
    });
  }

  bool _scroll(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    _refreshAfterLayout();
    if ((notification is UserScrollNotification &&
            notification.direction != ScrollDirection.idle) ||
        (notification is ScrollStartNotification &&
            notification.dragDetails != null)) {
      _userSequence = true;
    }
    if (notification is ScrollUpdateNotification &&
        (notification.dragDetails != null || _userSequence) &&
        (notification.scrollDelta ?? 0) != 0) {
      if (!_moved) widget.onUserScroll?.call();
      _moved = true;
      _hasBrowsed = true;
      _idle?.cancel();
      if (!_expanded) setState(() => _expanded = true);
    }
    if (notification is ScrollEndNotification ||
        (notification is UserScrollNotification &&
            notification.direction == ScrollDirection.idle)) {
      if (_moved) _restartIdle();
      _userSequence = false;
      _moved = false;
    }
    return false;
  }

  void _restartIdle() {
    _idle?.cancel();
    if (!_expanded || _focus || _accessibilityFocus) return;
    _idle = Timer(_idleDelay, () {
      if (mounted) setState(() => _expanded = false);
    });
  }

  void _act(VoidCallback action) {
    _userSequence = false;
    _moved = false;
    action();
    _restartIdle();
    _refreshAfterLayout();
  }

  @override
  void dispose() {
    _idle?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _refreshAfterLayout();
    return LayoutBuilder(
      builder: (context, constraints) {
        return Stack(
          fit: StackFit.expand,
          children: [
            NotificationListener<ScrollMetricsNotification>(
              onNotification: (n) {
                if (n.depth == 0) _refreshAfterLayout();
                return false;
              },
              child: NotificationListener<ScrollNotification>(
                onNotification: _scroll,
                child: widget.child,
              ),
            ),
            Positioned(
              bottom: 8,
              right: 8,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: math.max(0, constraints.maxHeight - 16),
                ),
                child: Focus(
                  canRequestFocus: false,
                  onFocusChange: (value) {
                    _focus = value;
                    _restartIdle();
                  },
                  child: context.lmUi.messageNavigation(
                    context,
                    narrative: widget.narrative,
                    visible: _targets.scrollable && _expanded,
                    compact: _hasBrowsed && !_expanded && _targets.bottom,
                    onJumpToTop: _targets.top ? () => _act(widget.onTop) : null,
                    onJumpToBottom:
                        _targets.bottom ? () => _act(widget.onBottom) : null,
                    onPrevUserMessage: _targets.previous
                        ? () => _act(() => widget.jumpRound(forward: false))
                        : null,
                    onNextUserMessage: _targets.next
                        ? () => _act(() => widget.jumpRound(forward: true))
                        : null,
                    onAccessibilityFocus: (value) {
                      _accessibilityFocus = value;
                      _restartIdle();
                    },
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
