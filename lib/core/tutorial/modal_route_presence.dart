import 'package:flutter/widgets.dart';

/// 浮层模态路由在栈计数（NavigatorObserver）。
///
/// 教程遮罩挂在 MaterialApp.builder（Navigator 之上）；对话框/底部
/// sheet 等 PopupRoute 在 Navigator 内部渲染——遮罩会挡住它们的交互。
/// 此观察者向遮罩宿主广播「当前有浮层在栈上」，遮罩据此抬起（浮层
/// 本身即当前操作面，用户必须能自由交互）。
///
/// 只计 PopupRoute（DialogRoute/ModalBottomSheetRoute 等浮层）——
/// MaterialPageRoute 等整页路由也是 ModalRoute 子类，但不属于浮层，
/// 计入会让遮罩对整页导航永久失效。
class ModalRoutePresence extends NavigatorObserver {
  final ValueNotifier<int> openCount = ValueNotifier<int>(0);

  void _bump(Route<dynamic> route, int delta) {
    if (route is PopupRoute) {
      openCount.value = (openCount.value + delta).clamp(0, 1 << 31);
    }
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _bump(route, 1);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _bump(route, -1);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _bump(route, -1);
}
