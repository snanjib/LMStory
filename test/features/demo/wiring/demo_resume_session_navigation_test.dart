import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/advanced/presentation/pages/advanced_chat_page.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/chat/data/repositories/chat_repository_impl.dart';
import 'package:lmstory/features/demo/data/demo_state_store.dart';
import 'package:lmstory/features/demo/presentation/demo_bridge.dart';
import 'package:lmstory/features/templates/data/repositories/template_repository_impl.dart';

import 'demo_exit_resume_helpers.dart';

/// 恢复演示导航回归：在看记忆库或已提交回合后退出，再次启动选择「继续上次」
/// 验证：自动跳转到上次对应的 AdvancedChatPage 会话，而非停留在主界面遮罩中卡住。
void main() {
  final h = DemoExitHarness();
  setUp(h.setUp);
  tearDown(h.tearDown);

  testWidgets('恢复演示自动导航至未完成会话页且高亮设置入口', (tester) async {
    // 1. 在演示库中布置已完成一回合的真实会话
    final seedDb = AppDatabase.forTesting(NativeDatabase(h.demoFile));
    await TemplateRepositoryImpl(seedDb).ensureBuiltInTemplates();
    final repo = ChatRepositoryImpl(database: seedDb);
    final session = await repo.createSession(
      title: '演示会话',
      mode: 'advanced',
    );
    final sid = session.sessionId;
    await seedDb.customStatement(
      'UPDATE chat_sessions SET next_turn = 2 WHERE session_id = ?',
      [sid],
    );
    await seedDb.close();

    // 2. 状态文件写入 running + memoryView 步骤（用户在看记忆库时退出的场景）
    final store = DemoStateStore(directory: h.tmpDir);
    await store.save(
      DemoState(
        inviteStatus: DemoInviteStatus.accepted,
        phase: DemoPhase.running,
        runId: 'resume-run-1',
        sessionId: sid,
        stepId: 'memoryView',
        seedPresetId: 'demo-seed-preset',
      ),
    );

    // 3. 启动应用宿主
    final runtime = h.buildRuntime();
    final root = h.buildContainer(runtime);
    addTearDown(root.dispose);
    await tester.pumpWidget(h.host(root));

    // 等待启动加载
    var loaded = false;
    for (var i = 0; i < 160 && !loaded; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump(const Duration(milliseconds: 60));
      loaded = runtime.loaded;
    }
    expect(loaded, isTrue);

    // 等待恢复弹窗
    var resumeShown = false;
    for (var i = 0; i < 80 && !resumeShown; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump(const Duration(milliseconds: 60));
      resumeShown = find.text('继续上次').evaluate().isNotEmpty;
    }
    expect(resumeShown, isTrue, reason: '恢复提示弹窗出现');

    // 点击「继续上次」
    await tester.tap(find.text('继续上次'));
    await h.settle(tester, rounds: 20);

    // 验证演示作用域已激活
    expect(runtime.scopeActive, isTrue);

    // 核心断言：自动跳转到了会话页面（AdvancedChatPage），而非停留在主界面
    expect(find.byType(AdvancedChatPage), findsOneWidget, reason: '直接跳转到会话页面');

    // 验证会话页面的设置按钮已被高亮，引导用户重新查看记忆库
    final bridge = runtime.container!.read(demoBridgeProvider)!;
    expect(bridge.tutorial.current?.id, 'settingsIntro', reason: '会话步平滑引导查看记忆库');

    // 清理
    await h.teardownScope(tester, runtime);
  });
}
