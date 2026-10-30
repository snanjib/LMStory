import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/features/director_wizard/domain/entities/director_wizard_outcome.dart';
import 'package:lmstory/features/director_wizard/presentation/pages/director_wizard_page.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/presentation/controllers/settings_controller.dart';
import 'package:lmstory/i18n/strings.g.dart';

import '../../../../test_helpers/wizard_fake_settings_notifier.dart';
import '../../../../test_helpers/wizard_page_actions.dart';

/// 结果收集盒：push 的 await 结果在异步闭包里落地。
class ResultBox {
  DirectorWizardOutcome? value;
  bool popped = false;
}

/// 导演向导分步页骨架：三步步进、上一步/下一步、完成携带结果、
/// 跳过丢弃退出（退出即弃）。模型步门控就绪后放行下一步。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await LocaleSettings.setLocale(AppLocale.zhCn);
  });

  FakeWizardSettingsNotifier configuredFake() {
    final fake = FakeWizardSettingsNotifier(
      initialPresets: [
        ApiPreset(
          presetId: 'preset-1',
          name: '测试供应商',
          baseUrl: 'https://example.com',
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
          cachedModels: const [ModelInfo(modelId: 'model-1')],
        ),
      ],
      keyedPresetIds: const {'preset-1'},
    );
    return fake;
  }

  Future<ResultBox> pumpShell(
    WidgetTester tester, {
    required FakeWizardSettingsNotifier fake,
  }) async {
    final box = ResultBox();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [settingsNotifierProvider.overrideWith((ref) => fake)],
        child: TranslationProvider(
          child: MaterialApp(
            theme:
                ThemeCatalog.assemble(const LmAppearance(), Brightness.light),
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () async {
                      final outcome = await Navigator.of(context)
                          .push<DirectorWizardOutcome>(
                        MaterialPageRoute<DirectorWizardOutcome>(
                          builder: (_) => const DirectorWizardPage(),
                        ),
                      );
                      box
                        ..value = outcome
                        ..popped = true;
                    },
                    child: const Text('open-wizard'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open-wizard'));
    await tester.pumpAndSettle();
    return box;
  }

  /// 模型步选好模型（已配置分支直选 model-1）——门控放行。
  Future<void> pickModel(WidgetTester tester) async {
    await pickWizardGmViaSheet(tester);
    await tester.pumpAndSettle();
  }

  testWidgets('三步骨架：步进指示 + 上一步/下一步往返', (tester) async {
    await pumpShell(tester, fake: configuredFake());

    expect(find.text('步骤 1 / 3'), findsOneWidget);
    // 首步不渲染上一步
    expect(find.text('上一步'), findsNothing);

    await pickModel(tester);
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(find.text('步骤 2 / 3'), findsOneWidget);
    expect(find.text('上一步'), findsOneWidget);

    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(find.text('步骤 3 / 3'), findsOneWidget);
    // 末步渲染完成而非下一步
    expect(find.text('下一步'), findsNothing);
    expect(find.text('完成'), findsOneWidget);

    await tester.tap(find.text('上一步'));
    await tester.pumpAndSettle();
    expect(find.text('步骤 2 / 3'), findsOneWidget);
  });

  testWidgets('模型步未选模型：下一步保持门控，停在步骤 1', (tester) async {
    await pumpShell(tester, fake: configuredFake());

    final nextButton = find.widgetWithText(ElevatedButton, '下一步');
    expect(tester.widget<ElevatedButton>(nextButton).enabled, isFalse);
    await tester.tap(nextButton);
    await tester.pumpAndSettle();
    expect(find.text('步骤 1 / 3'), findsOneWidget, reason: 'GM 未就绪不放行');
  });

  testWidgets('末步完成：pop 携带 GM 覆盖与空规则（跟随全局）', (tester) async {
    final box = await pumpShell(tester, fake: configuredFake());

    await pickModel(tester);
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    expect(box.popped, isTrue, reason: '完成应 pop 向导页');
    expect(box.value, isNotNull);
    // 模型步产物进 phaseModels；规则步跳过 = null（跟随全局兜底）
    expect(box.value!.phaseModels.generatingPresetId, 'preset-1');
    expect(box.value!.phaseModels.generatingModelId, 'model-1');
    expect(box.value!.systemPromptOverride, isNull);
  });

  testWidgets('AppBar 跳过：pop 无结果（退出即弃）', (tester) async {
    final box = await pumpShell(tester, fake: configuredFake());

    await tester.tap(find.text('跳过'));
    await tester.pumpAndSettle();

    expect(box.popped, isTrue);
    expect(box.value, isNull, reason: '跳过退出不产生会话配置');
  });

  testWidgets('步进往返：步骤内容与步号保持', (tester) async {
    await pumpShell(tester, fake: configuredFake());

    expect(find.text('选你的对话模型'), findsOneWidget);
    await pickModel(tester);
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(find.text('嵌入模型'), findsOneWidget);
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(find.text('项目规则'), findsOneWidget);
    await tester.tap(find.text('上一步'));
    await tester.pumpAndSettle();
    expect(find.text('嵌入模型'), findsOneWidget, reason: '回退后步骤内容仍在');
    // 再回到模型步：选择保持（门控仍放行）
    await tester.tap(find.text('上一步'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<ElevatedButton>(find.widgetWithText(ElevatedButton, '下一步'))
          .enabled,
      isTrue,
      reason: '步进往返模型选择不丢',
    );
  });
}
