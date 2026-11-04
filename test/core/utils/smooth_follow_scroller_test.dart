import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/utils/scroll_follow_state_machine.dart';
import 'package:lmstory/core/utils/smooth_follow_scroller.dart';

/// SmoothFollowScroller 单元测试（惰性跟随 + 速度受限滑行，2026-09-10）
///
/// 契约：
/// - **最新一行始终留在视口内**（`maxScrollExtent - pixels ≤ cushionPx`）；
/// - 缓冲区内增长不移动视口（已读文字静止）；
/// - 越过缓冲后限速滑行回贴底位——不是瞬移，也不是「每段一个动画」；
/// - 上划冻结当帧停（滑行立即中断，无残余位移）。
void main() {
  const frame = Duration(milliseconds: 16);

  double restGap(_ScrollerHostState h) => h.maxExtent - h.pixels;

  testWidgets('缓冲区内增长不移动视口（已读文字保持静止）', (tester) async {
    // 缓冲放大到 100px（大于单项 50px），专门验证「缓冲吸收增长」这一条
    final hostKey = GlobalKey<_ScrollerHostState>();
    await tester.pumpWidget(
      _ScrollerHost(key: hostKey, cushionPx: 100),
    );
    await tester.pump();
    final h = hostKey.currentState!
      ..jumpToBottom()
      ..grow(1); // +50px < 100px 缓冲
    await tester.pump();
    final before = h.pixels;

    h.scroller.nudge();
    for (var i = 0; i < 6; i++) {
      await tester.pump(frame);
    }
    expect(
      h.pixels,
      before,
      reason: '缓冲区内增长不得推动视口（这正是「写满一行整屏上移」的来源）',
    );
    expect(
      h.maxExtent - h.pixels,
      lessThanOrEqualTo(100),
      reason: '最新一行仍在视口内',
    );
  });

  testWidgets('缓冲耗尽后限速滑行（非瞬移），稳定后最新行在视口内', (tester) async {
    final hostKey = GlobalKey<_ScrollerHostState>();
    await tester.pumpWidget(_ScrollerHost(key: hostKey));
    await tester.pump();
    final h = hostKey.currentState!
      ..jumpToBottom()
      ..grow(8); // +400px，远超缓冲
    await tester.pump();
    final target = h.maxExtent;
    expect(target - h.pixels, greaterThan(300), reason: '前置：距底远大于缓冲');

    h.scroller.nudge();
    await tester.pump(const Duration(milliseconds: 100)); // 首帧 dt=0
    final afterFirst = h.pixels;
    await tester.pump(const Duration(milliseconds: 100));
    final afterSecond = h.pixels;

    expect(
      afterSecond,
      allOf(greaterThan(afterFirst), lessThan(target)),
      reason: '限速滑行：逐帧前进且未一帧到顶（非瞬移）',
    );
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(
      restGap(h),
      lessThanOrEqualTo(streamingFollowCushionPx + 1),
      reason: '滑行最终把视口带回贴底位（缓冲重新建立）',
    );
    expect(h.pixels, lessThanOrEqualTo(h.maxExtent), reason: '不得越过底部');
  });

  testWidgets('上划冻结后当帧停——无残余位移', (tester) async {
    final hostKey = GlobalKey<_ScrollerHostState>();
    await tester.pumpWidget(_ScrollerHost(key: hostKey));
    await tester.pump();
    final h = hostKey.currentState!
      ..jumpToBottom()
      ..grow(8);
    await tester.pump();
    h.scroller.nudge();
    await tester.pump(const Duration(milliseconds: 100)); // 首帧 dt=0
    await tester.pump(const Duration(milliseconds: 100)); // 滑行一帧
    expect(h.maxExtent - h.pixels, greaterThan(100), reason: '前置：滑行途中');

    h.freeze();
    expect(h.follow.following, isFalse);
    final frozenAt = h.pixels;

    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(
      h.pixels,
      frozenAt,
      reason: '上划即停：ticker 回调先查状态机，冻结后不得有残余滑行帧',
    );
    expect(
      h.maxExtent - frozenAt,
      greaterThan(100),
      reason: '停在阅读位而非滑到贴底（区别于自然滑行）',
    );
  });

  testWidgets('静止期停帧；再次越过缓冲的增长重新触发滑行', (tester) async {
    final hostKey = GlobalKey<_ScrollerHostState>();
    await tester.pumpWidget(_ScrollerHost(key: hostKey));
    await tester.pump();
    final h = hostKey.currentState!
      ..jumpToBottom()
      ..grow(6);
    await tester.pump();
    h.scroller.nudge();
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(restGap(h), lessThanOrEqualTo(streamingFollowCushionPx + 1));
    final restedAt = h.pixels;

    // 静止期内（未越过缓冲）继续泵帧：位置不应再变（ticker 已自停）
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(h.pixels, restedAt, reason: '静止期不得继续移动');

    // 再次大幅增长 → nudge 重新滑行
    h.grow(6);
    await tester.pump();
    expect(
      h.maxExtent - h.pixels,
      greaterThan(streamingFollowCushionPx),
      reason: '前置：再次增长已越过缓冲',
    );
    h.scroller.nudge();
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(restGap(h), lessThanOrEqualTo(streamingFollowCushionPx + 1));
  });
}

/// 滚动宿主：300px 视口 + 50px/项 的普通方向列表（与三模式同构）。
class _ScrollerHost extends StatefulWidget {
  const _ScrollerHost({super.key, this.cushionPx = streamingFollowCushionPx});

  /// 可注入缓冲（默认取单源常量）。
  final double cushionPx;

  @override
  State<_ScrollerHost> createState() => _ScrollerHostState();
}

class _ScrollerHostState extends State<_ScrollerHost>
    with SingleTickerProviderStateMixin {
  final controller = ScrollController();
  final follow = ScrollFollowStateMachine();
  late final SmoothFollowScroller scroller;
  int itemCount = 40;

  @override
  void initState() {
    super.initState();
    scroller = SmoothFollowScroller(
      controller: controller,
      vsync: this,
      isFollowing: () => follow.following,
      cushionPx: widget.cushionPx,
    );
  }

  @override
  void dispose() {
    scroller.dispose();
    controller.dispose();
    super.dispose();
  }

  double get pixels => controller.position.pixels;
  double get maxExtent => controller.position.maxScrollExtent;

  void jumpToBottom() => controller.jumpTo(maxExtent);

  void grow([int count = 4]) => setState(() => itemCount += count);

  /// 模拟上划（pixels 下降、extent 不变）冻结状态机。
  void freeze() => follow.onUserScroll(
        pixelsDelta: -80,
        maxExtentDelta: 0,
        distanceToBottom: maxExtent - pixels,
      );

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
