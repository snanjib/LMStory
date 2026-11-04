import 'package:flutter/widgets.dart';

/// 焦点遍历区域：桌面壳的「关键面」。
///
/// 枚举值即 Tab 顺序（[order] 小的先被遍历）。
///
/// **为什么只有三个区域**：`FocusTraversalOrder` 是继承标记，取**最近的祖先**
/// ——一个焦点节点只能属于一个区域。桌面壳里真正互为兄弟、需要显式排先后的
/// 只有「侧栏」与「主区」，故壳层声明到这一层为止；主区内部（同一页的
/// 顶部工具栏 → 正文）由 [LmFocusTraversal] 的次级策略按阅读顺序决定，
/// **不需要也不应该**跨页面去给每个 AppBar 单独贴标记（那会把页面骨架
/// 耦合到遍历顺序上）。设置域这类单列内容页则整体声明为一个区域，
/// 让「它是内容面」这件事显式化。
enum LmFocusRegion {
  /// 桌面侧栏（会话列表、新建入口、设置入口）。
  sidebar(1),

  /// 会话区：某一页的主区（含该页顶部工具栏与正文/列表）。
  conversation(2),

  /// 单列内容页：设置域子页、资源库、帮助中心等表单/列表面。
  content(3);

  const LmFocusRegion(this.order);

  /// 遍历序号（越小越先）。
  final double order;
}

/// 焦点遍历分组：为子树安装「显式顺序」策略。
///
/// 只有装了 `OrderedTraversalPolicy` 的分组，其子树里的 [LmFocusOrder] 才
/// 真正接管 Tab 顺序（否则 `FocusTraversalOrder` 会被默认的阅读顺序策略
/// 忽略——这正是「声明了但没生效」的经典坑）。
///
/// 次级策略（未声明顺序的节点、以及同序号节点之间的次序）用默认的
/// `ReadingOrderTraversalPolicy`：几何阅读顺序。
class LmFocusTraversal extends StatelessWidget {
  const LmFocusTraversal({required this.child, super.key});

  final Widget child;

  /// 策略实例复用：`FocusTraversalGroup` 的 `updateShouldNotify` 比的是
  /// 策略对象身份，每次 build 新建会让继承通知白跑一轮。
  static final FocusTraversalPolicy _policy = OrderedTraversalPolicy();

  @override
  Widget build(BuildContext context) =>
      FocusTraversalGroup(policy: _policy, child: child);
}

/// 把一个子树标记为 [region]（Tab 顺序显式声明）。
///
/// 消费方式见 `main_layout.dart` 的桌面壳与 `settings_page.dart`：
///
/// ```dart
/// LmFocusTraversal(
///   child: Row(children: [
///     LmFocusOrder(region: LmFocusRegion.sidebar, child: sidebar),
///     Expanded(
///       child: LmFocusOrder(
///         region: LmFocusRegion.conversation,
///         child: mainContent,
///       ),
///     ),
///   ]),
/// )
/// ```
class LmFocusOrder extends StatelessWidget {
  const LmFocusOrder({required this.region, required this.child, super.key});

  /// 本子树所属区域（枚举值即序号，不要在调用点写裸数字）。
  final LmFocusRegion region;

  final Widget child;

  @override
  Widget build(BuildContext context) => FocusTraversalOrder(
        order: NumericFocusOrder(region.order),
        child: child,
      );
}
