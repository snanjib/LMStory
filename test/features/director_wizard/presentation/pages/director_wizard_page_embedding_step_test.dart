import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/advanced_config.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/features/director_wizard/presentation/pages/director_wizard_page.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/entities/model_capability.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/settings/presentation/controllers/settings_controller.dart';
import 'package:lmstory/i18n/strings.g.dart';

import '../../../../test_helpers/wizard_fake_settings_notifier.dart';
import '../../../../test_helpers/wizard_page_actions.dart';

/// 嵌入步 UI 两路径：配上（展开选择器）/暂时跳过（强制显式选择前下一步
/// 关闭）、已配置现状卡+就按现状继续/换一个（无关闭入口）；
/// 以及完整第二供应商接入流（贴 Key→拉取→选嵌入模型→写新 preset）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await LocaleSettings.setLocale(AppLocale.zhCn);
  });

  /// 记录写入的 settings repo 桩（写键断言用）。
  late _RecordingSettingsRepo repo;

  ApiPreset keyedPreset() => ApiPreset(
        presetId: 'preset-1',
        name: '测试供应商',
        baseUrl: 'https://example.com',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        cachedModels: const [
          ModelInfo(modelId: 'model-1'),
          ModelInfo(modelId: 'emb-1', type: ModelType.embedding),
        ],
      );

  Future<void> pumpWizard(
    WidgetTester tester, {
    required FakeWizardSettingsNotifier fake,
    AdvancedConfig advancedConfig = const AdvancedConfig(),
  }) async {
    repo = _RecordingSettingsRepo();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsNotifierProvider.overrideWith((ref) => fake),
          settingsRepositoryProvider.overrideWithValue(repo),
          advancedConfigProvider.overrideWith((ref) async => advancedConfig),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            theme:
                ThemeCatalog.assemble(const LmAppearance(), Brightness.light),
            home: const DirectorWizardPage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 模型步就绪后进入嵌入步
    await pickWizardGmViaSheet(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
  }

  ElevatedButton nextButton() =>
      find.widgetWithText(ElevatedButton, '下一步').evaluate().single.widget
          as ElevatedButton;

  testWidgets('未配置+有既有嵌入模型：强制显式选择；配上后选行即写两键', (tester) async {
    final fake = FakeWizardSettingsNotifier(
      initialPresets: [keyedPreset()],
      keyedPresetIds: const {'preset-1'},
    );
    await pumpWizard(tester, fake: fake);

    expect(find.textContaining('按「意思相近」'), findsOneWidget, reason: '教学块');
    expect(find.text('配上（推荐）'), findsOneWidget);
    expect(find.text('暂时跳过'), findsOneWidget);
    expect(
      nextButton().enabled,
      isFalse,
      reason: '未显式选择前下一步不放行',
    );
    expect(find.text('emb-1'), findsNothing, reason: '选择器默认收起');

    await tester.tap(find.text('配上（推荐）'));
    await tester.pumpAndSettle();
    expect(find.text('emb-1'), findsOneWidget, reason: '展开后只列嵌入类型模型');

    await tester.ensureVisible(find.text('emb-1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('emb-1'));
    await tester.pumpAndSettle();

    expect(
      repo.writes,
      containsPair('advanced.embedding_preset_id', 'preset-1'),
    );
    expect(repo.writes, containsPair('advanced.embedding_model_id', 'emb-1'));
    expect(nextButton().enabled, isTrue, reason: '选定后放行');
  });

  testWidgets('未配置：暂时跳过零写入，跳过后放行', (tester) async {
    final fake = FakeWizardSettingsNotifier(
      initialPresets: [keyedPreset()],
      keyedPresetIds: const {'preset-1'},
    );
    await pumpWizard(tester, fake: fake);

    expect(nextButton().enabled, isFalse, reason: '强制显式选择');

    await tester.tap(find.text('暂时跳过'));
    await tester.pumpAndSettle();

    expect(
      repo.writes.keys.where((k) => k.startsWith('advanced.embedding')),
      isEmpty,
      reason: '跳过=FTS5 兜底，不碰键',
    );
    expect(repo.removes, isEmpty);
    expect(nextButton().enabled, isTrue);
  });

  testWidgets('已配置：现状卡+默认选中就按现状继续；无关闭入口；点保留写回原值', (
    tester,
  ) async {
    final fake = FakeWizardSettingsNotifier(
      initialPresets: [keyedPreset()],
      keyedPresetIds: const {'preset-1'},
    );
    await pumpWizard(
      tester,
      fake: fake,
      advancedConfig: const AdvancedConfig(
        embeddingPresetId: 'preset-1',
        embeddingModelId: 'emb-1',
      ),
    );

    expect(find.textContaining('管记忆'), findsOneWidget, reason: '现状卡白话');
    expect(find.textContaining('emb-1'), findsOneWidget, reason: '现状展示');
    expect(find.text('就按现状继续'), findsOneWidget);
    expect(find.text('换一个'), findsOneWidget);
    expect(find.textContaining('关闭'), findsNothing, reason: '向导内无关闭入口');
    expect(nextButton().enabled, isTrue, reason: '已配置默认高亮直接放行');

    // 点保留：把入口快照写回两键（F4 语义）
    await tester.tap(find.text('就按现状继续'));
    await tester.pumpAndSettle();
    expect(
      repo.writes,
      containsPair('advanced.embedding_preset_id', 'preset-1'),
    );
    expect(repo.writes, containsPair('advanced.embedding_model_id', 'emb-1'));
  });

  testWidgets('完整第二供应商流：贴 Key→拉取→选嵌入模型→写新 preset 两键', (
    tester,
  ) async {
    final fake = FakeWizardSettingsNotifier(
      initialPresets: [keyedPreset()],
      keyedPresetIds: const {'preset-1'},
      fetchModelsResult: const [
        ModelInfo(modelId: 'chat-x'),
        ModelInfo(modelId: 'emb-x', type: ModelType.embedding),
      ],
    );
    await pumpWizard(tester, fake: fake);

    await tester.tap(find.text('配上（推荐）'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('接一家新供应商'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('接一家新供应商'));
    await tester.pumpAndSettle();

    // 流内第二框 = API Key（名字已预填模板名）
    await tester.enterText(find.byType(TextField).at(1), 'sk-emb');
    await tester.ensureVisible(find.text('创建并获取模型列表'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('创建并获取模型列表'));
    await tester.pumpAndSettle();

    expect(find.text('emb-x'), findsOneWidget, reason: '只列嵌入类型');
    expect(find.text('chat-x'), findsNothing);

    await tester.ensureVisible(find.text('emb-x'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('emb-x'));
    await tester.pumpAndSettle();

    expect(
      repo.writes,
      containsPair('advanced.embedding_preset_id', 'new-preset'),
    );
    expect(
      repo.writes,
      containsPair('advanced.embedding_model_id', 'emb-x'),
    );
  });
}

class _RecordingSettingsRepo implements SettingsRepository {
  final Map<String, dynamic> writes = {};
  final List<String> removes = [];

  @override
  Future<void> setUserOverride(String key, dynamic value) async {
    writes[key] = value;
  }

  @override
  Future<void> removeUserOverride(String key) async {
    removes.add(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
