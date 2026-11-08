import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/demo/data/demo_state_store.dart';
import 'package:lmstory/features/demo/domain/demo_replay_profile.dart';

import 'demo_exit_resume_helpers.dart';

/// 真实页面测试：旧内容版本不符
/// 旧内容版本不符 → 点继续 → 可见提示 → 断言原库和状态在用户决策前保留 →
/// 不重启应用即可选择后续动作（点重新开始）→ fresh start 成功挂载。
void main() {
  final h = DemoExitHarness();
  setUp(h.setUp);
  tearDown(h.tearDown);

  testWidgets('旧内容版本不符时拒绝恢复：显示不兼容提示，决策前保留旧数据，点重新开始可不重启恢复',
      (tester) async {
    // 写入旧内容版本不匹配的状态
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

    // 初始化已有的 sqlite 文件
    final initDb = AppDatabase.forTesting(NativeDatabase(h.demoFile));
    await initDb.customStatement('SELECT 1;');
    await initDb.close();
    expect(h.demoFile.existsSync(), isTrue, reason: '初始演示库文件已存在');

    // 启动宿主（模拟启动检测到 running 状态）
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
    expect(loaded, isTrue, reason: '运行时已加载');
    await h.settle(tester, rounds: 10);

    // 启动门控弹出恢复对话框
    expect(find.text('继续上次的演示？'), findsOneWidget);
    expect(find.text('继续上次'), findsOneWidget);

    // 1. 点继续
    await tester.tap(find.text('继续上次'));
    await h.settle(tester, rounds: 6);

    // 2. 可见提示：弹出演示进度不兼容对话框，且包含不兼容原因
    expect(find.text('演示进度不兼容'), findsOneWidget, reason: '弹出不兼容提示');
    expect(
      find.textContaining('v2-outdated-content'),
      findsOneWidget,
      reason: '明确展示版本不匹配原因',
    );
    expect(find.text('重新开始'), findsOneWidget);
    expect(find.text('稍后处理'), findsOneWidget);
    expect(find.text('放弃演示数据'), findsOneWidget);

    // 3. 断言原库和状态在用户决策前完整保留
    expect(runtime.scopeActive, isFalse, reason: '不兼容时未激活 Demo 作用域');
    final savedBeforeDecision = await store.load();
    expect(savedBeforeDecision.runId, 'old-incompatible-run');
    expect(savedBeforeDecision.phase, DemoPhase.running);
    expect(savedBeforeDecision.packContentVersion, 'v2-outdated-content');
    expect(h.demoFile.existsSync(), isTrue, reason: '决策前原数据库文件未被清理');

    // 4. 不重启应用即可选择后续动作：点击「重新开始」
    await tester.tap(find.text('重新开始'));
    await h.settle(tester, rounds: 14);

    // 5. 验证 fresh start 成功挂载，且状态已更新为最新官方包
    expect(runtime.scopeActive, isTrue, reason: '重新开始后成功挂载 Demo 作用域');
    expect(runtime.state.phase, DemoPhase.running);
    expect(
      runtime.state.packContentVersion,
      isNot('v2-outdated-content'),
      reason: '已更新为当前官方包内容版本',
    );

    // 清理
    await h.teardownScope(tester, runtime);
  });
}
