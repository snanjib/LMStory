import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
// =============================================================================
// Message avatar
// （从 simple_message_bubble.dart 拆出，主文件装配引用）
// =============================================================================

class BubbleMessageAvatar extends StatefulWidget {
  const BubbleMessageAvatar({
    required this.isUser,
    required this.colors,
    super.key,
    this.isGenerating = false,
  });

  final bool isUser;
  final LmPalette colors;
  final bool isGenerating;

  @override
  State<BubbleMessageAvatar> createState() => _BubbleMessageAvatarState();
}

class _BubbleMessageAvatarState extends State<BubbleMessageAvatar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _rotationController;

  @override
  void initState() {
    super.initState();
    _rotationController = AnimationController(
      vsync: this,
      duration: LmMotion.breathe,
    );
  }

  ///  reduced-motion：减弱动态下不启动旋转循环（生成中也不转）。
  bool _shouldSpin(BuildContext context) =>
      widget.isGenerating && LmMotion.shouldAnimate(context);

  void _syncSpin() {
    if (_shouldSpin(context)) {
      if (!_rotationController.isAnimating) _rotationController.repeat();
    } else if (_rotationController.isAnimating) {
      _rotationController.stop();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncSpin();
  }

  @override
  void didUpdateWidget(BubbleMessageAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isGenerating != oldWidget.isGenerating) {
      _syncSpin();
    }
  }

  @override
  void dispose() {
    _rotationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final spinning = _shouldSpin(context);
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color:
            widget.isUser ? widget.colors.primaryDim : widget.colors.accentDim,
        shape: BoxShape.circle,
      ),
      child: spinning && !widget.isUser
          ? RotationTransition(
              turns: _rotationController,
              child: Icon(
                Icons.refresh_rounded,
                size: 18,
                color: widget.colors.accent,
              ),
            )
          : Icon(
              widget.isUser ? Icons.person : Icons.smart_toy_outlined,
              size: 18,
              color:
                  widget.isUser ? widget.colors.primary : widget.colors.accent,
            ),
    );
  }
}
