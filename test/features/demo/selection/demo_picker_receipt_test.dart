import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/settings/presentation/controllers/settings_controller.dart';
import 'package:lmstory/features/settings/presentation/widgets/default_model_picker_sheet.dart';
import 'package:lmstory/features/templates/domain/entities/template.dart';
import 'package:lmstory/features/templates/domain/repositories/template_repository.dart';
import 'package:lmstory/i18n/strings.g.dart';

import 'demo_picker_hint_test.dart' show demoModels;

/// 模型选择 sheet 选择回执回归：
/// - 提交抛错=失败回执：sheet 保持打开可就地重试，不关闭、不弹成功提示；
/// - 正常完成=成功：关闭一次 + 成功 snackbar；
/// - 快速连点：序次仲裁只关闭一次，不重复 pop；
/// - 处理中手动关闭：迟到结果静默，不再 pop/不弹过期提示；
/// - 被更新选择取代：只有最新选择的成功驱动关闭；
/// - onBeforeSelect 取消钩子行为不变（正式嵌入确认路径）。
const successToast = '已切换为该模型';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('失败回执：提交抛错不关闭不弹成功，可就地重试成功', (tester) async {
    var attempts = 0;
    await _pump(
      tester,
      onSelected: (presetId, modelId) async {
        attempts++;
        if (attempts == 1) {
          throw StateError('synthetic bind failure');
        }
      },
    );

    await _expandGroup(tester);
    await tester.tap(find.text('仿真 · GLM-5.3'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // 失败：sheet 保持打开，无成功提示
    expect(find.byType(DefaultModelPickerSheet), findsOneWidget);
    expect(find.text(successToast), findsNothing);

    // 就地重试：第二次成功 → 关闭 + 成功提示
    await tester.tap(find.text('仿真 · GLM-5.3'));
    await tester.pumpAndSettle();
    expect(find.byType(DefaultModelPickerSheet), findsNothing);
    expect(find.text(successToast), findsOneWidget);
    expect(attempts, 2);
  });

  testWidgets('成功回执：一次选择只关闭一次并弹成功提示', (tester) async {
    final observer = _PopCountingObserver();
    await _pump(tester, observer: observer, onSelected: (_, __) async {});
    await _expandGroup(tester);

    await tester.tap(find.text('仿真 · GLM-5.3'));
    await tester.pumpAndSettle();

    expect(find.byType(DefaultModelPickerSheet), findsNothing);
    expect(find.text(successToast), findsOneWidget);
    expect(observer.pops, 1, reason: '成功恰好关闭一次');
  });

  testWidgets('快速连点同一项：序次仲裁只关闭一次（防重复 pop）', (tester) async {
    final observer = _PopCountingObserver();
    final gate = Completer<void>();
    await _pump(
      tester,
      observer: observer,
      onSelected: (_, __) => gate.future,
    );
    await _expandGroup(tester);

    // 两次点击都在提交完成前发生（处理中重复点击）
    await tester.tap(find.text('仿真 · GLM-5.3'), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 16));
    await tester.tap(find.text('仿真 · GLM-5.3'), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 16));
    gate.complete();
    await tester.pumpAndSettle();

    expect(find.byType(DefaultModelPickerSheet), findsNothing);
    expect(observer.pops, 1, reason: '连点只允许一次导航 pop');
    expect(find.text(successToast), findsOneWidget);
  });

  testWidgets('处理中手动关闭：迟到成功静默，不再 pop 不弹过期提示', (tester) async {
    final observer = _PopCountingObserver();
    final gate = Completer<void>();
    await _pump(
      tester,
      observer: observer,
      onSelected: (_, __) => gate.future,
    );
    await _expandGroup(tester);

    await tester.tap(find.text('仿真 · GLM-5.3'), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 16));
    // 用户在提交完成前手动关闭 sheet（下滑/返回）
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    expect(find.byType(DefaultModelPickerSheet), findsNothing);
    expect(observer.pops, 1, reason: '手动关闭计一次 pop');

    // 迟到完成：sheet 已卸载，不得再 pop、不得弹成功
    gate.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(observer.pops, 1, reason: '迟到结果不再触发 pop');
    expect(find.text(successToast), findsNothing);
  });

  testWidgets('被更新选择取代：只有最新选择的成功驱动关闭', (tester) async {
    final observer = _PopCountingObserver();
    final gate = Completer<void>();
    await _pump(
      tester,
      observer: observer,
      // GLM 挂起（慢提交）；Kimi 立即成功
      onSelected: (_, modelId) =>
          modelId == 'demo-narrator-glm' ? gate.future : Future.value(),
    );
    await _expandGroup(tester);

    // 先点 GLM（挂起），再点 Kimi（立即成功）
    await tester.tap(find.text('仿真 · GLM-5.3'), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 16));
    await tester.tap(find.text('仿真 · Kimi-K3.1-Pro'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.byType(DefaultModelPickerSheet), findsNothing);
    expect(observer.pops, 1, reason: '只有最新选择关闭 sheet');
    expect(find.text(successToast), findsOneWidget);

    // 迟到的 GLM 成功结果：已过期，静默让位
    gate.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(observer.pops, 1, reason: '过期结果不得再次 pop');
  });

  testWidgets('onBeforeSelect 取消：sheet 保持打开（正式嵌入确认钩子不变）', (tester) async {
    await _pump(
      tester,
      onBeforeSelect: (_, __) async => false,
      onSelected: (_, __) async {},
    );
    await _expandGroup(tester);

    await tester.tap(find.text('仿真 · GLM-5.3'));
    await tester.pumpAndSettle();

    expect(
      find.byType(DefaultModelPickerSheet),
      findsOneWidget,
      reason: '确认钩子取消选择，sheet 不关闭',
    );
  });
}

Future<void> _expandGroup(WidgetTester tester) async {
  // 无预选时组默认收起：点组标题展开
  await tester.tap(find.text('演示模型（本地回放）'));
  await tester.pumpAndSettle();
}

Future<void> _pump(
  WidgetTester tester, {
  required Future<void> Function(String presetId, String modelId) onSelected,
  Future<bool> Function(String presetId, String modelId)? onBeforeSelect,
  _PopCountingObserver? observer,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsNotifierProvider.overrideWith(
          (ref) => _DemoPresetSettingsNotifier(),
        ),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          navigatorObservers: [if (observer != null) observer],
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => Scaffold(
                        body: DefaultModelPickerSheet(
                          selectedPresetId: 'demo-preset',
                          selectedModelId: null,
                          successMessage: successToast,
                          onBeforeSelect: onBeforeSelect,
                          onModelSelected: (presetId, modelId) async {
                            if (presetId == null || modelId == null) return;
                            await onSelected(presetId, modelId);
                          },
                        ),
                      ),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

class _PopCountingObserver extends NavigatorObserver {
  int pops = 0;

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pops++;
  }
}

/// 预置演示供应商（五仿真模型）的 SettingsNotifier 桩（与提示横幅回归同构）
class _DemoPresetSettingsNotifier extends SettingsNotifier {
  _DemoPresetSettingsNotifier()
      : super(
          presetRepo: _DemoPresetRepo(),
          templateRepo: _NoopTemplateRepo(),
          settingsRepo: _EmptySettingsRepo(),
        );
}

class _DemoPresetRepo implements ApiPresetRepository {
  @override
  Future<List<ApiPreset>> getAllPresets() async => [
        ApiPreset(
          presetId: 'demo-preset',
          name: '演示模型（本地回放）',
          baseUrl: 'https://demo.invalid/v1',
          createdAt: DateTime(2026, 11, 7),
          updatedAt: DateTime(2026, 11, 7),
          cachedModels: demoModels,
        ),
      ];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _NoopTemplateRepo implements TemplateRepository {
  @override
  Future<void> ensureBuiltInTemplates() async {}

  @override
  Future<List<Template>> getAllTemplates() async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _EmptySettingsRepo implements SettingsRepository {
  @override
  Future<Map<String, dynamic>> getUserOverrides() async => {};

  @override
  Future<String?> getApiKey(String presetId) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
