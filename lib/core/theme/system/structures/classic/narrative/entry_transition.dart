import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';

/// 进入转场组件（DOC-06B §5.2）。
///
/// 从 Simple 模式切换到中级模式的转场，"耳目一新"的关键瞬间：
/// 阶段 1（0-200ms）：surface/ink 淡入（ease-out-quart）
/// 阶段 2（300-500ms）：primary 琥珀金"点灯"淡入（ease-out-quint）
///
/// 背景始终为夜航 bg（colors.bg），不做透明渐变，避免 release 模式下
/// 首帧透明导致底层浅色页面透出形成白屏闪烁。
///
/// reduced-motion 备选：disableAnimations（OS 减弱动态
/// 效果）与 accessibleNavigation 任一为 true 即瞬时切换无过渡。
class EntryTransition extends StatefulWidget {
  const EntryTransition({
    required this.child,
    super.key,
  });

  final Widget child;

  @override
  State<EntryTransition> createState() => _EntryTransitionState();
}

class _EntryTransitionState extends State<EntryTransition>
    with TickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _contentAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: LmMotion.transition,
      vsync: this,
    );

    // 内容淡入（0-400ms，ease-out-quart）
    // 琥珀金"点灯"效果通过内容淡入自然体现（primary 元素随内容一起淡入）
    _contentAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0, 0.8, curve: _EaseOutQuart()),
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // reduced-motion：瞬时切换，无过渡（两条件取或）
    if (LmMotion.reducedMotion(context)) {
      return widget.child;
    }

    // 首次构建时启动动画
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _controller.status == AnimationStatus.dismissed) {
        _controller.forward();
      }
    });

    final colors = context.lm.palette;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return ColoredBox(
          color: colors.bg,
          child: Opacity(
            opacity: _contentAnimation.value,
            child: child,
          ),
        );
      },
      child: widget.child,
    );
  }
}

/// ease-out-quart 曲线：1 - (1-t)^4
class _EaseOutQuart extends Curve {
  const _EaseOutQuart();

  @override
  double transformInternal(double t) {
    return 1 - (1 - t) * (1 - t) * (1 - t) * (1 - t);
  }
}
