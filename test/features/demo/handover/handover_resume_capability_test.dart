import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/config_loader.dart';
import 'package:lmstory/core/network/dio_client.dart';
import 'package:lmstory/core/network/llm_adapters/llm_adapter_factory.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/chat/data/repositories/chat_repository_impl.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart';
import 'package:lmstory/features/demo/data/demo_preferences.dart';
import 'package:lmstory/features/demo/data/demo_secure_storage.dart';
import 'package:lmstory/features/demo/data/demo_session_handover.dart';
import 'package:lmstory/features/settings/data/datasources/api_key_datasource.dart';
import 'package:lmstory/features/settings/data/repositories/api_preset_repository_impl.dart';
import 'package:lmstory/features/settings/data/repositories/settings_repository_impl.dart';

/// T-HO-4：交接后正式接续能力。
///
/// 不调用真实模型（未授权）——验证止步于配置解析前提：会话级虚拟覆盖
/// 已清空 → 用户配置真实 GM 后解析回退全局成功、next_turn 允许继续、
/// 全库无演示供应商悬挂引用。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase demoDb;
  late AppDatabase realDb;
  late DemoSecureStorage secure;
  late DemoPreferences prefs;
  late ChatRepositoryImpl demoRepo;
  late ConfigurationResolver resolver;
  late ApiPresetRepositoryImpl realPresetRepo;
  late SettingsRepositoryImpl realSettingsRepo;

  setUp(() async {
    demoDb = AppDatabase.forTesting(NativeDatabase.memory());
    realDb = AppDatabase.forTesting(NativeDatabase.memory());
    secure = DemoSecureStorage();
    prefs = DemoPreferences();
    demoRepo = ChatRepositoryImpl(database: demoDb);

    // 「正式环境」的解析链：真实 SettingsRepositoryImpl + 演示内存
    // Preferences/SecureStorage 充当用户正式偏好与 Key 的替身
    //（测试不触真实 SharedPreferences/钥匙串，语义与正式一致）
    final keyDatasource = ApiKeyDatasource(secureStorage: secure);
    realSettingsRepo = SettingsRepositoryImpl(
      preferences: prefs,
      configLoader: ConfigLoader(),
      apiKeyDatasource: keyDatasource,
    );
    realPresetRepo = ApiPresetRepositoryImpl(
      database: realDb,
      apiKeyDatasource: keyDatasource,
      dioClient: DioClient(),
      adapterFactory: LlmAdapterFactory(),
    );
    resolver = ConfigurationResolver(
      presetRepository: realPresetRepo,
      settingsRepository: realSettingsRepo,
      logger: const Logger('test'),
    );
  });

  tearDown(() async {
    await demoDb.close();
    await realDb.close();
  });

  test('交接后配置真实 GM → 解析回退全局成功、next_turn 允许继续、无悬挂引用', () async {
    // 演示库：完成一回合的会话（引用虚拟供应商）
    final demoSession = await demoRepo.createSession(
      title: '演示会话',
      mode: 'advanced',
      modelId: 'demo-model-x',
      presetId: 'demo-preset-x',
    );
    final sid = demoSession.sessionId;
    await demoDb.customStatement(
      'UPDATE chat_sessions SET generating_preset_id = ?, '
      'generating_model_id = ?, next_turn = 2 WHERE session_id = ?',
      ['demo-preset-x', 'demo-model-x', sid],
    );

    final result = await DemoSessionHandover().run(
      demoDb: demoDb,
      realDb: realDb,
      sourceSessionId: sid,
    );
    expect(result, DemoHandoverResult.imported);

    final realRepo = ChatRepositoryImpl(database: realDb);
    final sessionRow = await realRepo.getSession(sid);
    expect(sessionRow, isNotNull);

    // —— 交接后、用户未配置真实模型：解析失败（E010 语义，不可误跑）——
    final before = await resolver.resolveAdvancedGeneratingNamingConfig(
      sessionRow,
    );
    expect(before, isNull, reason: '未配置真实 GM 前不可发起下一轮（真实行为）');

    // —— 用户在正式环境配置真实供应商 + Key + 全局导演 GM ——
    final preset = await realPresetRepo.createPreset(
      name: '真实供应商',
      baseUrl: 'https://real.example/v1',
    );
    await secure.write('api_key_${preset.presetId}', 'real-key');
    await realSettingsRepo.setUserOverride(
      'advanced.phase_models.generating_preset_id',
      preset.presetId,
    );
    await realSettingsRepo.setUserOverride(
      'advanced.phase_models.generating_model_id',
      'real-model',
    );

    // —— 会话级覆盖已空 → 回退全局 → 解析成功（接续前提成立）——
    final refreshed = await realRepo.getSession(sid);
    final after = await resolver.resolveAdvancedGeneratingNamingConfig(
      refreshed,
    );
    expect(after, isNotNull, reason: '会话虚拟覆盖清空后必须回退全局真实配置');
    expect(after!.modelId, 'real-model');
    expect(after.presetId, preset.presetId);

    expect(refreshed.nextTurn, 2, reason: 'next_turn=2 允许下一轮');

    // 全库无演示供应商悬挂引用
    final refs = await realDb
        .customSelect(
          'SELECT COUNT(*) AS n FROM chat_sessions WHERE '
          "generating_preset_id LIKE 'demo-%' OR preset_id LIKE 'demo-%'",
        )
        .get();
    expect(refs.first.read<int>('n'), 0);
    // 演示供应商不入正式库
    final presets = await realDb
        .customSelect('SELECT COUNT(*) AS n FROM api_presets')
        .get();
    expect(presets.first.read<int>('n'), 1, reason: '只有用户配置的真实供应商');
  });
}
