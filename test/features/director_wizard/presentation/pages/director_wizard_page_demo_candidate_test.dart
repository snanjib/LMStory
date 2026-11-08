import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/features/demo/data/demo_pack_loader.dart';
import 'package:lmstory/features/demo/domain/demo_candidate.dart';
import 'package:lmstory/features/demo/domain/demo_pack.dart';
import 'package:lmstory/features/demo/presentation/demo_bridge.dart';
import 'package:lmstory/features/demo/presentation/demo_selection_controller.dart';
import 'package:lmstory/features/director_wizard/presentation/pages/director_wizard_page.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/presentation/controllers/settings_controller.dart';
import 'package:lmstory/features/settings/presentation/widgets/default_model_picker_sheet.dart';
import 'package:lmstory/i18n/strings.g.dart';

import '../../../../test_helpers/wizard_fake_settings_notifier.dart';
import '../../../demo/selection/demo_picker_hint_test.dart' show demoModels;

/// 深度可控加载器：deepseek 可挂延迟门，其余走真实资产加载
/// （含坏候选的资产缺失真实失败路径）。
class WizardGatedLoader extends DemoPackLoader {
  WizardGatedLoader(this.deepseekGate);

  final Completer<void>? deepseekGate;

  @override
  Future<DemoPack> loadCandidate(
    DemoCandidate candidate, {
    String? expectedTemplateHash,
  }) async {
    if (candidate.id == 'deepseek-v4.1-flash') {
      await deepseekGate?.future;
    }
    return super
        .loadCandidate(candidate, expectedTemplateHash: expectedTemplateHash);
  }
}

/// 真实向导页面 × 演示选择协调点（页面级回归）：
/// - 快速两次选择：慢加载请求不能覆盖最后选择，sheet 只关一次，
///   向导摘要与协调点/画像一致落最后选择；
/// - 绑定失败：sheet 保持打开可就地重试、无成功提示、向导不推进，
///   页面 snackbar 提示后重选有效项成功；
/// - 关闭选择器后迟到返回：未提交请求被取消失效，向导保持原选择，
///   无多余 pop、无异常；
/// - 首轮已锁定：绑定拒绝并提示，向导与 sheet 保持原状。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await LocaleSettings.setLocale(AppLocale.zhCn);
  });

  // ——— 顶层局部工具（闭包内 await 载入真实候选后填充） ———
  late List<DemoCandidate> candidates;
  late DemoPack initialPack;
  late DemoPackLoader realLoader;

  setUpAll(() async {
    realLoader = const DemoPackLoader();
    candidates = await realLoader.availableCandidates('zh-CN');
    initialPack = await realLoader.loadCandidate(candidates.first);
  });

  DemoCandidate brokenCandidate() => const DemoCandidate(
        id: 'broken-candidate',
        sourceModelId: 'unknown',
        virtualModelId: 'demo-narrator-broken',
        locale: 'zh-CN',
        assetPath: 'assets/demo/first_launch/zh-CN/missing.json',
        isDefault: false,
        displayNameZh: '仿真 · 损坏模型',
        displayNameEn: 'Sim · Broken',
      );

  ({
    DemoBridge bridge,
    DemoSelectionController selection,
  }) buildDemoScope({Completer<void>? deepseekGate, bool withBroken = false}) {
    final loader = WizardGatedLoader(deepseekGate);
    final list = withBroken ? [...candidates, brokenCandidate()] : candidates;
    final bridge = DemoBridge();
    final selection = DemoSelectionController(
      bridge: bridge,
      loader: loader,
      candidates: list,
      initialCandidate: candidates.first,
      initialPack: initialPack,
      onIdentityPersist: (_, __) async {},
    );
    bridge.selection = selection;
    return (bridge: bridge, selection: selection);
  }

  Widget pumpWizard(DemoBridge bridge) {
    final demoPreset = ApiPreset(
      presetId: 'demo-preset',
      name: '演示模型（本地回放）',
      baseUrl: 'https://demo.invalid/v1',
      createdAt: DateTime(2026, 11, 7),
      updatedAt: DateTime(2026, 11, 7),
      cachedModels: [
        ...demoModels,
        if (bridge.selection!.candidates.any((c) => c.id == 'broken-candidate'))
          const ModelInfo(
            modelId: 'demo-narrator-broken',
            displayName: '仿真 · 损坏模型',
          ),
      ],
    );
    final fake = FakeWizardSettingsNotifier(
      initialPresets: [demoPreset],
      keyedPresetIds: const {'demo-preset'},
    );
    return ProviderScope(
      overrides: [
        settingsNotifierProvider.overrideWith((ref) => fake),
        demoBridgeProvider.overrideWithValue(bridge),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          theme: ThemeCatalog.assemble(const LmAppearance(), Brightness.light),
          home: const DirectorWizardPage(),
        ),
      ),
    );
  }

  Future<void> openPicker(WidgetTester tester) async {
    await tester.tap(find.textContaining('选一个模型'));
    await tester.pumpAndSettle();
    expect(find.byType(DefaultModelPickerSheet), findsOneWidget);
    // 无预选时组默认收起：展开演示供应商分组
    await tester.tap(find.text('演示模型（本地回放）'), warnIfMissed: false);
    await tester.pumpAndSettle();
    if (find.text('仿真 · GLM-5.3').evaluate().isEmpty) {
      await tester.tap(
        find.byIcon(Icons.keyboard_arrow_down).first,
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
    }
  }

  /// 绑定链含真实资产加载（平台通道）——FakeAsync 区内需 runAsync 交替
  /// 推进真实异步与帧，与全链旅程测试同一手法。
  Future<void> realSettle(WidgetTester tester, {int rounds = 60}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  Future<void> tapModel(
    WidgetTester tester,
    String displayName,
  ) async {
    final item = find.text(displayName);
    await tester.ensureVisible(item);
    await tester.pump(const Duration(milliseconds: 30));
    await tester.tap(item, warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 16));
  }

  testWidgets('快速两次选择：慢请求不覆盖最后选择，摘要/协调点/画像一致', (tester) async {
    final gate = Completer<void>();
    final scope = buildDemoScope(deepseekGate: gate);
    await tester.pumpWidget(pumpWizard(scope.bridge));
    await tester.pumpAndSettle();

    await openPicker(tester);
    // 先点 DeepSeek（加载挂起），再点 Kimi（立即完成）
    await tapModel(tester, '仿真 · DeepSeek-V4.1-Flash');
    await tapModel(tester, '仿真 · Kimi-K3.1-Pro');

    gate.complete();
    await realSettle(tester);

    // sheet 恰好关闭一次（无重复 pop；若双 pop，向导页会一同被弹掉）
    expect(find.byType(DefaultModelPickerSheet), findsNothing);
    expect(find.byType(DirectorWizardPage), findsOneWidget);
    // 向导摘要=最后选择；演示说明行随桥出现
    expect(find.textContaining('仿真 · Kimi-K3.1-Pro'), findsWidgets);
    expect(find.textContaining('当前为仿真模型'), findsOneWidget);
    // 协调点与能力画像=最后选择的候选（保守档）
    expect(scope.selection.current.id, 'kimi-k3.1-pro');
    expect(scope.selection.capabilities.streamingToolCallsReliable, isFalse);
  });

  testWidgets('绑定失败：sheet 保持打开可重试，向导不推进；重选有效项成功', (tester) async {
    final scope = buildDemoScope(withBroken: true);
    await tester.pumpWidget(pumpWizard(scope.bridge));
    await tester.pumpAndSettle();

    await openPicker(tester);
    await tapModel(tester, '仿真 · 损坏模型');
    await realSettle(tester, rounds: 20);

    // 失败回执：sheet 不关、无成功 toast、页面提示可重试、向导未确认。
    // （提示条文案在页面与 sheet 两个 Scaffold 各渲染一份——ScaffoldMessenger
    // 群播语义，因此 findsWidgets）
    expect(find.byType(DefaultModelPickerSheet), findsOneWidget);
    expect(find.textContaining('演示模型切换失败'), findsWidgets);
    expect(
      find.textContaining('由 仿真 ·'),
      findsNothing,
      reason: '绑定失败不得触发向导推进或成功提示',
    );

    // 就地重试有效项：成功关闭并向导确认
    await tapModel(tester, '仿真 · DeepSeek-V4.1-Flash');
    await realSettle(tester);
    expect(find.byType(DefaultModelPickerSheet), findsNothing);
    expect(find.textContaining('仿真 · DeepSeek-V4.1-Flash'), findsWidgets);
    expect(scope.selection.current.id, 'deepseek-v4.1-flash');
    expect(scope.selection.capabilities.streamingToolCallsReliable, isTrue);
  });

  testWidgets('关闭选择器后迟到返回：未提交请求取消，向导保持原选择', (tester) async {
    final gate = Completer<void>();
    final scope = buildDemoScope(deepseekGate: gate);
    await tester.pumpWidget(pumpWizard(scope.bridge));
    await tester.pumpAndSettle();

    await openPicker(tester);
    await tapModel(tester, '仿真 · DeepSeek-V4.1-Flash');
    // 用户在绑定完成前手动关闭 sheet：未提交请求被取消失效
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    expect(find.byType(DefaultModelPickerSheet), findsNothing);
    expect(find.byType(DirectorWizardPage), findsOneWidget);

    // 迟到返回：取消语义——不换包、不确认向导选择、静默无异常
    gate.complete();
    await realSettle(tester);
    expect(tester.takeException(), isNull);
    expect(
      find.byType(DirectorWizardPage),
      findsOneWidget,
      reason: '不得出现多余 pop 把向导页一并弹掉',
    );
    expect(
      find.textContaining('由 仿真 · DeepSeek'),
      findsNothing,
      reason: '未提交的迟到选择不得确认向导',
    );
    expect(scope.selection.current.id, 'glm-5.3', reason: '原完整选择保持');
  });

  testWidgets('首轮已锁定：选择被拒绝并提示，sheet 保持打开向导不变', (tester) async {
    final scope = buildDemoScope();
    scope.selection.lock(); // 首轮已开始（等价真实回放触发的锁定）
    await tester.pumpWidget(pumpWizard(scope.bridge));
    await tester.pumpAndSettle();

    await openPicker(tester);
    await tapModel(tester, '仿真 · Kimi-K3.1-Pro');
    await realSettle(tester, rounds: 20);

    expect(
      find.byType(DefaultModelPickerSheet),
      findsOneWidget,
      reason: '锁定后绑定失败：sheet 保持打开',
    );
    expect(find.textContaining('演示模型切换失败'), findsWidgets);
    expect(
      find.textContaining('由 仿真 ·'),
      findsNothing,
      reason: '锁定后绑定被拒，向导确认不发生',
    );
    expect(scope.selection.current.id, 'glm-5.3', reason: '原选择保持');
  });

  testWidgets('排队中的未提交选择随关闭取消：已提交选择不受影响', (tester) async {
    final gate = Completer<void>();
    final scope = buildDemoScope(deepseekGate: gate);
    await tester.pumpWidget(pumpWizard(scope.bridge));
    await tester.pumpAndSettle();

    // 先提交初始候选 glm（同候选快速通道），向导就绪
    await openPicker(tester);
    await tapModel(tester, '仿真 · GLM-5.3');
    await realSettle(tester);
    expect(scope.selection.current.id, 'glm-5.3');
    expect(find.byType(DefaultModelPickerSheet), findsNothing);
    // 成功提示条过期后再重开选择器
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    // 重开选择器：A(deepseek) 加载挂起 → B(kimi) 排队（尚未开始执行）
    // → 关闭选择器取消——取消时机必须在 B 进入自身加载/保存之前
    final reopen = find.text('换一个主编');
    await tester.ensureVisible(reopen);
    await tester.tap(reopen);
    await tester.pumpAndSettle();
    expect(find.byType(DefaultModelPickerSheet), findsOneWidget);
    await tapModel(tester, '仿真 · DeepSeek-V4.1-Flash');
    await tapModel(tester, '仿真 · Kimi-K3.1-Pro');
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();

    // 释放 A：执行中的 A 与排队中的 B 都取消；已提交的 glm 不受影响
    gate.complete();
    await realSettle(tester);
    expect(tester.takeException(), isNull);
    expect(
      find.textContaining('演示模型切换失败'),
      findsNothing,
      reason: '取消静默：无错误回执',
    );
    expect(
      scope.selection.current.id,
      'glm-5.3',
      reason: '排队请求取消，已提交选择保持',
    );
    // 完成屏障采用原已提交候选并锁定
    final committed = await scope.selection.settleForSessionEntry();
    expect(committed, 'demo-narrator-glm');
    expect(scope.selection.locked, isTrue);
  });

  testWidgets('取消后重新发起的选择可正常提交', (tester) async {
    final gate = Completer<void>();
    final scope = buildDemoScope(deepseekGate: gate);
    await tester.pumpWidget(pumpWizard(scope.bridge));
    await tester.pumpAndSettle();

    // A(deepseek) 加载挂起 → B(kimi) 排队 → 关闭选择器取消两请求
    await openPicker(tester);
    await tapModel(tester, '仿真 · DeepSeek-V4.1-Flash');
    await tapModel(tester, '仿真 · Kimi-K3.1-Pro');
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    gate.complete();
    await realSettle(tester);
    expect(tester.takeException(), isNull);
    expect(find.textContaining('演示模型切换失败'), findsNothing);
    expect(
      scope.selection.current.id,
      'glm-5.3',
      reason: '执行中与排队中的请求都取消：原选择保持',
    );
    expect(
      find.textContaining('选一个模型'),
      findsOneWidget,
      reason: '无确认选择：模型步仍在选择入口',
    );

    // 取消之后重新发起：正常提交并确认向导
    await openPicker(tester);
    await tapModel(tester, '仿真 · Kimi-K3.1-Pro');
    await realSettle(tester);
    expect(find.byType(DefaultModelPickerSheet), findsNothing);
    expect(scope.selection.current.id, 'kimi-k3.1-pro');
    expect(find.textContaining('Kimi-K3.1-Pro'), findsWidgets);
  });
}
