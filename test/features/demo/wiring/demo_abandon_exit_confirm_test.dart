import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/demo/data/demo_state_store.dart';

import 'demo_exit_resume_helpers.dart';

/// 放弃演示数据确认回归：从运行中 Demo 触发退出 → 选择放弃演示数据 → 二次确认放弃
/// 验证：作用域安全卸载、不抛 GlobalKey/Element 重挂载断言、状态清空回到正式主界面。
void main() {
  final h = DemoExitHarness();
  setUp(h.setUp);
  tearDown(h.tearDown);

  testWidgets('放弃体验二次确认确认放弃：安全注销作用域且无 Element 断言异常', (tester) async {
    final runtime = await h.mountDemo(tester);
    expect(runtime.scopeActive, isTrue);

    // 点击遮罩上的「退出体验」
    await tester.tap(find.text('退出体验'));
    await h.settle(tester, rounds: 8);

    // 点击「放弃演示数据」
    await tester.tap(find.text('放弃演示数据'));
    await h.settle(tester, rounds: 8);

    expect(find.text('放弃演示数据？'), findsOneWidget, reason: '二次确认弹窗出现');

    // 点击「确认放弃」
    await tester.tap(find.text('确认放弃'));
    await h.settle(tester);

    // 验证演示作用域已干净卸载，回到正式环境
    expect(runtime.scopeActive, isFalse, reason: '确认放弃后 DemoScope 已卸载');
    expect(runtime.state.phase, DemoPhase.idle, reason: '状态回到 idle');
    expect(find.text('放弃演示数据？'), findsNothing, reason: '确认弹窗已关闭');
    expect(find.text('退出体验'), findsNothing, reason: '演示遮罩已关闭');
  });
}
