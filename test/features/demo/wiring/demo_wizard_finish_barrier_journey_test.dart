import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/storage/preferences.dart';
import 'package:lmstory/core/storage/secure_storage.dart';
import 'package:lmstory/features/advanced/presentation/pages/advanced_chat_page.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/demo/data/demo_pack_loader.dart';
import 'package:lmstory/features/demo/data/demo_session_handover.dart';
import 'package:lmstory/features/demo/data/demo_state_store.dart';
import 'package:lmstory/features/demo/domain/demo_candidate.dart';
import 'package:lmstory/features/demo/domain/demo_pack.dart';
import 'package:lmstory/features/demo/domain/demo_replay_profile.dart';
import 'package:lmstory/features/demo/presentation/demo_runtime.dart';
import 'package:lmstory/features/demo/presentation/demo_selection_controller.dart';
import 'package:lmstory/features/director_wizard/presentation/controllers/director_wizard_controller.dart';
import 'package:lmstory/features/director_wizard/presentation/pages/director_wizard_page.dart';
import 'package:lmstory/features/settings/presentation/widgets/default_model_picker_sheet.dart';
import 'package:lmstory/i18n/strings.g.dart';
import 'package:lmstory/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'demo_candidate_journey_harness.dart' show settle, waitFor;

/// 向导完成 × 会话创建入口屏障（真实应用全链页面级回归）：
/// 绑定未收敛时不得按旧选择完成向导并创建会话 Controller。
///
/// 覆盖三个交错起因（每个场景独立环境，按顺序在同一个 testWidgets 内
/// 执行——rootBundle 缓存命中的 SynchronousFuture 在同进程第二个
/// testWidgets 的 FakeAsync 区会停滞，故多场景合并为单测顺序循环）。
/// 挂起窗口全部发生在**同一次选择器会话内**：初始候选是 glm-5.3
/// （zhipu 画像），点选非初始候选才走真实加载；A=DeepSeek 的加载挂门
/// 保持 sheet 打开 → 点选 B=Kimi 排队（串行）→ 放行 A 使向导就绪为
/// A、B 仍在等待：
/// 1. B 加载挂起 → 关闭选择器 → 完成向导：入口屏障拦下（处理中状态、
///    不 pop、不建 Controller），放行后 B 迟到返回被取消，A（deepseek
///    画像，与初始 zhipu 画像跨画像）全链一致，且入口已锁定（首发前
///    也禁止热换）；
/// 2. B 身份保存挂起 → 同路径：放行后 B 补偿回滚持久身份并取消，
///    A 全链一致（状态文件候选仍是 A）；
/// 3. B 挂起 → 关闭选择器 → 销毁向导页（不产出会话）：放行后迟到
///    返回静默失效——无 ref-after-dispose、无换包、状态原样。
///
/// 除加载/保存延迟门与库/状态文件注入外全部真实页面与业务：
/// 真实向导、真实选择器、真实完成链、真实草稿会话 Controller。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('绑定未收敛时向导完成被入口屏障拦截，放行后取消迟到请求保持原候选', (tester) async {
    await LocaleSettings.setLocaleRaw('zh');
    SharedPreferences.setMockInitialValues(<String, Object>{
      'onboarding_completed': false,
    });

    // ── 场景 1：同会话 A(deepseek)→B(kimi)，B 加载挂起；A 先放行使向导
    //    就绪为 A，关闭选择器（未提交的 B 被取消）→ 完成被入口屏障拦下
    //    → 放行后 B 迟到返回取消，A 全链一致，且入口已锁定 ──
    var cycle = _CycleEnv();
    var runtime = await cycle.pumpApp(tester);
    await _acceptInvite(tester, runtime);
    await _openPicker(tester);
    // 门在点选前预挂：A 的加载挂起保 sheet 打开，B 排队（串行）
    cycle.loader.gateFor('deepseek-v4.1-flash');
    cycle.loader.gateFor('kimi-k3.1-pro');
    await _selectModel(tester, '仿真 · DeepSeek-V4.1-Flash');
    await tester.pump(const Duration(milliseconds: 30));
    await _selectModel(tester, '仿真 · Kimi-K3.1-Pro');
    await tester.pump(const Duration(milliseconds: 30));
    // A 先放行：向导就绪为 A；sheet 仍开（B 挂起中，序次归 B）
    cycle.loader.gateFor('deepseek-v4.1-flash').complete();
    await settle(tester, rounds: 16);
    expect(
      runtime.container!.read(directorWizardProvider).gmModelId,
      'demo-narrator-deepseek-v4.1-flash',
      reason: 'A 放行后向导就绪为 A',
    );
    expect(
      find.textContaining('由 仿真 · DeepSeek-V4.1-Flash 执笔'),
      findsWidgets,
    );
    expect(
      find.byType(DefaultModelPickerSheet),
      findsOneWidget,
      reason: '过期的 A 结果不驱动关闭（序次归 B）',
    );
    _popSheet(tester);
    await settle(tester, rounds: 12);
    expect(find.byType(DefaultModelPickerSheet), findsNothing);
    // 完成向导：入口屏障等待 B 收敛——期间不 pop、不建会话
    await _completeWizardSteps(tester);
    expect(
      find.byType(AdvancedChatPage),
      findsNothing,
      reason: '绑定未收敛：不得创建会话',
    );
    expect(
      find.byType(DirectorWizardPage),
      findsOneWidget,
      reason: '完成入口呈处理中状态（未 pop）',
    );
    expect(
      tester
          .widget<ElevatedButton>(
            find.widgetWithText(ElevatedButton, '完成').first,
          )
          .enabled,
      isFalse,
      reason: '屏障期间完成按钮禁用（处理中状态）',
    );
    cycle.loader.gateFor('kimi-k3.1-pro').complete();
    await settle(tester);
    await _expectSessionBound(
      tester,
      runtime,
      'deepseek-v4.1-flash',
      'demo-narrator-deepseek-v4.1-flash',
      DemoReplayProfile.deepseek,
    );
    await expectLater(
      runtime.container!.read(demoSelectionProvider).bindByVirtualModelId(
            'demo-narrator-kimi-k3.1-pro',
          ),
      throwsA(isA<DemoCandidateLockedException>()),
      reason: '入口屏障已锁定：首发前也禁止热换',
    );
    await cycle.teardown(tester);

    // ── 场景 2：同会话 A(deepseek)→B(kimi)，B 的身份保存挂起；关闭选择器
    //    后完成被拦 → 放行后 B 补偿回滚持久身份并取消，A 全链一致
    //    （状态文件候选是 A）──
    cycle = _CycleEnv();
    runtime = await cycle.pumpApp(tester);
    await _acceptInvite(tester, runtime);
    await _openPicker(tester);
    // A 的加载挂门保 sheet 打开；B 的保存挂门（点选前预挂）
    cycle.loader.gateFor('deepseek-v4.1-flash');
    cycle.store.gateFor('kimi-k3.1-pro');
    await _selectModel(tester, '仿真 · DeepSeek-V4.1-Flash');
    await tester.pump(const Duration(milliseconds: 30));
    await _selectModel(tester, '仿真 · Kimi-K3.1-Pro');
    await tester.pump(const Duration(milliseconds: 30));
    cycle.loader.gateFor('deepseek-v4.1-flash').complete();
    await settle(tester, rounds: 16);
    expect(
      runtime.container!.read(directorWizardProvider).gmModelId,
      'demo-narrator-deepseek-v4.1-flash',
      reason: 'A 放行后向导就绪为 A',
    );
    expect(
      find.byType(DefaultModelPickerSheet),
      findsOneWidget,
      reason: 'B 身份保存挂起中：sheet 保持打开',
    );
    _popSheet(tester);
    await settle(tester, rounds: 12);
    await _completeWizardSteps(tester);
    expect(
      find.byType(AdvancedChatPage),
      findsNothing,
      reason: '身份保存未收敛：不得创建会话',
    );
    cycle.store.gateFor('kimi-k3.1-pro').complete();
    await settle(tester);
    await _expectSessionBound(
      tester,
      runtime,
      'deepseek-v4.1-flash',
      'demo-narrator-deepseek-v4.1-flash',
      DemoReplayProfile.deepseek,
    );
    // 被取消的 B 身份不得落盘（补偿回滚后候选仍是 A）
    final savedState = await cycle.store.load();
    expect(savedState.candidateId, 'deepseek-v4.1-flash');
    await cycle.teardown(tester);

    // ── 场景 3：同会话 A(deepseek)→B(kimi)，关闭选择器后销毁向导页
    //    （不产出会话）→ 放行后 B 迟到返回静默失效——无 ref-after-dispose、
    //    无换包、状态原样、未走完成入口不触发锁定 ──
    cycle = _CycleEnv();
    runtime = await cycle.pumpApp(tester);
    await _acceptInvite(tester, runtime);
    await _openPicker(tester);
    cycle.loader.gateFor('deepseek-v4.1-flash');
    cycle.loader.gateFor('kimi-k3.1-pro');
    await _selectModel(tester, '仿真 · DeepSeek-V4.1-Flash');
    await tester.pump(const Duration(milliseconds: 30));
    await _selectModel(tester, '仿真 · Kimi-K3.1-Pro');
    await tester.pump(const Duration(milliseconds: 30));
    cycle.loader.gateFor('deepseek-v4.1-flash').complete();
    await settle(tester, rounds: 16);
    _popSheet(tester);
    await settle(tester, rounds: 12);
    // 销毁向导页（返回，不产出会话）
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await settle(tester, rounds: 12);
    expect(find.byType(DirectorWizardPage), findsNothing);
    // 放行 B：迟到返回静默失效
    cycle.loader.gateFor('kimi-k3.1-pro').complete();
    await settle(tester, rounds: 16);
    expect(
      tester.takeException(),
      isNull,
      reason: '迟到回调不得触发 ref-after-dispose',
    );
    expect(
      find.byType(AdvancedChatPage),
      findsNothing,
      reason: '向导已销毁：不创建会话',
    );
    final selection3 = runtime.container!.read(demoSelectionProvider);
    expect(selection3.current.id, 'deepseek-v4.1-flash', reason: 'B 被取消：A 保持');
    expect(selection3.locked, isFalse, reason: '未走完成入口：不触发入口锁定');
    expect(runtime.state.candidateId, 'deepseek-v4.1-flash');
    expect(
      runtime.container!.read(agentCapabilitiesOverrideProvider),
      DemoReplayProfile.deepseek.resolveCapabilities(),
    );
    await cycle.teardown(tester);
  });
}

void _popSheet(WidgetTester tester) {
  tester.state<NavigatorState>(find.byType(Navigator)).pop();
}

/// 每个场景独立环境：临时目录/库/状态文件 + 可控加载与保存延迟门
class _CycleEnv {
  _CycleEnv() {
    tmpDir = Directory.systemTemp.createTempSync('demo_finish_barrier');
    demoFile = File('${tmpDir.path}/demo.db');
    realDb = AppDatabase.forTesting(NativeDatabase.memory());
    realPrefs = Preferences();
    store = _GatedCandidateStore(directory: tmpDir);
  }

  late final Directory tmpDir;
  late final File demoFile;
  late final AppDatabase realDb;
  late final Preferences realPrefs;
  late final _GatedCandidateStore store;
  final _BarrierGatedLoader loader = _BarrierGatedLoader();
  DemoRuntime? runtime;

  Future<DemoRuntime> pumpApp(WidgetTester tester) async {
    final runtime = DemoRuntime(
      realDatabase: realDb,
      preferences: realPrefs,
      secureStorage: SecureStorage(),
      stateStore: store,
      databaseOpener: () async =>
          AppDatabase.forTesting(NativeDatabase(demoFile)),
      handoverFactory: DemoSessionHandover.new,
      packLoader: loader,
    );
    this.runtime = runtime;
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
    return runtime;
  }

  /// 场景收场：卸载应用树 → 运行时收尾 → 关库 → 清临时目录
  Future<void> teardown(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await settle(tester, rounds: 8);
    runtime?.dispose();
    await realDb.close();
    try {
      tmpDir.deleteSync(recursive: true);
    } catch (_) {}
  }
}

/// 加载延迟门：按候选 id 挂 Completer，其余走真实资产加载
class _BarrierGatedLoader extends DemoPackLoader {
  final Map<String, Completer<void>> _gates = {};

  Completer<void> gateFor(String candidateId) =>
      _gates.putIfAbsent(candidateId, Completer<void>.new);

  @override
  Future<DemoPack> loadCandidate(
    DemoCandidate candidate, {
    String? expectedTemplateHash,
  }) async {
    final gate = _gates[candidate.id];
    if (gate != null) await gate.future;
    return super.loadCandidate(
      candidate,
      expectedTemplateHash: expectedTemplateHash,
    );
  }
}

/// 保存延迟门：仅拦「候选身份写为该候选」的保存（普通检查点保存直通）
class _GatedCandidateStore extends DemoStateStore {
  _GatedCandidateStore({required Directory directory})
      : super(directory: directory);

  final Map<String, Completer<void>> _gates = {};

  Completer<void> gateFor(String candidateId) =>
      _gates.putIfAbsent(candidateId, Completer<void>.new);

  @override
  Future<void> save(DemoState state) async {
    final gate = _gates[state.candidateId];
    if (gate != null) await gate.future;
    return super.save(state);
  }
}

Future<void> _acceptInvite(WidgetTester tester, DemoRuntime runtime) async {
  await tester.tap(find.text('立即体验'));
  await settle(tester, rounds: 20);
  expect(runtime.scopeActive, isTrue, reason: '接受后挂载 Demo 作用域');
  expect(
    find.text('导演模式创建向导'),
    findsOneWidget,
    reason: 'Demo 作用域内真实主页与向导引导卡',
  );
}

Future<void> _openPicker(WidgetTester tester) async {
  // 点真实向导卡 → 向导模型步（无预选）→「选择模型」→ 分组展开
  await tester.tap(find.text('导演模式创建向导'));
  await settle(tester, rounds: 16);
  final pickModelButton = find.text('选一个模型');
  expect(pickModelButton, findsOneWidget, reason: '模型步可操作入口（高亮目标覆盖区）');
  await tester.tap(pickModelButton);
  await settle(tester, rounds: 10);

  // 模型选择器：分组默认收起（无预选）→ 点组标题展开 → 候选可见
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
  expect(find.text('仿真 · GLM-5.3'), findsOneWidget, reason: '分组展开后候选可见');
}

Future<void> _selectModel(WidgetTester tester, String label) async {
  final item = find.text(label);
  await settle(tester, rounds: 2);
  if (item.evaluate().isEmpty) {
    // 列表视口边缘候选：滚动到可见（sheet 内列表）
    final sheetScrollable = find
        .descendant(
          of: find.byType(DefaultModelPickerSheet),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(item, 64, scrollable: sheetScrollable);
    await settle(tester, rounds: 2);
  }
  await tester.ensureVisible(item);
  await settle(tester, rounds: 2);
  await tester.tap(item);
  await tester.pump(const Duration(milliseconds: 16));
}

Future<void> _completeWizardSteps(WidgetTester tester) async {
  await tester.tap(find.text('下一步'));
  await settle(tester, rounds: 16);
  expect(find.text('选择记忆检索模型'), findsOneWidget);
  await tester.tap(find.text('配上（推荐）'));
  await settle(tester, rounds: 8);
  await tester.tap(find.text('演示嵌入模型（本地）'));
  await settle(tester, rounds: 10);
  // 嵌入选择成功提示条过期（1s+退场），随后点真实「下一步」进规则步
  await tester.pump(const Duration(seconds: 3));
  await settle(tester, rounds: 8);
  await tester.tap(find.text('下一步'));
  await settle(tester, rounds: 10);
  expect(find.text('项目规则'), findsWidgets);
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
  await tester.tap(find.text('异世界穿越叙述者系统提示词'));
  await settle(tester, rounds: 10);
  await tester.tap(find.text('就用这个'), warnIfMissed: false);
  await settle(tester, rounds: 10);
  // 规则确认完成 → 点真实「完成」（末步按钮触发完成事务/入口屏障）
  await tester.tap(find.text('完成'));
  await tester.pump(const Duration(milliseconds: 30));
}

/// 会话创建后的全链同一性断言：会话模型/画像/协调点/运行时身份/锁定
Future<void> _expectSessionBound(
  WidgetTester tester,
  DemoRuntime runtime,
  String candidateId,
  String virtualModelId,
  DemoReplayProfile profile,
) async {
  final pageReady = await waitFor(
    tester,
    () => find.byType(AdvancedChatPage).evaluate().isNotEmpty,
    maxRounds: 200,
  );
  expect(pageReady, isTrue, reason: '入口屏障放行后会话页就绪（Controller 已构造）');
  final page = tester.widget<AdvancedChatPage>(find.byType(AdvancedChatPage));
  final controllerState =
      runtime.container!.read(advancedChatControllerProvider(page.session));
  expect(
    controllerState.session.phaseModels.generatingModelId,
    virtualModelId,
    reason: '会话配置=入口屏障固定的已提交候选（$candidateId）',
  );
  final selection = runtime.container!.read(demoSelectionProvider);
  expect(selection.current.id, candidateId);
  expect(selection.locked, isTrue, reason: '入口屏障锁定：此后迟到请求一律拒绝');
  expect(
    runtime.container!.read(agentCapabilitiesOverrideProvider),
    profile.resolveCapabilities(),
    reason: 'Controller 首读缓存的能力画像=同一份已提交候选',
  );
  expect(
    selection.capabilities,
    profile.resolveCapabilities(),
    reason: '协调点画像与消费面一致',
  );
  expect(runtime.state.candidateId, candidateId);
  expect(runtime.state.virtualModelId, virtualModelId);
  expect(
    runtime.state.replayProfileId,
    selection.pack.manifest.replayProfile!.id,
  );
}
