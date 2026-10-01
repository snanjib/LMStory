import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/utils/follow_scroll_executor.dart';
import 'package:lmstory/core/utils/smooth_follow_scroller.dart'
    show streamingFollowCushionPx;

/// FollowScrollExecutor 测试（：状态机 + 平滑执行器； 头注订正）
///
/// 契约（4ff36891 起两平台行为一致，不再有
/// 「桌面平滑 / 移动直贴」分派）：
/// - followGrowth → 缓冲吸收 + 越界限速滑行（见 smooth_follow_scroller_test），
///   两平台同一套常量与行为；
/// - forceToBottom 一律即时贴底（发送/胶囊路径不走缓冲滑行）；
/// - handleScrollMetrics：上划即冻结；未跟随时 followGrowth 无滚动；
/// - forceToBottom 恢复跟随并贴底；reset 回初始跟随态。
///
/// 平台覆盖恢复：test binding 在用例体结束时校验 foundation 调试变量
/// 已复位，须在体内（而非仅 tearDown）恢复 override。
void main() {
  testWidgets('跟随统一：缓冲滑行取代移动端直贴（不再当帧瞬移）', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final hostKey = GlobalKey<_ExecutorHostState>();
    await tester.pumpWidget(_ExecutorHost(key: hostKey));
    await tester.pump();
    final h = hostKey.currentState!
      ..jumpToBottom()
      ..grow(8);
    await tester.pump(); // 布局新内容
    expect(h.maxExtent - h.pixels, greaterThan(300), reason: '前置：距底远超缓冲');

    h.executor.followGrowth();
    await tester.pump(const Duration(milliseconds: 16)); // 首帧 dt=0
    final firstFrame = h.pixels;
    await tester.pump(const Duration(milliseconds: 16));
    expect(h.pixels, greaterThan(firstFrame), reason: '滑行逐帧前进');
    expect(
      h.maxExtent - h.pixels,
      greaterThan(100),
      reason: '不是当帧瞬移到位——移动端也走缓冲滑行（2026-09-10 拍板统一）',
    );

    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(
      h.maxExtent - h.pixels,
      lessThanOrEqualTo(streamingFollowCushionPx + 1),
      reason: '滑行到位后最新一行留在视口内',
    );
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('android：未贴底且 following=false → followGrowth 无滚动', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final hostKey = GlobalKey<_ExecutorHostState>();
    await tester.pumpWidget(_ExecutorHost(key: hostKey));
    await tester.pump();
    final h = hostKey.currentState!
      ..jumpToBottom()
      ..feedMetrics(); // 建立游标基线
    h.executor.handleScrollMetrics(h.pixels - 80, h.maxExtent); // 上划冻结
    expect(h.executor.state.following, isFalse, reason: '前置：已冻结');

    h.grow(8);
    await tester.pump();
    final frozenAt = h.pixels;
    h.executor.followGrowth();
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(
      h.pixels,
      frozenAt,
      reason: '未跟随时 followGrowth 不得产生任何滚动',
    );
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('handleScrollMetrics：上划即冻结；滚回贴底自动恢复', (tester) async {
    final hostKey = GlobalKey<_ExecutorHostState>();
    await tester.pumpWidget(_ExecutorHost(key: hostKey));
    await tester.pump();
    final h = hostKey.currentState!
      ..jumpToBottom()
      ..feedMetrics(); // 建立游标基线（pixels=maxExtent）
    expect(h.executor.state.following, isTrue);

    // 上划（pixels 下降、extent 不变）→ 冻结
    h.executor.handleScrollMetrics(h.pixels - 80, h.maxExtent);
    expect(h.executor.state.following, isFalse, reason: '上划即冻结');

    // 滚回贴底（距底 0 在 48px 恢复带内，且 delta 为正）→ 恢复跟随
    h.executor.handleScrollMetrics(h.maxExtent, h.maxExtent);
    expect(h.executor.state.following, isTrue, reason: '滚回贴底自动恢复');
  });

  testWidgets('forceToBottom：恢复跟随并即时贴底（桌面也不走平滑）', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final hostKey = GlobalKey<_ExecutorHostState>();
    await tester.pumpWidget(_ExecutorHost(key: hostKey));
    await tester.pump();
    final h = hostKey.currentState!
      ..jumpToBottom()
      ..feedMetrics();
    h.executor.handleScrollMetrics(h.pixels - 80, h.maxExtent); // 冻结
    h.grow(8);
    await tester.pump();
    expect(h.executor.state.following, isFalse, reason: '前置：阅读位冻结');

    h.executor.forceToBottom();
    await tester.pump();
    expect(h.executor.state.following, isTrue, reason: '强制恢复跟随');
    expect(
      h.pixels,
      h.maxExtent,
      reason: '发送/胶囊路径：postFrame jumpTo 即时贴底（windows 也即时）',
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      h.pixels,
      h.maxExtent,
      reason: 'ticker 已停：后续帧不得再动（无平滑余波）',
    );
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('reset：冻结态回初始跟随，游标清零后可再次正常冻结', (tester) async {
    final hostKey = GlobalKey<_ExecutorHostState>();
    await tester.pumpWidget(_ExecutorHost(key: hostKey));
    await tester.pump();
    final h = hostKey.currentState!
      ..jumpToBottom()
      ..feedMetrics();
    h.executor.handleScrollMetrics(h.pixels - 80, h.maxExtent); // 冻结
    expect(h.executor.state.following, isFalse);

    h.executor.reset();
    expect(h.executor.state.following, isTrue, reason: 'reset 回初始跟随态');

    // 游标已清零：重新建立基线后上划仍能冻结（簿记未串台）
    h.feedMetrics();
    h.executor.handleScrollMetrics(h.pixels - 80, h.maxExtent);
    expect(h.executor.state.following, isFalse, reason: 'reset 后冻结语义正常');
  });
}

/// 滚动宿主：300px 视口 + 50px/项 的普通方向列表（与三模式同构）。
class _ExecutorHost extends StatefulWidget {
  const _ExecutorHost({super.key});

  @override
  State<_ExecutorHost> createState() => _ExecutorHostState();
}

class _ExecutorHostState extends State<_ExecutorHost>
    with SingleTickerProviderStateMixin {
  final controller = ScrollController();
  late final FollowScrollExecutor executor;
  int itemCount = 40;

  @override
  void initState() {
    super.initState();
    executor = FollowScrollExecutor(controller: controller, vsync: this);
  }

  @override
  void dispose() {
    executor.dispose();
    controller.dispose();
    super.dispose();
  }

  double get pixels => controller.position.pixels;
  double get maxExtent => controller.position.maxScrollExtent;

  void jumpToBottom() => controller.jumpTo(maxExtent);

  void grow([int count = 4]) => setState(() => itemCount += count);

  /// 以当前滚动位姿喂一次执行器（建立/刷新游标基线）。
  void feedMetrics() => executor.handleScrollMetrics(pixels, maxExtent);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Center(
        child: SizedBox(
          height: 300,
          child: ListView.builder(
            controller: controller,
            padding: EdgeInsets.zero,
            itemCount: itemCount,
            itemBuilder: (_, i) => SizedBox(
              height: 50,
              child: Center(child: Text('item-$i')),
            ),
          ),
        ),
      ),
    );
  }
}
