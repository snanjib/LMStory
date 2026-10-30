import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/shared/components/lm_activity_dots.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
// =============================================================================
// 从 simple_message_bubble.dart 拆出的共享指示器：
// 内容区与压缩摘要卡都引用这两个流式指示组件，放最低层共享文件
// （子文件之间单向依赖，禁止回 import 主文件）。
// =============================================================================

/// Blinking cursor shown at the end of an assistant message while streaming.
/// Uses the accent colour with a smooth fade-in / fade-out cycle.
class BubbleStreamingCursor extends StatefulWidget {
  const BubbleStreamingCursor({super.key});

  @override
  State<BubbleStreamingCursor> createState() => _BubbleStreamingCursorState();
}

class _BubbleStreamingCursorState extends State<BubbleStreamingCursor>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: LmMotion.blink,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    //  reduced-motion：减弱动态下**不启动**循环闪烁（不是启动后再停），
    // 光标直接落在恒亮终态。
    if (LmMotion.shouldAnimate(context)) {
      if (!_controller.isAnimating) _controller.repeat(reverse: true);
    } else {
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
    final colors = context.lm.palette;
    final cursor = Container(
      width: 1.5,
      height: 14,
      margin: const EdgeInsets.only(left: 2),
      decoration: BoxDecoration(
        color: colors.accent,
        borderRadius: BorderRadius.circular(1),
      ),
    );
    if (!LmMotion.shouldAnimate(context)) return cursor;
    return FadeTransition(opacity: _controller, child: cursor);
  }
}

// =============================================================================
// Bouncing dots indicator (waiting for first token)
// =============================================================================

/// Three bouncing dots shown while waiting for the first token from the LLM.
///
/// Reference: ChatBox's loading indicator — dots bounce in sequence with a
/// staggered delay, using the accent colour. Shown when the assistant message
/// is empty and streaming has started but no content has arrived yet.
class BubbleBouncingDotsIndicator extends StatelessWidget {
  const BubbleBouncingDotsIndicator({required this.colors, super.key});

  final LmPalette colors;

  @override
  Widget build(BuildContext context) => LmActivityDots(color: colors.accent);
}
