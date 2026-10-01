import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';

/// 呼吸点指示器：用于侧边栏会话项标记"正在生成"状态。
///
/// 设计要点（impeccable 规范）：
/// - 8px 直径，使用 `context.lm.palette` 的 primary 槽（与侧边栏主题色一致）
/// - Opacity 动画 0.4 → 1.0 → 0.4，1.5s 周期，easeInOut 曲线（breathing 效果）
/// - Reduced-motion 非可选：`disableAnimations` 或
///   `accessibleNavigation` 任一为 true 时
///   静态渲染 0.7 opacity，不启动 AnimationController
/// - 不使用 bounce/elastic 曲线
///
/// 取色走语义色槽而非模式私有色类：侧边栏在三模式共用，
/// 会话项不区分 Simple/Intermediate 模式视觉表现。
class BreathingDot extends StatefulWidget {
  const BreathingDot({
    this.size = 8.0,
    super.key,
  });

  /// 圆点直径（px），默认 8
  final double size;

  @override
  State<BreathingDot> createState() => _BreathingDotState();
}

class _BreathingDotState extends State<BreathingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: LmMotion.breathe,
      vsync: this,
    );
    _opacity = Tween<double>(begin: 0.4, end: 1).animate(
      CurvedAnimation(parent: _controller, curve: LmMotion.easeBoth),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    // 减弱动效：accessibleNavigation 为 true 时静态渲染（impeccable: reduced motion 非可选）
    // 与 failure_bar.dart 使用同一 API 保持一致
    final reducedMotion = LmMotion.reducedMotion(context);

    if (reducedMotion) {
      return _Dot(
        size: widget.size,
        color: colors.primary,
        opacity: 0.7,
      );
    }

    // 启动动画（若尚未运行）——放在 build 中以确保 rebuild 后仍运行
    if (!_controller.isAnimating) {
      _controller.repeat(reverse: true);
    }

    return AnimatedBuilder(
      animation: _opacity,
      builder: (context, _) {
        return _Dot(
          size: widget.size,
          color: colors.primary,
          opacity: _opacity.value,
        );
      },
    );
  }
}

/// 静态圆点渲染（分离出 StatelessWidget 以便 reduced-motion 分支复用）
class _Dot extends StatelessWidget {
  const _Dot({
    required this.size,
    required this.color,
    required this.opacity,
  });

  final double size;
  final Color color;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: opacity,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}
