import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/features/director_wizard/presentation/pages/director_wizard_page.dart';
import 'package:lmstory/features/director_wizard/presentation/widgets/wizard_option_row.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/presentation/controllers/settings_controller.dart';
import 'package:lmstory/features/settings/presentation/widgets/default_model_picker_sheet.dart';
import 'package:lmstory/i18n/strings.g.dart';

import '../../../../test_helpers/wizard_fake_settings_notifier.dart';

/// 模型步 UI：两分支渲染、教学块、未配置创建链（贴 Key→拉列表→选模型）、
/// 拉取失败手填兜底、已配置弹层选择+默认预选、未就绪时下一步门控。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await LocaleSettings.setLocale(AppLocale.zhCn);
  });

  ApiPreset preset({String id = 'preset-1'}) => ApiPreset(
        presetId: id,
        name: '测试供应商',
        baseUrl: 'https://example.com',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        cachedModels: const [
          ModelInfo(modelId: 'model-1', displayName: '测试模型'),
          ModelInfo(modelId: 'model-2'),
        ],
      );

  Widget pumpWizard(FakeWizardSettingsNotifier fake) {
    return ProviderScope(
      overrides: [
        settingsNotifierProvider.overrideWith((ref) => fake),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          theme: ThemeCatalog.assemble(const LmAppearance(), Brightness.light),
          home: const DirectorWizardPage(),
        ),
      ),
    );
  }

  testWidgets('未配置分支：教学块+模板推荐+贴 Key+创建拉取+选模型 → 下一步放行', (tester) async {
    final fake = FakeWizardSettingsNotifier(
      fetchModelsResult: const [
        ModelInfo(modelId: 'model-a'),
        ModelInfo(modelId: 'model-b'),
      ],
    );
    await tester.pumpWidget(pumpWizard(fake));
    await tester.pumpAndSettle();

    expect(find.textContaining('AI 总编辑'), findsOneWidget, reason: '教学块渲染');
    expect(find.text('DeepSeek'), findsWidgets, reason: '默认推荐选中 DeepSeek');

    // 未填 Key：下一步门控关闭
    final nextButton = find.widgetWithText(ElevatedButton, '下一步');
    expect(tester.widget<ElevatedButton>(nextButton).enabled, isFalse);

    await tester.enterText(find.byType(TextField).at(1), 'sk-test');
    await tester.ensureVisible(find.text('创建并获取模型列表'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('创建并获取模型列表'));
    await tester.pumpAndSettle();

    expect(find.text('model-a'), findsOneWidget);
    expect(find.text('model-b'), findsOneWidget);

    await tester.ensureVisible(find.text('model-b'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('model-b'));
    await tester.pumpAndSettle();

    expect(find.textContaining('执笔者'), findsOneWidget, reason: '选中即解释行出现');
    expect(tester.widget<ElevatedButton>(nextButton).enabled, isTrue);
    expect(fake.savedKeys, isNotEmpty, reason: 'Key 已随创建链落库');
  });

  testWidgets('未配置分支：模板为整行选项且带推荐语（选中即解释范式）', (tester) async {
    final fake = FakeWizardSettingsNotifier();
    await tester.pumpWidget(pumpWizard(fake));
    await tester.pumpAndSettle();

    expect(
      find.byType(WizardOptionRow),
      findsWidgets,
      reason: '模板区为整行描边选项',
    );
    expect(
      find.textContaining('性价比首选'),
      findsOneWidget,
      reason: 'DeepSeek 推荐语常显',
    );
    await tester.tap(find.text('OpenAI'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('名气最大'),
      findsOneWidget,
      reason: '切模板后推荐语跟随',
    );
  });

  testWidgets('手填主模型 ID 可返回修正再保存', (tester) async {
    final fake = FakeWizardSettingsNotifier(fetchModelsFail: true);
    await tester.pumpWidget(pumpWizard(fake));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).at(1), 'sk-test');
    await tester.ensureVisible(find.text('创建并获取模型列表'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('创建并获取模型列表'));
    await tester.pumpAndSettle();

    expect(find.text('手填模型 ID'), findsOneWidget);
    // 手填框 = 第三个 TextField（名字/Key 两框禁用态仍在树中）
    final id = find.byType(TextField).at(2);
    await tester.enterText(id, 'my－model');
    await tester.ensureVisible(find.text('用这个 ID'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('用这个 ID'));
    await tester.pumpAndSettle();
    expect(find.text('核对模型 ID'), findsOneWidget);
    expect(fake.updatedModels, isEmpty);
    await tester.tap(find.text('返回修改'));
    await tester.pumpAndSettle();

    await tester.enterText(id, 'custom/my-model:v2');
    await tester.ensureVisible(find.text('用这个 ID'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('用这个 ID'));
    await tester.pumpAndSettle();

    expect(fake.updatedModels.single.$2.single.modelId, 'custom/my-model:v2');
    expect(
      tester
          .widget<ElevatedButton>(find.widgetWithText(ElevatedButton, '下一步'))
          .enabled,
      isTrue,
    );
  });

  testWidgets('已配置分支：默认模型预选（简单默认链），下一步直接放行', (tester) async {
    final fake = FakeWizardSettingsNotifier(
      initialPresets: [preset()],
      keyedPresetIds: const {'preset-1'},
      userOverrides: const {
        'broadcast_chat.preset_id': 'preset-1',
        'broadcast_chat.model_id': 'model-1',
      },
    );
    await tester.pumpWidget(pumpWizard(fake));
    await tester.pumpAndSettle();

    expect(
      find.widgetWithText(OutlinedButton, '换一个主编'),
      findsOneWidget,
      reason: '换编辑入口呈现',
    );
    expect(
      find.textContaining('由 测试模型 执笔'),
      findsOneWidget,
      reason: '默认预选的解释行',
    );
    expect(
      tester
          .widget<ElevatedButton>(find.widgetWithText(ElevatedButton, '下一步'))
          .enabled,
      isTrue,
      reason: '不换默认模型直接下一步',
    );
  });

  testWidgets('已配置分支：不平铺模型，走弹层选择后写 GM 并放行', (tester) async {
    final fake = FakeWizardSettingsNotifier(
      initialPresets: [preset()],
      keyedPresetIds: const {'preset-1'},
    );
    await tester.pumpWidget(pumpWizard(fake));
    await tester.pumpAndSettle();

    expect(find.textContaining('想给这个故事换一个编辑'), findsOneWidget);
    expect(find.text('model-1'), findsNothing, reason: '不再平铺全部模型');
    expect(find.text('model-2'), findsNothing);

    await tester.tap(find.textContaining('选一个模型'));
    await tester.pumpAndSettle();

    expect(
      find.byType(DefaultModelPickerSheet),
      findsOneWidget,
      reason: '弹出供应商分组选择器',
    );
    expect(find.text('测试供应商'), findsOneWidget, reason: '按供应商分组');
    // 无选中组默认收起（数量徽章预告模型数），点组头展开
    await tester.tap(find.text('测试供应商'));
    await tester.pumpAndSettle();
    expect(find.text('model-2'), findsOneWidget, reason: '模型在弹层内呈现');

    await tester.tap(find.text('model-2'));
    await tester.pumpAndSettle();

    expect(
      find.byType(DefaultModelPickerSheet),
      findsNothing,
      reason: '选择后弹层关闭',
    );
    expect(
      find.textContaining('model-2 执笔'),
      findsOneWidget,
      reason: '选中即解释（选中行下方）',
    );
    expect(
      tester
          .widget<ElevatedButton>(find.widgetWithText(ElevatedButton, '下一步'))
          .enabled,
      isTrue,
    );
  });

  testWidgets('已配置分支：无任何已拉取模型 → 引导接新供应商', (tester) async {
    final fake = FakeWizardSettingsNotifier(
      initialPresets: [preset().copyWith(cachedModels: const [])],
      keyedPresetIds: const {'preset-1'},
    );
    await tester.pumpWidget(pumpWizard(fake));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('还没有拉取过的模型'),
      findsOneWidget,
    );
    await tester.tap(find.text('接一家新供应商'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('AI 总编辑'),
      findsOneWidget,
      reason: '切换到供应商接入流（教学块呈现）',
    );
  });
}
