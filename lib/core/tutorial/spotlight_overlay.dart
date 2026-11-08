import 'package:flutter/foundation.dart' show ValueListenable, listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show BoxHitTestResult, RenderProxyBox;
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/tutorial/spotlight_registry.dart';
import 'package:lmstory/core/tutorial/tutorial_controller.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 教程控制器 Provider（根作用域缺省 null=无教程活动）。
/// 演示作用域经 overrideWithValue 注入桥内控制器。
final tutorialControllerProvider = Provider<TutorialController?>((ref) => null);

/// Spotlight 遮罩宿主：挂 MaterialApp.builder 内，包住整个 Navigator
/// （对路由、弹窗、底部面板统一遮罩）。
///
/// 职责（通用能力，零业务语义）：
/// - 活动步骤时渲染暗化遮罩+目标挖孔（Rect 来自注册表）；
/// - 挖孔区命中穿透（用户亲自操作目标），遮罩区吸收指针；
///   系统返回不被吞（遮罩不参与 PopScope 拦截）；
/// - 目标缺失 → 居中等待卡（不静默跳步）；
/// - 活动期逐帧刷新目标 Rect（滚动/键盘/窗口/动画位移兜底）；
/// - 主题色板、减弱动态（禁渐隐与呼吸描边）、Semantics 标注。
class SpotlightOverlayHost extends ConsumerStatefulWidget {
  const SpotlightOverlayHost({
    required this.child,
    this.modalPresence,
    super.key,
  });

  final Widget child;

  /// 模态路由在栈计数（null=不感知；>0 时遮罩抬起，模态可自由交互）
  final ValueListenable<int>? modalPresence;

  @override
  ConsumerState<SpotlightOverlayHost> createState() =>
      _SpotlightOverlayHostState();
}

class _SpotlightOverlayHostState extends ConsumerState<SpotlightOverlayHost>
    with WidgetsBindingObserver {
  bool _loopScheduled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _loopScheduled = false;
    super.dispose();
  }

  @override
  Future<bool> didPopRoute() async {
    final nav = Navigator.maybeOf(context);
    if (nav != null && nav.canPop()) {
      nav.pop();
      return true;
    }
    final controller = ref.read(tutorialControllerProvider);
    if (controller != null && controller.active && !controller.exitRequestOpen) {
      controller.requestExit();
      return true;
    }
    return false;
  }

  void _ensureFrameLoop() {
    if (_loopScheduled) return;
    _loopScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _loopScheduled = false;
      if (!mounted) return;
      try {
        final controller = ref.read(tutorialControllerProvider);
        if (controller != null && controller.active) {
          ref.read(spotlightRegistryProvider).refreshReporters();
          _ensureFrameLoop();
        }
      } catch (_) {}
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(tutorialControllerProvider);
    if (controller == null) {
      return widget.child;
    }
    final presence = widget.modalPresence;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        if (!controller.active) {
          return widget.child;
        }
        _ensureFrameLoop();
        final registry = ref.read(spotlightRegistryProvider);
        // 同时监听注册表：目标注册/位移时挖孔即时跟随；
        // 模态（对话框/sheet）在栈时遮罩抬起——模态是当前操作面
        return ListenableBuilder(
          listenable: Listenable.merge(<Listenable?>[
            registry,
            presence,
          ]),
          builder: (context, _) {
            final modalOpen = presence?.value ?? 0;
            // 退出确认弹窗展示中：遮罩抬起，让用户正常与确认框交互
            if (controller.exitRequestOpen) {
              return _DirectionalitySafe(child: widget.child);
            }
            // 模态浮层在栈时：
            // 若当前目标处于当前活动顶层路由（targetMeta.isCurrentRoute），
            // 遮罩正常渲染并高亮目标（如会话设置面板内的「查看记忆库」按钮，或其上推入的记忆库页）；
            // 否则（浮层内无目标，或当前目标在浮层底下的背景页，如模型选择器覆盖向导页），
            // 遮罩抬起放行浮层交互，避免阻断用户操作。
            final targetId =
                controller.current?.resolveTargetId(registry.isRegistered);
            final targetMeta =
                targetId == null ? null : registry.metaOf(targetId);
            if (modalOpen > 0) {
              final targetOnCurrentRoute =
                  targetMeta != null && targetMeta.isCurrentRoute;
              if (!targetOnCurrentRoute) {
                return _DirectionalitySafe(child: widget.child);
              }
            }
            return _DirectionalitySafe(
              child: PopScope(
                canPop: false,
                onPopInvokedWithResult: (didPop, _) {
                  if (didPop) return;
                  controller.requestExit();
                },
                child: Stack(
                  children: [
                    Positioned.fill(child: widget.child),
                    Positioned.fill(
                      child: _SpotlightLayer(
                        controller: controller,
                        registry: registry,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// MaterialApp.builder 内可能尚未继承 Directionality 的兜底
/// （遮罩层纯定位布局需要确定文本方向）。
class _DirectionalitySafe extends StatelessWidget {
  const _DirectionalitySafe({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final dir = Directionality.maybeOf(context);
    if (dir != null) return child;
    return Directionality(textDirection: TextDirection.ltr, child: child);
  }
}

class _SpotlightLayer extends StatelessWidget {
  const _SpotlightLayer({required this.controller, required this.registry});

  final TutorialController controller;
  final SpotlightRegistry registry;

  static const double _holePadding = 8;
  static const double _bubbleMaxWidth = 320;
  static const double _screenMargin = 16;
  static const double _bubbleTopClamp = 140;

  @override
  Widget build(BuildContext context) {
    final step = controller.current!;
    final media = MediaQuery.of(context);
    final reduceMotion = media.disableAnimations || media.accessibleNavigation;
    final screenSize = media.size;

    final targetId = step.resolveTargetId((id) => registry.rectOf(id) != null);
    final targetRect = targetId == null ? null : registry.rectOf(targetId);
    final waiting = targetId != null && targetRect == null;

    final dark = Theme.of(context).brightness == Brightness.dark;
    // 遮罩透明度调优（问题 4）：dark 0.45、light 0.30，保证底层文本清晰可读
    final barrierColor =
        dark ? const Color(0x73000000) : const Color(0x4D000000);
    final passThroughRect = step.passThroughTargetId == null
        ? null
        : registry.rectOf(step.passThroughTargetId!);

    // 放行区（如会话滚动区）在无独立目标时亦参与挖孔，保证主浏览区明亮不遮蔽
    final primaryHole = targetRect?.inflate(_holePadding) ?? passThroughRect;
    final holes = <Rect>[];
    if (primaryHole != null) {
      holes.add(primaryHole);
    }
    for (final extraId in step.extraHighlightTargetIds) {
      final extraRect = registry.rectOf(extraId);
      if (extraRect != null) {
        final extraHole = extraRect.inflate(_holePadding);
        if (!holes.contains(extraHole)) {
          holes.add(extraHole);
        }
      }
    }

    return Stack(
      children: [
        // 遮罩+挖孔：挖孔命中穿透；介绍步全放行；**等待态全放行**——
        // 目标缺失时用户需要自由操作底层 UI 把目标带出来（如点真实
        // 「下一步」翻页），全屏吸收会造成死锁；局部交互放行区（会话滚动）穿透
        Positioned.fill(
          child: _HoleBarrier(
            holes: holes,
            passThroughRect: passThroughRect,
            passThrough: step.allowUntargetedTaps || waiting,
            child: CustomPaint(
              painter: _MaskPainter(
                holes: holes,
                barrierColor: barrierColor,
                outline: !reduceMotion && !waiting,
              ),
              size: screenSize,
            ),
          ),
        ),
        if (waiting)
          Align(
            child: _WaitingCard(onExit: controller.requestExit),
          )
        else
          _positionedBubble(context, step, targetRect, screenSize),
      ],
    );
  }

  Widget _positionedBubble(
    BuildContext context,
    TutorialStep step,
    Rect? targetRect,
    Size screenSize,
  ) {
    final bubble = _StepBubble(step: step, controller: controller);

    if (targetRect == null) {
      if (step.passThroughTargetId != null) {
        // 放行交互步（如导演工作中）：气泡贴底悬浮（停在已禁用的输入栏上方），
        // 绝不遮挡主视口正文与思考展开
        return Positioned(
          left: _screenMargin,
          right: _screenMargin,
          bottom: 16,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _bubbleMaxWidth),
              child: bubble,
            ),
          ),
        );
      }
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: bubble,
        ),
      );
    }

    final spaceBelow = screenSize.height - targetRect.bottom;
    final below = spaceBelow >= 180 || spaceBelow >= targetRect.top;
    final top = below
        ? targetRect.bottom + 12
        : (targetRect.top - 190).clamp(_screenMargin, double.infinity);
    final left = (targetRect.center.dx - _bubbleMaxWidth / 2).clamp(
      _screenMargin,
      (screenSize.width - _bubbleMaxWidth - _screenMargin)
          .clamp(_screenMargin, double.infinity),
    );
    return Positioned(
      top: top.clamp(_screenMargin, screenSize.height - _bubbleTopClamp),
      left: left,
      child: bubble,
    );
  }
}

/// 步骤气泡（标题/正文/退出/可选跳过/可选确认）
class _StepBubble extends StatelessWidget {
  const _StepBubble({required this.step, required this.controller});

  final TutorialStep step;
  final TutorialController controller;

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320),
      child: Material(
        elevation: 6,
        borderRadius: BorderRadius.circular(12),
        color: cs.surface,
        surfaceTintColor: cs.surfaceTint,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(
                header: true,
                child: Text(step.title, style: text.titleSmall),
              ),
              const SizedBox(height: 6),
              Flexible(
                child: SingleChildScrollView(
                  child: Text(
                    step.message,
                    style: text.bodyMedium,
                    semanticsLabel: '${step.title}。${step.message}',
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  TextButton(
                    // 请求退出（不终止教程）——宿主确认后按选择处置；
                    // 「继续体验」经 cancelExit 原地恢复
                    onPressed: controller.requestExit,
                    child: Text(t.tutorial.exit),
                  ),
                  const Spacer(),
                  if (step.skippable)
                    TextButton(
                      onPressed: controller.skipCurrent,
                      child: Text(t.tutorial.skip),
                    ),
                  if (step.confirmLabel != null)
                    FilledButton(
                      // 提供 confirmLabel 的步骤确认即可点（末步 next=
                      // 结束回调→交接）。业务推进步骤不设 confirmLabel，
                      // 由步骤条件驱动——此处无例外分支。
                      onPressed: controller.next,
                      child: Text(step.confirmLabel!),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 目标缺失等待卡（必需步骤不静默跳过）
class _WaitingCard extends StatelessWidget {
  const _WaitingCard({this.onExit});

  final VoidCallback? onExit;

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final cs = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320),
      child: Material(
        elevation: 6,
        borderRadius: BorderRadius.circular(12),
        color: cs.surface,
        surfaceTintColor: cs.surfaceTint,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                t.tutorial.waitingTitle,
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 6),
              Text(t.tutorial.waitingMessage),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => onExit?.call(),
                  child: Text(t.tutorial.exit),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 遮罩屏障：挖孔区命中穿透（用户真实操作目标），其余吸收误触。
class _HoleBarrier extends SingleChildRenderObjectWidget {
  const _HoleBarrier({
    required this.holes,
    required this.passThrough,
    this.passThroughRect,
    super.child,
  });

  final List<Rect> holes;
  final Rect? passThroughRect;

  /// true=介绍性步骤：全屏放行自由操作
  final bool passThrough;

  @override
  RenderProxyBox createRenderObject(BuildContext context) {
    return _RenderHoleBarrier(
      holes: holes,
      passThroughRect: passThroughRect,
      passThrough: passThrough,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderProxyBox renderObject,
  ) {
    (renderObject as _RenderHoleBarrier)
      ..holes = holes
      ..passThroughRect = passThroughRect
      ..passThrough = passThrough;
  }
}

class _RenderHoleBarrier extends RenderProxyBox {
  _RenderHoleBarrier({
    List<Rect> holes = const [],
    Rect? passThroughRect,
    this.passThrough = false,
  })  : _holes = holes,
        _passThroughRect = passThroughRect;

  List<Rect> _holes;
  Rect? _passThroughRect;

  /// 介绍性步骤：全屏放行自由操作
  bool passThrough;

  List<Rect> get holes => _holes;

  set holes(List<Rect> value) {
    if (listEquals(_holes, value)) return;
    _holes = value;
    markNeedsPaint();
  }

  Rect? get passThroughRect => _passThroughRect;

  set passThroughRect(Rect? value) {
    if (_passThroughRect == value) return;
    _passThroughRect = value;
    markNeedsPaint();
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (passThrough) return false;
    for (final h in _holes) {
      if (h.contains(position)) {
        return false; // 挖孔穿透：目标收到真实事件
      }
    }
    if (_passThroughRect != null && _passThroughRect!.contains(position)) {
      return false; // 交互放行区（如会话滚动区）：放行浏览/展开
    }
    return true; // 遮罩吸收（阻断误触）
  }
}

class _MaskPainter extends CustomPainter {
  const _MaskPainter({
    required this.holes,
    required this.barrierColor,
    required this.outline,
  });

  final List<Rect> holes;
  final Color barrierColor;

  /// 呼吸描边（减弱动态时关闭）
  final bool outline;

  @override
  void paint(Canvas canvas, Size size) {
    final full = Offset.zero & size;
    final paint = Paint()..color = barrierColor;
    if (holes.isEmpty) {
      canvas.drawRect(full, paint);
      return;
    }
    final barrier = Path()..addRect(full);
    final cutout = Path();
    for (final h in holes) {
      cutout.addRRect(RRect.fromRectAndRadius(h, const Radius.circular(12)));
    }
    final combined = Path.combine(PathOperation.difference, barrier, cutout);
    canvas.drawPath(combined, paint);
    if (outline) {
      final outlinePaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = const Color(0x66FFFFFF);
      for (final h in holes) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(h, const Radius.circular(12)).inflate(2),
          outlinePaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_MaskPainter oldDelegate) =>
      !listEquals(oldDelegate.holes, holes) ||
      oldDelegate.outline != outline ||
      oldDelegate.barrierColor != barrierColor;
}
