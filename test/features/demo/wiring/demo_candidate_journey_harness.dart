import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/storage/preferences.dart';
import 'package:lmstory/core/storage/secure_storage.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/demo/data/demo_pack_loader.dart';
import 'package:lmstory/features/demo/data/demo_session_handover.dart';
import 'package:lmstory/features/demo/data/demo_state_store.dart';
import 'package:lmstory/features/demo/domain/demo_pack.dart';
import 'package:lmstory/features/demo/domain/demo_replay_profile.dart';
import 'package:lmstory/features/demo/presentation/demo_runtime.dart';
import 'package:lmstory/features/demo/presentation/demo_selection_controller.dart';
import 'package:lmstory/i18n/strings.g.dart';
import 'package:lmstory/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 候选长链共享行走器（被三个独立文件各跑一条——rootBundle 缓存命中的
/// SynchronousFuture 在同进程第二个 testWidgets 的 FakeAsync 区会停滞，
/// 因此每进程只跑一条旅程）。
///
/// 真实页面点击全链：主页 → 邀请 → 真实向导（模型步经真实 sheet 选定
/// 候选 → 虚拟/嵌入/内置模板逐步真实点击）→ 固定提示词亲自发送 → 真实
/// 回合（候选包回放+真实工具链落库）→ 设置面板 → 真实记忆库（按候选
/// 真实沉淀浏览）→ 返回 → 完成体验 → 正式交接 → 正式库可查。
/// 不 mock 目标注册、不用控制器替身；除演示数据包（明确标注 sample）
/// 与库/状态文件注入外全部真实页面与业务。

/// 候选长链规格：向导步点选的候选、包资产路径与回放画像期望。
enum JourneySpec {
  glm53(
    candidateId: 'glm-5.3',
    modelLabel: '仿真 · GLM-5.3',
    packPath: 'assets/demo/first_launch/zh-CN.json',
    profile: DemoReplayProfile.zhipu,
  ),
  deepseek(
    candidateId: 'deepseek-v4.1-flash',
    modelLabel: '仿真 · DeepSeek-V4.1-Flash',
    packPath: 'assets/demo/first_launch/zh-CN/deepseek-v4.1-flash.json',
    profile: DemoReplayProfile.deepseek,
  ),
  glmFlash(
    candidateId: 'glm-5.3-flash',
    modelLabel: '仿真 · GLM-5.3-Flash',
    packPath: 'assets/demo/first_launch/zh-CN/glm-5.3-flash.json',
    profile: DemoReplayProfile.zhipu,
  );

  const JourneySpec({
    required this.candidateId,
    required this.modelLabel,
    required this.packPath,
    required this.profile,
  });

  final String candidateId;
  final String modelLabel;
  final String packPath;
  final DemoReplayProfile profile;

  /// 其他候选的独立正文证据needle（用于页面全链串包防线）
  List<String> otherProseNeedles() {
    final needles = <String>[];
    for (final other in JourneySpec.values) {
      if (other == this) continue;
      final raw = jsonDecode(File(other.packPath).readAsStringSync())
          as Map<String, dynamic>;
      needles.addAll(
        ((raw['expectations'] as Map<String, dynamic>)['proseContains'] as List)
            .cast<String>(),
      );
    }
    return needles;
  }
}

/// 执行一条候选长链（[spec] 决定向导模型步点选的候选与其期望证据）。
///
/// [tmpDir]/[demoFile]/[realDb]/[realPrefs] 由各文件用例注入（每条旅程
/// 独立临时目录与真实库）。
Future<void> runCandidateJourney(
  WidgetTester tester,
  JourneySpec spec, {
  required Directory tmpDir,
  required File demoFile,
  required AppDatabase realDb,
  required Preferences realPrefs,
  DemoPackLoader? packLoader,
  DemoStateStore? stateStore,
}) async {
  final packRaw = jsonDecode(File(spec.packPath).readAsStringSync())
      as Map<String, dynamic>;
  final pack = DemoPack.parse(packRaw);
  final expectedPrompt = pack.prompt;
  final expectedEntities = pack.expectations.entityNames;

  final runtime = DemoRuntime(
    realDatabase: realDb,
    preferences: realPrefs,
    secureStorage: SecureStorage(),
    stateStore: stateStore ?? DemoStateStore(directory: tmpDir),
    databaseOpener: () async =>
        AppDatabase.forTesting(NativeDatabase(demoFile)),
    handoverFactory: DemoSessionHandover.new,
    packLoader: packLoader,
  );
  addTearDown(runtime.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(realDb),
        preferencesProvider.overrideWithValue(realPrefs),
        secureStorageProvider.overrideWithValue(SecureStorage()),
        demoRuntimeProvider.overrideWith((ref) => runtime),
      ],
      child: MyApp(),
    ),
  );
  await settle(tester, rounds: 12);

  await tester.tap(find.text('立即体验'));
  await settle(tester, rounds: 20);
  expect(runtime.scopeActive, isTrue, reason: '接受后挂载 Demo 作用域');

  // Demo 内 MainLayout：onboarding stub=已完成 → 主页（非介绍页）
  expect(
    find.text('导演模式创建向导'),
    findsOneWidget,
    reason: 'Demo 作用域内真实主页与向导引导卡',
  );

  // ── 2. 点真实向导卡 → 向导模型步 ──
  await tester.tap(find.text('导演模式创建向导'));
  await settle(tester, rounds: 16);

  // 无预选（确定性配置清了全局 GM 键）→「选择模型」按钮在挖孔内
  final pickModelButton = find.text('选一个模型');
  expect(pickModelButton, findsOneWidget, reason: '模型步可操作入口（高亮目标覆盖区）');
  await tester.tap(pickModelButton);
  await settle(tester, rounds: 10);

  // 模型选择器：分组默认收起（无预选）→ 点组标题展开 → 点选目标候选
  final groupTile = find.text('演示模型（本地回放）');
  await tester.ensureVisible(groupTile);
  await settle(tester, rounds: 4);
  await tester.tap(groupTile, warnIfMissed: false);
  await settle(tester, rounds: 8);
  if (find.text('仿真 · GLM-5.3').evaluate().isEmpty) {
    // 组标题点击未命中（InkWell 边缘）→ 重试 Chevron 图标
    await tester.tap(
      find.byIcon(Icons.keyboard_arrow_down).first,
      warnIfMissed: false,
    );
    await settle(tester, rounds: 8);
  }
  expect(find.text(spec.modelLabel), findsOneWidget, reason: '分组展开后目标候选可见');
  await tester.tap(find.text(spec.modelLabel));
  await settle(tester, rounds: 10);

  // 真实绑定证据：协调点/画像=所选候选（同页面真实回调链）
  final selection = runtime.container!.read(demoSelectionProvider);
  expect(
    selection.current.id,
    spec.candidateId,
    reason: '向导模型步真实回调完成候选绑定',
  );
  expect(
    selection.capabilities,
    spec.profile.resolveCapabilities(),
    reason: '网关能力画像与所选候选回放画像一致',
  );
  expect(
    runtime.state.candidateId,
    spec.candidateId,
    reason: '候选身份已持久化（向导确认前）',
  );

  // 选择结果推进（wizardProgress.modelReady）→ 点真实「下一步」。
  // 先等选模型成功提示条（SnackBar，1s+退场动画）过期——真实用户
  // 也会等它消失，避免遮挡底部主按钮。
  await tester.pump(const Duration(seconds: 3));
  await settle(tester, rounds: 10);
  await tester.tap(find.text('下一步'));
  await settle(tester, rounds: 16);
  expect(find.text('选择记忆检索模型'), findsOneWidget, reason: '嵌入页出现后气泡定位到选择区');

  // ── 3. 嵌入步：「配上」展开 → 选演示嵌入模型 →「下一步」──
  await tester.tap(find.text('配上（推荐）'));
  await settle(tester, rounds: 8);
  await tester.tap(find.text('演示嵌入模型（本地）'));
  await settle(tester, rounds: 10);
  // 嵌入选择成功提示条过期（1s+退场），随后点真实「下一步」进规则步
  await tester.pump(const Duration(seconds: 3));
  await settle(tester, rounds: 8);
  await tester.tap(find.text('下一步'));
  await settle(tester, rounds: 10);
  expect(find.text('项目规则'), findsWidgets, reason: '进入规则步');
  // 规则步先呈现路径选择（模板/问卷两条路）→ 点真实「用现成模板」
  final pathCard = find.text('用现成模板');
  await tester.ensureVisible(pathCard);
  await settle(tester, rounds: 4);
  await tester.tap(pathCard, warnIfMissed: false);
  await settle(tester, rounds: 10);
  if (find.text('异世界穿越叙述者系统提示词').evaluate().isEmpty) {
    // PathCard 点击未命中（可能被等待卡遮罩遮挡）→ 重试标题所在卡中心
    await tester.tap(find.text('用现成模板'), warnIfMissed: false);
    await settle(tester, rounds: 10);
  }
  expect(find.text('使用内置的世界规则'), findsOneWidget, reason: '路径选择后模板列表气泡出现');

  // ── 4. 规则步：选内置异世界模板 → 预览「使用」确认 →「完成」──
  await tester.tap(find.text('异世界穿越叙述者系统提示词'));
  await settle(tester, rounds: 10);
  await tester.tap(find.text('就用这个'), warnIfMissed: false);
  await settle(tester, rounds: 10);
  // 规则确认完成 → 点真实「完成」（末步按钮）交付向导
  await tester.tap(find.text('完成'));
  await settle(tester, rounds: 16);

  // ── 5. 草稿会话页：固定提示词锁定，亲自点击发送 ──
  // 向导 pop 动画+输入锁 build 后校正需要真实帧——等锁文本到位
  // 输入锁校正时机=advanced 页 initState postFrame + 锁 provider 变化；
  // waitFor 轮询期间 pump 推进真实帧（校正经 setText 即时生效）
  final locked = await waitFor(
    tester,
    () => tester.widgetList(find.byType(TextField, skipOffstage: false)).any(
          (f) => (f as TextField).controller!.text == expectedPrompt,
        ),
    maxRounds: 200,
  );
  expect(locked, isTrue, reason: '输入锁呈现固定提示词（只读）');
  final sendButton = find.byIcon(Icons.send_rounded);
  expect(sendButton, findsOneWidget);
  await tester.tap(sendButton);
  await settle(tester, rounds: 8);

  // ── 6. 真实回合（候选包回放+真实工具链）→ 推进到设置介绍 ──
  final reachedSettings = await waitFor(
    tester,
    () => find.text('看看会话设置').evaluate().isNotEmpty,
  );
  expect(reachedSettings, isTrue, reason: '回合提交后推进到设置介绍步');

  // ── 7. 点真实设置按钮 → 面板 → 记忆库按钮 ──
  await tester.tap(find.byIcon(Icons.settings_outlined));
  await settle(tester, rounds: 12);
  final openMemory = find.text('查看记忆库');
  if (openMemory.evaluate().isNotEmpty) {
    await tester.ensureVisible(openMemory);
    await tester.tap(openMemory);
  } else {
    // 面板内滚动兜底
    await tester.drag(find.byType(Scrollable).last, const Offset(0, -220));
    await settle(tester, rounds: 6);
    await tester.tap(find.text('查看记忆库'));
  }
  await settle(tester, rounds: 14);

  // ── 8. 真实记忆库：按候选真实沉淀浏览 ──
  if (expectedEntities.isEmpty) {
    // 零实体候选：经历分区承载本轮沉淀（默认 Tab 即经历），事实分区
    // 不虚构实体条目
    expect(find.text('经历'), findsOneWidget, reason: '零实体引导落在经历分区');
    final episodic = await waitFor(
      tester,
      () => find
          .textContaining(pack.expectations.eventSummaryContains.first)
          .evaluate()
          .isNotEmpty,
      maxRounds: 200,
    );
    expect(episodic, isTrue, reason: '经历 Tab 展示本轮真实沉淀的事件记忆');
    // 真实浏览动作：切到事实分区看一眼（空态），再回经历
    final factualTab = find.text('事实');
    if (factualTab.evaluate().isNotEmpty) {
      await tester.tap(factualTab.first);
      await settle(tester, rounds: 10);
      await tester.tap(find.text('经历').first);
      await settle(tester, rounds: 10);
    }
  } else {
    // 有实体候选：事实 Tab 展示本轮真实沉淀的实体
    final factualTab = find.text('事实');
    if (factualTab.evaluate().isNotEmpty) {
      await tester.tap(factualTab.first);
      await settle(tester, rounds: 10);
    }
    expect(
      find.text(expectedEntities.first),
      findsWidgets,
      reason: '记忆库事实 Tab 展示本轮真实沉淀的实体',
    );
  }
  expect(find.text('查看记忆库'), findsNothing, reason: '设置面板已被记忆库页覆盖（真实路由推入）');

  // ── 9. 返回会话：记忆库（AppBar 返回箭头）→ 设置面板（关闭/拖下）
  //    → 会话（两层）→ 收尾步 → 点「完成」触发交接 ──
  final memoryBack = find.byType(BackButton);
  if (memoryBack.evaluate().isNotEmpty) {
    await tester.tap(memoryBack.first);
    await settle(tester, rounds: 10);
  }
  // 设置面板是 bottom sheet：再 navigator pop 关闭
  tester.state<NavigatorState>(find.byType(Navigator)).pop();
  await settle(tester, rounds: 12);
  final finishVisible = await waitFor(
    tester,
    () =>
        find.text('体验完成').evaluate().isNotEmpty ||
        find.text('完成').evaluate().isNotEmpty,
  );
  expect(finishVisible, isTrue, reason: '返回后进入收尾步（目标注销→教程推进有帧延迟）');

  // 点收尾卡「完成」→ 教程结束 → 交接
  await tester.tap(find.text('完成'), warnIfMissed: false);
  await settle(tester);

  // ── 10. 交接后退出 Demo 作用域：介绍式引导呈现 + 正式库可查 ──
  final handedOver = await waitFor(
    tester,
    () => !runtime.scopeActive,
    maxRounds: 200,
  );
  expect(handedOver, isTrue, reason: '交接完成后退出 Demo 作用域');
  await settle(tester, rounds: 12);
  // 介绍式引导（既有 OnboardingPage，内容零删减）——真实门控呈现
  expect(find.text('暂不，先看介绍'), findsNothing);
  expect(runtime.state.phase, DemoPhase.handoverDone);

  // 正式库：会话保留且可继续（next_turn=2），消息/实体/事件齐全；
  // 正文与实体都是**本候选**独立语义证据（串包防线在真实页面全链成立）
  final sessionRows = await realDb
      .customSelect('SELECT session_id, next_turn, mode FROM chat_sessions')
      .get();
  expect(sessionRows, hasLength(1), reason: '正式库收到交接会话');
  expect(sessionRows.single.read<int>('next_turn'), pack.expectations.nextTurn);
  expect(sessionRows.single.read<String>('mode'), 'advanced');
  final sid = sessionRows.single.read<String>('session_id');
  final assistantRows = await realDb
      .customSelect(
        "SELECT content FROM chat_messages WHERE session_id='$sid' "
        "AND role='assistant'",
      )
      .get();
  final prose = assistantRows.map((r) => r.read<String>('content')).join('\n');
  expect(prose, isNotEmpty);
  for (final needle in pack.expectations.proseContains) {
    expect(prose, contains(needle), reason: '交接后的正式库正文来自所选候选包');
  }
  // 串包防线（页面全链级）：其他候选的独立正文证据不得出现在正式库
  for (final needle in spec.otherProseNeedles()) {
    expect(prose, isNot(contains(needle)), reason: '其他候选正文不得串入（$needle）');
  }
  expect(
    (await realDb
            .customSelect(
              "SELECT COUNT(*) n FROM chat_messages WHERE session_id='$sid'",
            )
            .get())
        .single
        .read<int>('n'),
    2,
  );
  expect(
    (await realDb
            .customSelect(
              "SELECT COUNT(*) n FROM factual_entities WHERE session_id='$sid'",
            )
            .get())
        .single
        .read<int>('n'),
    expectedEntities.length,
    reason: '实体由真实 update_facts 落库（零实体候选=0，不虚构）',
  );
  // 虚拟供应商不进正式库
  expect(
    (await realDb.customSelect('SELECT COUNT(*) n FROM api_presets').get())
        .single
        .read<int>('n'),
    0,
  );
}

Future<void> settle(WidgetTester tester, {int rounds = 24}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump(const Duration(milliseconds: 60));
  }
}

/// 轮询直到 [predicate] 成立（runAsync+ pump 交替推进真实异步与定时器）
Future<bool> waitFor(
  WidgetTester tester,
  bool Function() predicate, {
  int maxRounds = 800,
  Duration step = const Duration(milliseconds: 100),
}) async {
  for (var i = 0; i < maxRounds; i++) {
    if (predicate()) return true;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(step);
  }
  return predicate();
}

/// 每条旅程文件的公共开场：locale/onboarding/临时目录/真实库
({
  Directory tmpDir,
  File demoFile,
  AppDatabase realDb,
  Preferences realPrefs,
}) journeySetUp() {
  unawaited(LocaleSettings.setLocaleRaw('zh'));
  SharedPreferences.setMockInitialValues(<String, Object>{
    // 真实用户路径：onboarding 未完成（首问+介绍式引导按真实门控出现）
    'onboarding_completed': false,
  });
  final tmpDir = Directory.systemTemp.createTempSync('demo_journey');
  final demoFile = File('${tmpDir.path}/demo.db');
  final realDb = AppDatabase.forTesting(NativeDatabase.memory());
  final realPrefs = Preferences();
  return (
    tmpDir: tmpDir,
    demoFile: demoFile,
    realDb: realDb,
    realPrefs: realPrefs
  );
}

/// 公共收场：关真实库、删临时目录
Future<void> journeyTearDown(
  Directory tmpDir,
  AppDatabase realDb,
) async {
  await realDb.close();
  tmpDir.deleteSync(recursive: true);
}
