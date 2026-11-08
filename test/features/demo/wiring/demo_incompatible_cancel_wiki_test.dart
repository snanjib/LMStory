import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/demo/data/demo_state_store.dart';
import 'package:lmstory/features/demo/domain/demo_replay_profile.dart';
import 'package:lmstory/features/help/presentation/pages/first_launch_wiki_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'demo_exit_resume_helpers.dart';

/// 真实页面测试：不兼容提示中选择「稍后处理」后状态保留，
/// 可在 Wiki 帮助页重新进入恢复决策流程并选择放弃。
void main() {
  final h = DemoExitHarness();
  setUp(() async {
    await h.setUp();
    // 标记 onboarding 完成，使帮助页的重看/恢复入口对用户可见
    SharedPreferences.setMockInitialValues(<String, Object>{
      'onboarding_completed': true,
    });
  });
  tearDown(h.tearDown);

  testWidgets('不兼容提示选择「稍后处理」：原状态保留，可经由 Wiki 帮助页重新进入决策并放弃',
      (tester) async {
    final store = DemoStateStore(directory: h.tmpDir);
    await store.save(
      const DemoState(
        inviteStatus: DemoInviteStatus.accepted,
        phase: DemoPhase.running,
        runId: 'old-incompatible-run',
        sessionId: 'old-session-1',
        stepId: 'sessionInput',
        formatVersion: 2,
        packContentVersion: 'v2-outdated-content',
        replayProfileId: DemoReplayProfile.zhipuId,
        capabilitiesHash: 'mock-cap-hash',
      ),
    );

    final initDb = AppDatabase.forTesting(NativeDatabase(h.demoFile));
    await initDb.customStatement('SELECT 1;');
    await initDb.close();

    final runtime = h.buildRuntime();
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

    // 启动弹出恢复对话框
    expect(find.text('继续上次的演示？'), findsOneWidget);
    await tester.tap(find.text('继续上次'));
    await h.settle(tester, rounds: 6);

    // 弹出不兼容提示
    expect(find.text('演示进度不兼容'), findsOneWidget);
    expect(find.text('稍后处理'), findsOneWidget);

    // 点击「稍后处理」关闭弹窗
    await tester.tap(find.text('稍后处理'));
    await h.settle(tester, rounds: 6);

    // 弹窗关闭，未挂载，数据与状态保持完整未变
    expect(find.text('演示进度不兼容'), findsNothing);
    expect(runtime.scopeActive, isFalse);
    final savedBefore = await store.load();
    expect(savedBefore.phase, DemoPhase.running);
    expect(savedBefore.packContentVersion, 'v2-outdated-content');
    expect(h.demoFile.existsSync(), isTrue);

    // 打开/挂载 Wiki 帮助页查看再入口
    await tester.pumpWidget(
      h.host(root),
    );
    // 直接把 FirstLaunchWikiPage 推到 Navigator 上
    runtime.navigatorKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const FirstLaunchWikiPage(),
      ),
    );
    await h.settle(tester, rounds: 8);

    // Wiki 帮助页检测到 running && !scopeActive，展示「继续上次」入口
    expect(find.text('第一次打开 App'), findsOneWidget);
    expect(find.text('继续上次'), findsOneWidget);

    // 点击 Wiki 页内的「继续上次」，重新触发恢复决策流程
    await tester.tap(find.text('继续上次'));
    await h.settle(tester, rounds: 6);

    // 重新弹出恢复对话框
    expect(find.text('继续上次的演示？'), findsOneWidget);
    expect(find.text('放弃演示数据'), findsOneWidget);

    // 点击「放弃演示数据」
    await tester.tap(find.text('放弃演示数据'));
    await h.settle(tester, rounds: 6);

    // 验证状态已彻底重置为已接受/放弃，不再处于 running 阶段
    final savedAfter = await store.load();
    expect(savedAfter.phase, isNot(DemoPhase.running));
    expect(runtime.state.phase, isNot(DemoPhase.running));

    // 清理：拆树 + 推进 21s 消除 MainLayout 的 20s 备份计时器
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 21));
  });
}
