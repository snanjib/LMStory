import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/demo/data/demo_state_store.dart';
import 'package:lmstory/features/help/presentation/pages/first_launch_wiki_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'demo_exit_resume_helpers.dart';

void main() {
  final h = DemoExitHarness();
  setUp(() async {
    await h.setUp();
    SharedPreferences.setMockInitialValues(<String, Object>{
      'onboarding_completed': true,
    });
  });
  tearDown(h.tearDown);

  testWidgets('在 Wiki/设置页手动启动演示：自动退回主界面后再出现蒙版，不出现等待目标弹窗', (
    tester,
  ) async {
    final store = DemoStateStore(directory: h.tmpDir);
    await store.save(
      const DemoState(
        inviteStatus: DemoInviteStatus.accepted,
      ),
    );

    final runtime = h.buildRuntime();
    addTearDown(runtime.dispose);
    final root = h.buildContainer(runtime);
    addTearDown(root.dispose);
    await tester.pumpWidget(h.host(root));

    var loaded = false;
    for (var i = 0; i < 160 && !loaded; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump(const Duration(milliseconds: 60));
      loaded = runtime.loaded;
    }
    expect(loaded, isTrue);
    await h.settle(tester, rounds: 10);

    // 把 FirstLaunchWikiPage 推到 Navigator 上模拟从设置进入
    runtime.navigatorKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const FirstLaunchWikiPage(),
      ),
    );
    await h.settle(tester, rounds: 8);

    expect(find.text('第一次打开 App'), findsOneWidget);
    expect(find.text('立即体验'), findsOneWidget);

    // 点击「立即体验」
    await tester.tap(find.text('立即体验'));
    await h.settle(tester, rounds: 12);

    // 验证演示作用域已激活
    expect(runtime.scopeActive, isTrue);

    // 验证 FirstLaunchWikiPage 已被弹出退回根路由，主界面可见
    expect(find.text('第一次打开 App'), findsNothing);
    expect(find.text('导演模式创建向导'), findsOneWidget);

    // 验证绝无「正在等待目标出现...」卡片
    expect(find.text('正在等待目标出现...'), findsNothing);

    // 清理：主动 dispose 演示运行时以撤销 300ms 定期刷新定时器，
    // 拆树并推进 21s 消除 MainLayout 的 20s 备份计时器
    runtime.dispose();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 21));
  });
}
