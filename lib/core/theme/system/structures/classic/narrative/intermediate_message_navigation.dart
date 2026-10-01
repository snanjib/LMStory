import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 故事模式浮动导航按钮（夜航主题）。
///
/// 对标 Simple 模式的 SimpleMessageNavigation，提供跳到顶部、上一条用户消息、
/// 下一条用户消息、跳到底部 4 个按钮。使用夜航主题色彩（surfaceElevated 底 +
/// muted 图标），与故事模式整体视觉语言一致。
///
/// 自动隐藏逻辑：滑动时由父组件控制 [visible] 显示，停止 2 秒后自动隐藏。
/// 桌面端鼠标 hover 保持可见，移动端长按保持可见。
class IntermediateMessageNavigation extends StatefulWidget {
  const IntermediateMessageNavigation({
    required this.onJumpToTop,
    required this.onJumpToBottom,
    required this.onPrevUserMessage,
    required this.onNextUserMessage,
    required this.visible,
    super.key,
  });

  /// 点击"跳到顶部"回调。
  final VoidCallback onJumpToTop;

  /// 点击"跳到底部"回调。
  final VoidCallback onJumpToBottom;

  /// 点击"上一条用户消息"回调。
  final VoidCallback onPrevUserMessage;

  /// 点击"下一条用户消息"回调。
  final VoidCallback onNextUserMessage;

  /// 是否可见（由父组件根据滚动状态控制）。
  final bool visible;

  @override
  State<IntermediateMessageNavigation> createState() =>
      _IntermediateMessageNavigationState();
}

class _IntermediateMessageNavigationState
    extends State<IntermediateMessageNavigation> {
  bool _isHovered = false;
  bool _keepVisible = false;

  /// 实际是否显示。
  /// 桌面端：鼠标 hover 时显示。移动端：长按时保持显示。
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
                padding: const EdgeInsets.only(
                  right: LmSpacing.s2xs,
                  bottom: LmSpacing.sXs,
                ),
                decoration: BoxDecoration(
                  color: colors.surfaceElevated,
                  borderRadius:
                      BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
                  border: Border.all(color: colors.divider),
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
          padding: const EdgeInsets.all(LmSpacing.sSm),
          child: Icon(icon, size: 16, color: colors.muted),
        ),
      ),
    );
  }
}
