import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// Floating navigation buttons for jumping between user messages.
///
/// Reference: ChatBox's MessageNavigation.tsx — provides jump-to-top,
/// previous/next user message, and jump-to-bottom buttons.
class SimpleMessageNavigation extends StatefulWidget {
  const SimpleMessageNavigation({
    required this.onJumpToTop,
    required this.onJumpToBottom,
    required this.onPrevUserMessage,
    required this.onNextUserMessage,
    required this.visible,
    super.key,
  });

  /// Callback when the user taps "jump to top".
  final VoidCallback onJumpToTop;

  /// Callback when the user taps "jump to bottom".
  final VoidCallback onJumpToBottom;

  /// Callback when the user taps "previous user message".
  final VoidCallback onPrevUserMessage;

  /// Callback when the user taps "next user message".
  final VoidCallback onNextUserMessage;

  /// Whether the navigation panel is visible.
  final bool visible;

  @override
  State<SimpleMessageNavigation> createState() =>
      _SimpleMessageNavigationState();
}

class _SimpleMessageNavigationState extends State<SimpleMessageNavigation> {
  bool _isHovered = false;
  bool _keepVisible = false;

  /// Whether the navigation should actually be shown.
  /// On desktop: always visible when the parent's `visible` prop is true.
  /// On mobile: visible when scrolled up (controlled by the `visible` prop).
  bool get _shouldShow => widget.visible || _isHovered || _keepVisible;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) {
        setState(() => _isHovered = false);
        if (_keepVisible) {
          Future.delayed(const Duration(seconds: 2), () {
            if (mounted && !_isHovered) {
              setState(() => _keepVisible = false);
            }
          });
        }
      },
      child: GestureDetector(
        onLongPressStart: (_) => setState(() => _keepVisible = true),
        onLongPressEnd: (_) {
          Future.delayed(const Duration(seconds: 2), () {
            if (mounted) setState(() => _keepVisible = false);
          });
        },
        child: AnimatedOpacity(
          // 降低不透明度到 0.85，避免遮挡阅读
          opacity: _shouldShow ? 0.85 : 0.0,
          duration: LmMotion.base,
          child: AnimatedSlide(
            offset: _shouldShow ? Offset.zero : const Offset(0.5, 0),
            duration: LmMotion.base,
            curve: LmMotion.easeStandard,
            child: IgnorePointer(
              ignoring: !_shouldShow,
              child: Container(
                // 变窄：减小内边距
                padding: const EdgeInsets.only(
                  right: LmSpacing.s2xs,
                  bottom: LmSpacing.sXs,
                ),
                decoration: BoxDecoration(
                  color: colors.surfaceElevated,
                  borderRadius:
                      BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
                  border: Border.all(
                    color: colors.divider,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.06),
                      blurRadius: 4,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _NavigationButton(
                      icon: Icons.keyboard_double_arrow_up,
                      tooltip: t.chat.navigation.jumpToTop,
                      onTap: widget.onJumpToTop,
                      colors: colors,
                    ),
                    Divider(
                      height: 1,
                      thickness: 1,
                      color: colors.divider,
                      indent: LmSpacing.s2xs,
                      endIndent: LmSpacing.s2xs,
                    ),
                    _NavigationButton(
                      icon: Icons.keyboard_arrow_up,
                      tooltip: t.chat.navigation.prevUserMessage,
                      onTap: widget.onPrevUserMessage,
                      colors: colors,
                    ),
                    Divider(
                      height: 1,
                      thickness: 1,
                      color: colors.divider,
                      indent: LmSpacing.s2xs,
                      endIndent: LmSpacing.s2xs,
                    ),
                    _NavigationButton(
                      icon: Icons.keyboard_arrow_down,
                      tooltip: t.chat.navigation.nextUserMessage,
                      onTap: widget.onNextUserMessage,
                      colors: colors,
                    ),
                    Divider(
                      height: 1,
                      thickness: 1,
                      color: colors.divider,
                      indent: LmSpacing.s2xs,
                      endIndent: LmSpacing.s2xs,
                    ),
                    _NavigationButton(
                      icon: Icons.keyboard_double_arrow_down,
                      tooltip: t.chat.navigation.jumpToBottom,
                      onTap: widget.onJumpToBottom,
                      colors: colors,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavigationButton extends StatelessWidget {
  const _NavigationButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    required this.colors,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final LmPalette colors;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
        child: Padding(
          // 变窄：从 sLg(16px) 减小到 sSm(8px)，保持 40x40 触控目标
          padding: const EdgeInsets.all(LmSpacing.sSm),
          child: Icon(
            icon,
            size: 16,
            color: colors.muted,
          ),
        ),
      ),
    );
  }
}
