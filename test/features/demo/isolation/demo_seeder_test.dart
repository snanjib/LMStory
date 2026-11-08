import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/network/dio_client.dart';
import 'package:lmstory/core/network/llm_adapters/llm_adapter_factory.dart';
import 'package:lmstory/core/storage/preferences.dart';
import 'package:lmstory/features/advanced/presentation/advanced_mode_flag.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/demo/data/demo_preferences.dart';
import 'package:lmstory/features/demo/data/demo_secure_storage.dart';
import 'package:lmstory/features/demo/data/demo_seeder.dart';
import 'package:lmstory/features/demo/domain/demo_scene.dart';
import 'package:lmstory/features/settings/data/datasources/api_key_datasource.dart';
import 'package:lmstory/features/settings/data/repositories/api_preset_repository_impl.dart';
import 'package:lmstory/features/settings/domain/entities/model_capability.dart';
import 'package:lmstory/features/templates/data/repositories/template_repository_impl.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late AppDatabase db;
  late DemoSecureStorage secure;
  late DemoPreferences prefs;
  late Preferences realPrefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      // 模拟重看用户已有真实配置（种子必须清空这些键的演示侧视图）
      'user_overrides':
          '{"broadcast_chat.preset_id":"real-preset","broadcast_chat.model_id":"real-model"}',
      'advanced_mode_enabled': false,
    });
    db = AppDatabase.forTesting(NativeDatabase.memory());
    secure = DemoSecureStorage();
    realPrefs = Preferences();
    prefs = DemoPreferences(fallback: realPrefs);
  });

  tearDown(() => db.close());

  ApiPresetRepositoryImpl repo() => ApiPresetRepositoryImpl(
        database: db,
        apiKeyDatasource: ApiKeyDatasource(secureStorage: secure),
        dioClient: DioClient(),
        adapterFactory: LlmAdapterFactory(),
      );

  test('播种：虚拟供应商+双模型+占位 Key+模板+偏好覆盖', () async {
    final result = await seedDemoEnvironment(
      db,
      secure,
      prefs,
      localeTag: 'zh-CN',
    );

    final presets = await repo().getAllPresets();
    expect(presets, hasLength(1));
    final preset = presets.single;
    expect(preset.presetId, result.presetId);
    expect(preset.baseUrl, DemoSeedIds.invalidBaseUrl);
    expect(
      preset.cachedModels.map((m) => m.modelId).toSet(),
      {DemoSeedIds.chatModelId, DemoSeedIds.embeddingModelId},
    );
    final emb = preset.cachedModels
        .singleWhere((m) => m.modelId == DemoSeedIds.embeddingModelId);
    expect(emb.type, ModelType.embedding);

    // 占位 Key 在内存
    expect(
      await secure.read('api_key_${preset.presetId}'),
      DemoSeedIds.placeholderApiKey,
    );

    // 内置模板就位
    final tpl =
        await TemplateRepositoryImpl(db).getTemplate('builtin-isekai-narrator');
    expect(tpl, isNotNull);
    expect(tpl.content, isNotEmpty);

    // 偏好 overlay：模型键被删除标记遮蔽、导演入口强制可见
    expect(await prefs.getString('broadcast_chat.preset_id'), isNull);
    expect(await prefs.getBool(AdvancedModeFlagNotifier.prefKey), true);
    // 真实侧不被改动
    expect(
      await realPrefs.getBool(AdvancedModeFlagNotifier.prefKey),
      false,
      reason: '真实偏好零写入（导演开关仍为用户原值）',
    );
  });

  test('幂等：二次播种清旧重建（旧 preset/Key 不残留）', () async {
    final first =
        await seedDemoEnvironment(db, secure, prefs, localeTag: 'zh-CN');
    final second =
        await seedDemoEnvironment(db, secure, prefs, localeTag: 'zh-CN');

    expect(second.presetId, isNot(first.presetId));
    final presets = await repo().getAllPresets();
    expect(presets, hasLength(1));
    expect(
      await secure.read('api_key_${first.presetId}'),
      isNull,
      reason: '旧 run 的占位 Key 必须随 deleteAll 清除',
    );
  });

  test('locale 感知命名：en 命名供应商', () async {
    await seedDemoEnvironment(db, secure, prefs, localeTag: 'en-US');
    final presets = await repo().getAllPresets();
    expect(presets.single.name, contains('Demo'));
  });
}
