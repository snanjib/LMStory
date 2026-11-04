import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/advanced_config.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/features/director_wizard/domain/entities/director_wizard_outcome.dart';
import 'package:lmstory/features/director_wizard/presentation/pages/director_wizard_page.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/settings/presentation/controllers/settings_controller.dart';
import 'package:lmstory/i18n/strings.g.dart';

import '../../../../test_helpers/wizard_fake_settings_notifier.dart';
import '../../../../test_helpers/wizard_page_actions.dart';

/// 完成事务写入时序：未配置分支在完成时统一下发全局默认四键
/// （broadcast_chat 两键 + 导演 GM 两键）；已配置分支只带会话覆盖，
/// 全局键零写入。嵌入/模板键在各步确认时已写，不在完成面重复。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await LocaleSettings.setLocale(AppLocale.zhCn);
  });

  ApiPreset keyedPreset() => ApiPreset(
        presetId: 'preset-1',
        name: '测试供应商',
        baseUrl: 'https://example.com',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        cachedModels: const [ModelInfo(modelId: 'model-1')],
      );

  Future<_ResultBox> pumpShell(
    WidgetTester tester, {
    required FakeWizardSettingsNotifier fake,
    required _RecordingSettingsRepo repo,
  }) async {
    final box = _ResultBox();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsNotifierProvider.overrideWith((ref) => fake),
          settingsRepositoryProvider.overrideWithValue(repo),
          advancedConfigProvider.overrideWith(
            (ref) async => const AdvancedConfig(),
          ),
        ],
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

  testWidgets('未配置分支完成：统一下发全局默认四键', (tester) async {
    final fake = FakeWizardSettingsNotifier(
      fetchModelsResult: const [ModelInfo(modelId: 'model-a')],
    );
    final repo = _RecordingSettingsRepo();
    final box = await pumpShell(tester, fake: fake, repo: repo);

    // 未配置链路：贴 Key → 创建拉取 → 选模型 → 直达完成
    await tester.enterText(find.byType(TextField).at(1), 'sk-test');
    await tester.ensureVisible(find.text('创建并获取模型列表'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('创建并获取模型列表'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('model-a'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('model-a'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    await skipWizardEmbedding(tester);
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    expect(box.popped, isTrue);
    expect(
      fake.calls,
      contains('setDefaultModel:new-preset:model-a'),
      reason: 'Simple 默认模型顺带写全局（fake 记录调用）',
    );
    expect(
      repo.writes,
      containsPair(
        'advanced.phase_models.generating_preset_id',
        'new-preset',
      ),
      reason: '导演 GM 顺带写全局（下次新建不必重配）',
    );
    expect(
      repo.writes,
      containsPair('advanced.phase_models.generating_model_id', 'model-a'),
    );
    // 产物：会话覆盖与全局同值（双保险，且本会话不受后续全局改动影响）
    expect(box.value!.phaseModels.generatingPresetId, 'new-preset');
    expect(box.value!.systemPromptOverride, isNull, reason: '未碰规则步');
  });

  testWidgets('已配置分支完成：全局键零写入，只带会话覆盖', (tester) async {
    final fake = FakeWizardSettingsNotifier(
      initialPresets: [keyedPreset()],
      keyedPresetIds: const {'preset-1'},
    );
    final repo = _RecordingSettingsRepo();
    final box = await pumpShell(tester, fake: fake, repo: repo);

    await pickWizardGmViaSheet(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    await skipWizardEmbedding(tester);
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    expect(box.popped, isTrue);
    expect(
      repo.writes.keys
          .where(
            (k) => k.startsWith('broadcast_chat') || k.contains('phase_models'),
          )
          .isEmpty,
      isTrue,
      reason: '已配置用户全局不动，只写会话覆盖',
    );
    expect(box.value!.phaseModels.generatingModelId, 'model-1');
  });
}

class _ResultBox {
  DirectorWizardOutcome? value;
  bool popped = false;
}

class _RecordingSettingsRepo implements SettingsRepository {
  final Map<String, dynamic> writes = {};

  @override
  Future<void> setUserOverride(String key, dynamic value) async {
    writes[key] = value;
  }

  @override
  Future<Map<String, dynamic>> getUserOverrides() async => const {};

  @override
  Future<String?> getApiKey(String presetId) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
