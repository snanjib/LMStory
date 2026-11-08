import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/demo/presentation/demo_bridge.dart';

import 'demo_exit_resume_helpers.dart';

/// r3 修复回归（主控复核一·场景 3）：放弃→二次确认取消，教程恢复、
/// 作用域保持（演示数据未被清）。
///
/// 本目录隔离纪律见 demo_exit_resume_helpers.dart（一文件一场景）。
void main() {
  final h = DemoExitHarness();
  setUp(h.setUp);
  tearDown(h.tearDown);

  testWidgets('放弃→二次确认取消：教程恢复，作用域保持', (tester) async {
    final runtime = await h.mountDemo(tester);
    final bridge = runtime.container!.read(demoBridgeProvider)!;
    final stepBefore = bridge.tutorial.current?.id;

    await tester.tap(find.text('退出体验'));
    await h.settle(tester, rounds: 8);
    await tester.tap(find.text('放弃演示数据'));
    await h.settle(tester, rounds: 8);
    expect(find.text('放弃演示数据？'), findsOneWidget, reason: '二次确认框出现');
    expect(bridge.tutorial.active, isTrue, reason: '二次确认期间教程未终止');

    // 取消放弃（用 MaterialLocalizations 的取消按钮）
    await tester.tap(find.text('取消'));
    await h.settle(tester, rounds: 8);
    expect(bridge.tutorial.active, isTrue, reason: '取消放弃后教程恢复');
    expect(bridge.tutorial.current?.id, stepBefore);
    expect(runtime.scopeActive, isTrue, reason: '演示数据未被清');

    await h.teardownScope(tester, runtime);
  });
}
