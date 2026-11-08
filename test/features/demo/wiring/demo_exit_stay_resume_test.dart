import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/demo/presentation/demo_bridge.dart';

import 'demo_exit_resume_helpers.dart';

/// r3 修复回归（主控复核一·场景 1）：退出→继续体验，教程原地恢复。
/// 确认框期间教程不得提前终止；继续体验回到原步骤与活动态。
///
/// 本目录隔离纪律见 demo_exit_resume_helpers.dart（一文件一场景）。
void main() {
  final h = DemoExitHarness();
  setUp(h.setUp);
  tearDown(h.tearDown);

  testWidgets('退出→继续体验：教程原地恢复（步骤与活动态保留）', (tester) async {
    final runtime = await h.mountDemo(tester);
    final bridge = runtime.container!.read(demoBridgeProvider)!;
    final stepBefore = bridge.tutorial.current?.id;
    expect(stepBefore, isNotNull);
    expect(bridge.tutorial.active, isTrue);

    // 遮罩退出入口 → 弹确认框（教程未终止）
    await tester.tap(find.text('退出体验'));
    await h.settle(tester, rounds: 8);
    expect(find.text('退出演示体验？'), findsOneWidget, reason: '退出确认框出现');
    expect(bridge.tutorial.active, isTrue, reason: '确认期间教程不得提前终止');
    expect(bridge.tutorial.current?.id, stepBefore, reason: '步骤保留');

    // 继续体验 → 教程原地恢复
    await tester.tap(find.text('继续体验'));
    await h.settle(tester, rounds: 8);
    expect(bridge.tutorial.active, isTrue, reason: '继续体验后教程恢复');
    expect(bridge.tutorial.current?.id, stepBefore, reason: '回到原步骤');
    expect(bridge.tutorial.exitRequestOpen, isFalse);
    expect(runtime.scopeActive, isTrue);

    await h.teardownScope(tester, runtime);
  });
}
