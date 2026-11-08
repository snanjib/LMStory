import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/tutorial/spotlight_registry.dart';

/// Spotlight 语义目标：以稳定 id 向最近作用域的注册表上报自身全局几何。
///
/// - build 后 postFrame 上报（布局稳定后取 Rect）；
/// - 自身重建/尺寸变化（didUpdateWidget + build）重新上报；
/// - 卸载注销；
/// - 外部位移（滚动/键盘/窗口/动画）由 Overlay 活动期的逐帧刷新兜底；
/// - 空内容/离屏目标照常上报（Rect 由渲染树决定，不做视口裁剪）。
///
/// 通用组件：不含任何业务/教程步骤语义。
class SpotlightTarget extends ConsumerStatefulWidget {
  const SpotlightTarget({
    required this.id,
    required this.child,
    super.key,
  });

  /// 语义目标 id（教程步骤引用的稳定标识）
  final String id;
  final Widget child;

  @override
  ConsumerState<SpotlightTarget> createState() => _SpotlightTargetState();
}

class _SpotlightTargetState extends ConsumerState<SpotlightTarget> {
  SpotlightRegistry? _cachedRegistry;

  SpotlightRegistry get _registry {
    try {
      final current = ref.read(spotlightRegistryProvider);
      _cachedRegistry = current;
      return current;
    } catch (_) {
      return _cachedRegistry ?? SpotlightRegistry();
    }
  }

  @override
  void initState() {
    super.initState();
    _cachedRegistry = ref.read(spotlightRegistryProvider);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _registry.registerReporter(widget.id, _reportImmediate);
      }
    });
    _scheduleReport();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    try {
      final newRegistry = ref.read(spotlightRegistryProvider);
      if (_cachedRegistry != null && _cachedRegistry != newRegistry) {
        _cachedRegistry!.unregister(widget.id);
        _cachedRegistry = newRegistry;
        _cachedRegistry!.registerReporter(widget.id, _reportImmediate);
        _scheduleReport();
      }
    } catch (_) {}
  }

  @override
  void didUpdateWidget(SpotlightTarget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.id != widget.id) {
      _registry.unregister(oldWidget.id);
      _registry.registerReporter(widget.id, _reportImmediate);
    }
    _scheduleReport();
  }

  @override
  void dispose() {
    // 注册表引用在 initState/didChangeDependencies 缓存——dispose 期不可再访问 ref
    _cachedRegistry?.unregister(widget.id);
    super.dispose();
  }

  void _scheduleReport() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _report());
    try {
      SchedulerBinding.instance.scheduleFrame();
    } catch (_) {}
  }

  void _report() {
    // postFrame 时机（调用方保证）：布局已定，直接即时上报
    _reportImmediate();
  }

  /// 即时上报全局 Rect（逐帧刷新回调同此）。返回是否成功——
  /// 遮罩活动期外部位移（滚动/键盘/窗口）由此路径兜底。
  bool _reportImmediate() {
    if (!mounted) return false;
    final ro = context.findRenderObject();
    if (ro is! RenderBox || !ro.hasSize || !ro.attached) return false;
    final route = ModalRoute.of(context);
    final isCurrent = route?.isCurrent ?? true;
    final isPopup = route is PopupRoute;
    final topLeft = ro.localToGlobal(Offset.zero);
    _registry.register(
      widget.id,
      topLeft & ro.size,
      isCurrentRoute: isCurrent,
      isPopupRoute: isPopup,
    );
    return true;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
