import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/network/dio_client.dart';
import 'package:lmstory/core/network/llm_adapters/llm_adapter_factory.dart';
import 'package:lmstory/core/storage/secure_storage.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/settings/data/datasources/api_key_datasource.dart';
import 'package:lmstory/features/settings/data/repositories/api_preset_repository_impl.dart';

/// resetPreset 的 providerOptions 快照语义回归（S-1，2026-09-06）。
///
/// 口径：重置 = 把当前模板快照值写入本层。模板（ProviderTemplate）无
/// providerOptions 字段，快照值即 null——重置必须把 provider_options 列
/// 一并写空，不能残留旧值（旧行为只写 name/baseUrl/protocol/cachedModels，
/// 用户此前配置的 thinking 等参数在重置后静默续用，与「恢复为模板默认值」
/// 的 UI 承诺相悖）。
void main() {
  late AppDatabase db;
  late ApiPresetRepositoryImpl repo;

  setUp(() async {
    final nativeDb = NativeDatabase.memory();
    db = AppDatabase.forTesting(nativeDb);
    await db.customSelect('SELECT 1').get();
    repo = ApiPresetRepositoryImpl(
      database: db,
      apiKeyDatasource: ApiKeyDatasource(secureStorage: SecureStorage()),
      dioClient: DioClient(),
      adapterFactory: LlmAdapterFactory(),
    );
  });

  tearDown(() async {
    await db.close();
  });

  test('S-1：resetPreset 把 provider_options 列一并清空（模板快照=null）', () async {
    final preset = await repo.createFromTemplate(
      templateId: 'tpl-anthropic',
      name: '我的 Claude',
    );

    // 先配置 providerOptions（模拟  高级参数已设置）
    await repo.updatePreset(
      preset.presetId,
      (current) => current.copyWith(
        providerOptions: {
          'thinking': {'type': 'enabled', 'budget_tokens': 2000},
        },
      ),
    );
    final configured = await repo.getPreset(preset.presetId);
    expect(configured.providerOptions, isNotNull);

    await repo.resetPreset(preset.presetId);

    // 返回实体：不残留 providerOptions
    expect(configured.providerOptions, isNotNull, reason: '前置条件自检');
    final after = await repo.getPreset(preset.presetId);
    expect(
      after.providerOptions,
      isNull,
      reason: '重置后 provider_options 列必须为空（模板快照值），不能残留旧值',
    );
  });

  test('S-1：重置返回实体同样不带 providerOptions', () async {
    final preset = await repo.createFromTemplate(
      templateId: 'tpl-anthropic',
      name: '我的 Claude',
    );
    await repo.updatePreset(
      preset.presetId,
      (current) => current.copyWith(
        providerOptions: {
          'anthropic_beta': ['x'],
        },
      ),
    );

    final reset = await repo.resetPreset(preset.presetId);

    expect(reset.providerOptions, isNull);
    expect(reset.name, 'Anthropic Claude');
  });
}
