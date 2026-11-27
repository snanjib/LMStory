import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// Conversation shortcuts that fold into the bottom button at the same position.
class SimpleMessageNavigation extends StatelessWidget {
  const SimpleMessageNavigation({
    required this.onJumpToTop,
    required this.onPrevUserMessage,
    required this.onNextUserMessage,
    required this.onJumpToBottom,
    required this.visible,
    this.compact = false,
    this.onAccessibilityFocus,
    super.key,
  });

  final VoidCallback? onJumpToTop;
  final VoidCallback? onPrevUserMessage;
  final VoidCallback? onNextUserMessage;
  final VoidCallback? onJumpToBottom;
  final ValueChanged<bool>? onAccessibilityFocus;
  final bool visible;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    final reduced = MediaQuery.disableAnimationsOf(context);
    final highContrast = MediaQuery.highContrastOf(context);
    final show = visible || compact;
    final actions = [
      (
        Icons.keyboard_double_arrow_up,
        t.chat.navigation.jumpToTop,
        onJumpToTop
      ),
      (
        Icons.keyboard_arrow_up,
        t.chat.navigation.prevUserMessage,
        onPrevUserMessage
      ),
      (
        Icons.keyboard_arrow_down,
        t.chat.navigation.nextUserMessage,
        onNextUserMessage
      ),
      (
        Icons.keyboard_double_arrow_down,
        compact ? t.chat.scrollToLatest : t.chat.navigation.jumpToBottom,
        onJumpToBottom
      ),
    ];
    const side = kMinInteractiveDimension;
    const railWidth = 32.0;
    const railInset = (side - railWidth) / 2;
    final railDecoration = BoxDecoration(
      color: highContrast
          ? colors.surfaceElevated
          : colors.surfaceElevated.withValues(alpha: .6),
      borderRadius: BorderRadius.circular(railWidth / 2),
      border: Border.all(
        color: highContrast
            ? colors.dividerStrong
            : colors.divider.withValues(alpha: .5),
      ),
    );
    return IgnorePointer(
      ignoring: !show,
      child: ExcludeSemantics(
        excluding: !show,
        child: ExcludeFocus(
          excluding: !show,
          child: AnimatedOpacity(
            opacity: show ? 1 : 0,
            duration: LmMotion.micro,
            child: LayoutBuilder(
              builder: (context, constraints) {
                // The landscape keyboard can leave less than four targets of height.
                final horizontal =
                    constraints.maxHeight < actions.length * side;
                return TweenAnimationBuilder<double>(
                  tween: Tween<double>(end: visible ? 1 : 0),
                  duration: reduced ? LmMotion.micro : LmMotion.base,
                  builder: (context, openness, _) {
                    final progress = reduced ? (visible ? 1.0 : 0.0) : openness;
                    final length =
                        railWidth + (actions.length - 1) * side * progress;
                    return SizedBox(
                      width: horizontal ? 4 * side : side,
                      height: horizontal ? side : 4 * side,
                      child: Stack(
                        alignment: Alignment.bottomRight,
                        children: [
                          Positioned(
                            bottom: railInset,
                            right: railInset,
                            child: IgnorePointer(
                              child: Container(
                                width: horizontal ? length : railWidth,
                                height: horizontal ? railWidth : length,
                                decoration: railDecoration,
                              ),
                            ),
                          ),
                          for (var i = 0; i < actions.length; i++)
                            Positioned(
                              bottom: horizontal ? 0 : (3 - i) * side,
                              right: horizontal ? (3 - i) * side : 0,
                              child: _NavigationButton(
                                action: actions[i],
                                index: i,
                                openness: openness,
                                horizontal: horizontal,
                                reduced: reduced,
                                visible: visible,
                                compact: compact,
                                onAccessibilityFocus: onAccessibilityFocus,
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _NavigationButton extends StatelessWidget {
  const _NavigationButton({
    required this.action,
    required this.index,
    required this.openness,
    required this.horizontal,
    required this.reduced,
    required this.visible,
    required this.compact,
    required this.onAccessibilityFocus,
  });

  final (IconData, String, VoidCallback?) action;
  final int index;
  final double openness;
  final bool horizontal;
  final bool reduced;
  final bool visible;
  final bool compact;
  final ValueChanged<bool>? onAccessibilityFocus;

  @override
  Widget build(BuildContext context) {
    final (icon, label, onPressed) = action;
    final bottom = index == 3;
    final hidden = !visible && !bottom;
    final phase =
        ((openness - (2 - index).clamp(0, 2) * .07) / .86).clamp(0.0, 1.0);
    // Only the glyph travels. The four 48 dp hit targets never overlap.
    final shift = reduced
        ? 0.0
        : bottom
            ? 2 * math.sin(openness * math.pi * 2)
            : kMinInteractiveDimension *
                (3 - index) *
                (1 - LmMotion.easeBoth.transform(phase));
    final colors = context.lm.palette;
    return IgnorePointer(
      ignoring: hidden,
      child: ExcludeSemantics(
        excluding: hidden,
        child: ExcludeFocus(
          excluding: hidden,
          child: MergeSemantics(
            child: Semantics(
              onDidGainAccessibilityFocus: () =>
                  onAccessibilityFocus?.call(true),
              onDidLoseAccessibilityFocus: () =>
                  onAccessibilityFocus?.call(false),
              child: SizedBox.square(
                dimension: kMinInteractiveDimension,
                child: Material(
                  type: MaterialType.transparency,
                  child: IconButton(
                    tooltip: label,
                    onPressed: onPressed,
                    padding: EdgeInsets.zero,
                    color: bottom && compact ? colors.primary : colors.ink,
                    icon: Transform.translate(
                      transformHitTests: false,
                      offset: horizontal ? Offset(shift, 0) : Offset(0, shift),
                      child: Opacity(
                        opacity: bottom ? 1 : phase,
                        child: Icon(icon, size: bottom ? 22 : 20),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
