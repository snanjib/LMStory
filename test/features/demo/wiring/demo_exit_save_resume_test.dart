import 'package:flutter/material.dart' show SizedBox;
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/demo/data/demo_state_store.dart';
import 'package:lmstory/features/demo/presentation/demo_bridge.dart';

import 'demo_exit_resume_helpers.dart';

/// r3 修复回归（主控复核一·场景 2）：确认保存退出后仍可恢复。
/// 作用域卸载 → 检查点持久化 → 重建宿主（模拟重启）→ 恢复弹窗
/// 「继续上次」→ 恢复到保存时的步骤（不重启一轮）。
///
/// 本目录隔离纪律见 demo_exit_resume_helpers.dart（一文件一场景）。
void main() {
  final h = DemoExitHarness();
  setUp(h.setUp);
  tearDown(h.tearDown);

  testWidgets('退出确认「保存并退出」后可恢复：作用域退出，start 恢复到检查点',
      (tester) async {
    final runtime = await h.mountDemo(tester);
    final bridge = runtime.container!.read(demoBridgeProvider)!;
    final stepBefore = bridge.tutorial.current?.id;

    await tester.tap(find.text('退出体验'));
    await h.settle(tester, rounds: 8);
    await tester.tap(find.text('保存并退出'), warnIfMissed: false);
    // 交接链异步完成（scopeActive 翻转）——轮询等待而非固定帧数
    var exited = false;
    for (var i = 0; i < 160 && !exited; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump(const Duration(milliseconds: 60));
      exited = !runtime.scopeActive;
    }
    expect(exited, isTrue, reason: '保存退出 → 作用域卸载');
    // 桥已随作用域销毁（实例被弃用，不再读其状态）；
    // 「教程已结束」的证据=恢复挂载后新控制器从检查点起步（下方断言）

    // 恢复：重建 MyApp 宿主（模拟重启）→ 恢复弹窗 → 继续上次
    final runtime2 = h.buildRuntime();
    await runtime2.load();
    expect(runtime2.state.phase, DemoPhase.running, reason: '检查点已持久化');
    expect(runtime2.state.stepId, stepBefore, reason: '步骤检查点一致');

    final root2 = h.buildContainer(runtime2);
    addTearDown(root2.dispose);
    await tester.pumpWidget(h.host(root2));
    await h.settle(tester, rounds: 10);
    await tester.tap(find.text('继续上次'));
    await h.settle(tester);
    expect(runtime2.scopeActive, isTrue, reason: '恢复挂载成功');
    final bridge2 = runtime2.container!.read(demoBridgeProvider)!;
    expect(bridge2.tutorial.active, isTrue);
    expect(
      bridge2.tutorial.current?.id,
      stepBefore,
      reason: '恢复到保存时的步骤（不重启一轮）',
    );
    expect(runtime2.state.phase, DemoPhase.running);

    // 清理：拆树 + 推过 20s 备份延迟时钟
    await runtime2.exitKeepData();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 21));
  });
}
