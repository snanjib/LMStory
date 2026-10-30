import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/advanced_config.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';
import 'package:lmstory/features/director_wizard/domain/entities/director_wizard_outcome.dart';
import 'package:lmstory/features/director_wizard/presentation/pages/director_wizard_page.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/entities/model_capability.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/settings/presentation/controllers/settings_controller.dart';
import 'package:lmstory/i18n/strings.g.dart';

import '../../../../test_helpers/wizard_fake_settings_notifier.dart';
import '../../../../test_helpers/wizard_page_actions.dart';

/// 终审修复轮回归：滑动越步物理拦截、完成中退出守卫、GM 列表
/// 过滤嵌入类型、保留现状回写、生成兜底重试键、切换接入流的名称同步、
/// 拒绝回退清除已确认产物。
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
        cachedModels: const [
          ModelInfo(modelId: 'model-1'),
          ModelInfo(modelId: 'emb-1', type: ModelType.embedding),
          ModelInfo(modelId: 'emb-2', type: ModelType.embedding),
        ],
      );

  Future<_ResultBox> pumpShell(
    WidgetTester tester, {
    required FakeWizardSettingsNotifier fake,
    _RecordingSettingsRepo? repo,
    AdvancedConfig advancedConfig = const AdvancedConfig(),
    bool llmFails = false,
  }) async {
    final box = _ResultBox();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsNotifierProvider.overrideWith((ref) => fake),
          settingsRepositoryProvider
              .overrideWithValue(repo ?? _RecordingSettingsRepo()),
          advancedConfigProvider.overrideWith(
            (ref) async => advancedConfig,
          ),
          configurationResolverProvider
              .overrideWithValue(const _StubResolver()),
          llmServiceProvider
              .overrideWithValue(_GenLlmService(llmFails: llmFails)),
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

  testWidgets('F1：GM 未就绪时滑动被物理拦截，嵌入步内容不可达', (tester) async {
    final fake = FakeWizardSettingsNotifier(
      fetchModelsResult: const [ModelInfo(modelId: 'model-a')],
    );
    await pumpShell(tester, fake: fake);

    // 未选模型（未就绪）——快速左滑不应露出嵌入步
    await tester.fling(
      find.byType(PageView),
      const Offset(-400, 0),
      1000,
    );
    await tester.pumpAndSettle();
    expect(find.text('步骤 1 / 3'), findsOneWidget);
    expect(
      find.textContaining('嵌入模型让导演的记忆检索更准'),
      findsNothing,
      reason: '滑动不得绕过模型步门控',
    );
  });

  testWidgets('F2：全局写入进行中点跳过无效，完成后正常交付', (tester) async {
    final gate = Completer<void>();
    final fake = FakeWizardSettingsNotifier(
      fetchModelsResult: const [ModelInfo(modelId: 'model-a')],
      setDefaultGate: gate,
    );
    final box = await pumpShell(tester, fake: fake);

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
    await tester.pump();
    // 写入未落定：跳过不得抢跑 pop
    await tester.tap(find.text('跳过'));
    await tester.pump();
    expect(
      find.byType(DirectorWizardPage),
      findsOneWidget,
      reason: '完成事务进行中退出无效',
    );
    expect(box.popped, isFalse);

    gate.complete();
    await tester.pumpAndSettle();
    expect(box.popped, isTrue);
    expect(box.value, isNotNull, reason: '写入完成后交付产物');
  });

  testWidgets('F3：未配置链路 GM 列表过滤嵌入类型模型', (tester) async {
    final fake = FakeWizardSettingsNotifier(
      fetchModelsResult: const [
        ModelInfo(modelId: 'chat-a'),
        ModelInfo(modelId: 'emb-x', type: ModelType.embedding),
      ],
    );
    await pumpShell(tester, fake: fake);

    await tester.enterText(find.byType(TextField).at(1), 'sk-test');
    await tester.ensureVisible(find.text('创建并获取模型列表'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('创建并获取模型列表'));
    await tester.pumpAndSettle();

    expect(find.text('chat-a'), findsOneWidget);
    expect(find.text('emb-x'), findsNothing, reason: '嵌入模型不得选为 GM');
  });

  testWidgets('F4：更换后反悔点保留现状 → 原配置回写', (tester) async {
    final repo = _RecordingSettingsRepo();
    final fake = FakeWizardSettingsNotifier(
      initialPresets: [keyedPreset()],
      keyedPresetIds: const {'preset-1'},
    );
    await pumpShell(
      tester,
      fake: fake,
      repo: repo,
      advancedConfig: const AdvancedConfig(
        embeddingPresetId: 'preset-1',
        embeddingModelId: 'emb-1',
      ),
    );

    await pickWizardGmViaSheet(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();

    // 更换 → 选新嵌入模型（写入新值）
    await tester.tap(find.text('换一个'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('emb-2'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('emb-2'));
    await tester.pumpAndSettle();
    expect(repo.writes['advanced.embedding_model_id'], 'emb-2');

    // 反悔 → 保留现状：原快照回写
    await tester.ensureVisible(find.text('就按现状继续'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('就按现状继续'));
    await tester.pumpAndSettle();
    expect(
      repo.writeLog.lastWhere((e) => e.$1 == 'advanced.embedding_model_id').$2,
      'emb-1',
      reason: '保留现状=把入口快照写回去（覆盖更换时写入的新值）',
    );
  });

  testWidgets('F5：生成失败兜底后仍可重试模型（重新生成可见）', (tester) async {
    final fake = FakeWizardSettingsNotifier(
      initialPresets: [keyedPreset()],
      keyedPresetIds: const {'preset-1'},
    );
    await pumpShell(
      tester,
      fake: fake,
      llmFails: true,
    );

    await pickWizardGmViaSheet(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    await skipWizardEmbedding(tester);
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('捏一个自己的世界'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('让模型替你写'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('让模型替你写'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始写'));
    await tester.pumpAndSettle();

    expect(find.textContaining('模型这次没写出来'), findsOneWidget);
    expect(find.text('重新生成'), findsOneWidget, reason: '兜底提示承诺「可以再试一次模型」，必须有入口');
  });

  testWidgets('F7：已配置空态切接新供应商 → 名称输入框预填 DeepSeek', (tester) async {
    final fake = FakeWizardSettingsNotifier(
      initialPresets: [
        ApiPreset(
          presetId: 'preset-empty',
          name: '空供应商',
          baseUrl: 'https://example.com',
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        ),
      ],
      keyedPresetIds: const {'preset-empty'},
    );
    await pumpShell(tester, fake: fake);

    await tester.ensureVisible(find.text('接一家新供应商'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('接一家新供应商'));
    await tester.pumpAndSettle();

    final nameField = find.byType(TextField).first;
    expect(
      tester.widget<TextField>(nameField).controller?.text,
      'DeepSeek',
      reason: '切换接入流后名称框须与选中模板同步',
    );
  });
}

class _ResultBox {
  DirectorWizardOutcome? value;
  bool popped = false;
}

class _StubResolver implements ConfigurationResolver {
  const _StubResolver();

  @override
  Future<NamingConfig?> resolvePresetModelNamingConfig(
    String presetId,
    String modelId,
  ) async {
    return const NamingConfig(
      baseUrl: 'https://example.com',
      apiKey: 'sk-test',
      modelId: 'model-1',
    );
  }

  @override
  Future<({Duration connectTimeout, Duration readTimeout})> resolveTimeouts() {
    return Future.value(
      (
        connectTimeout: const Duration(seconds: 15),
        readTimeout: const Duration(seconds: 30),
      ),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _GenLlmService implements LlmService {
  _GenLlmService({required this.llmFails});

  final bool llmFails;

  @override
  Future<LlmResponse> chat(LlmRequest request) async {
    if (llmFails) throw Exception('llm down');
    return const LlmResponse(content: '模型生成的世界设定ABC');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _RecordingSettingsRepo implements SettingsRepository {
  final Map<String, dynamic> writes = {};
  final List<(String, Object)> writeLog = [];

  @override
  Future<void> setUserOverride(String key, dynamic value) async {
    writes[key] = value;
    writeLog.add((key, value));
  }

  @override
  Future<Map<String, dynamic>> getUserOverrides() async => const {};

  @override
  Future<String?> getApiKey(String presetId) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
