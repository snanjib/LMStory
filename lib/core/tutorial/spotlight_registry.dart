import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Spotlight 目标挂载元信息（几何与路由状态）。
class SpotlightTargetMeta {
  const SpotlightTargetMeta({
    required this.rect,
    this.isCurrentRoute = true,
    this.isPopupRoute = false,
  });

  final Rect rect;
  final bool isCurrentRoute;
  final bool isPopupRoute;
}

/// Spotlight 语义目标注册表。
///
/// 真实 widget 经 `SpotlightTarget`（spotlight_target.dart）以语义 id
/// 注册全局几何；教程系统据此定位遮罩挖孔，**不使用固定坐标或截图**。
/// 目标几何随布局/滚动/键盘/窗口变化由上报方与 overlay 的逐帧刷新
/// 共同维护；卸载即注销。
///
/// 本类为纯通用能力：不含任何业务或教程步骤语义。
class SpotlightRegistry extends ChangeNotifier {
  final Map<String, Rect> _rects = {};
  final Map<String, SpotlightTargetMeta> _metas = {};
  final Map<String, bool Function()> _reporters = {};
  bool _notifyScheduled = false;
  bool _disposed = false;

  /// 帧安全通知：始终延迟到 postFrame 并强制调度新帧，
  /// 避免在 widget 的 dispose/deactivate/didChangeDependencies 期间同步触发重绘
  /// 导致 InheritedElement 依赖未注销断言失败（_dependents.isEmpty）。
  void _scheduleNotify() {
    if (_disposed) return;
    if (_notifyScheduled) return;
    _notifyScheduled = true;
    try {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _notifyScheduled = false;
        if (_disposed) return;
        notifyListeners();
      });
      SchedulerBinding.instance.scheduleFrame();
    } catch (_) {
      // binding 未就绪（纯 Dart 单测场景，直接通知）
      _notifyScheduled = false;
      notifyListeners();
    }
  }

  /// 当前全部目标快照（id → 全局 Rect）
  Map<String, Rect> snapshot() => Map.unmodifiable(_rects);

  Rect? rectOf(String id) => _rects[id];

  SpotlightTargetMeta? metaOf(String id) => _metas[id];

  bool isRegistered(String id) => _rects.containsKey(id);

  bool get isNotEmpty => _rects.isNotEmpty;

  /// 注册/更新目标几何与路由状态（几何与状态未变化时不通知）
  void register(
    String id,
    Rect rect, {
    bool isCurrentRoute = true,
    bool isPopupRoute = false,
  }) {
    final old = _rects[id];
    final oldMeta = _metas[id];
    final changed = old != rect ||
        oldMeta == null ||
        oldMeta.isCurrentRoute != isCurrentRoute ||
        oldMeta.isPopupRoute != isPopupRoute;
    _rects[id] = rect;
    _metas[id] = SpotlightTargetMeta(
      rect: rect,
      isCurrentRoute: isCurrentRoute,
      isPopupRoute: isPopupRoute,
    );
    if (changed) {
      _scheduleNotify();
    }
  }

  void unregister(String id) {
    _reporters.remove(id);
    _metas.remove(id);
    if (_rects.remove(id) != null) {
      _scheduleNotify();
    }
  }

  /// 目标组件注册即时上报器（遮罩活动期逐帧调用，兜底外部位移：
  /// 滚动/键盘/窗口缩放/动画——这些不触发目标自身重建）
  void registerReporter(String id, bool Function() reporter) {
    _reporters[id] = reporter;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// 逐帧刷新：全部上报器重算 Rect（变化经 register 通知）
  void refreshReporters() {
    for (final reporter in _reporters.values.toList()) {
      reporter();
    }
  }
}

/// 根作用域缺省注册表（无教程活动时为空）。
/// 演示作用域经 overrideWithValue 注入桥内共享实例。
final spotlightRegistryProvider = Provider<SpotlightRegistry>(
  (ref) => SpotlightRegistry(),
);
