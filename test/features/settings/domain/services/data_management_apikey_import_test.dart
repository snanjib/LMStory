import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/chat/domain/repositories/chat_repository.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/entities/data_management_models.dart';
import 'package:lmstory/features/settings/domain/entities/llm_protocol.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/backup_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/settings/domain/services/data_management_service.dart';

/// 含 API Key 备份导入——默认不导入密钥
///
/// Key 是敏感凭据：`importBackup` 新增 importApiKeys 开关（默认 false），
/// 未显式勾选时 v1/v2/v3 三链都不写 saveApiKey（预设行本身不含密钥，
/// 密钥走独立安全存储）；显式传 true 才覆盖本机 Key。
void main() {
  late _RecordingBackupRepository backupRepo;
  late _RecordingSettingsRepository settingsRepo;
  late DataManagementService service;

  setUp(() {
    backupRepo = _RecordingBackupRepository();
    settingsRepo = _RecordingSettingsRepository();
    service = DataManagementService(
      chatRepository: _StubChatRepository(),
      presetRepository: _StubPresetRepository(),
      settingsRepository: settingsRepo,
      backupRepository: backupRepo,
    );
  });

  const v3BackupWithKey = '''
{
  "version": 3,
  "contains_secrets": true,
  "presets": [
    {"preset_id": "p1", "name": "含Key供应商", "baseUrl": "https://api.test.com", "api_key": "sk-secret-1"}
  ]
}
''';

  const v1BackupWithKey = '''
{
  "version": 1,
  "presets": [
    {"name": "v1含Key", "baseUrl": "https://api.test.com", "apiKey": "sk-secret-v1"}
  ]
}
''';

  test('默认（不勾选）：预设导入成功但不写任何 Key', () async {
    final result =
        await service.importBackup(v3BackupWithKey, ImportMode.append);

    expect(result.importedPresets, 1);
    expect(
      settingsRepo.savedApiKeys,
      isEmpty,
      reason: 'D6-4：Key 默认不导入，须在导入面板显式勾选',
    );
  });

  test('显式勾选 importApiKeys=true：Key 覆盖本机', () async {
    await service.importBackup(
      v3BackupWithKey,
      ImportMode.append,
      importApiKeys: true,
    );

    expect(settingsRepo.savedApiKeys, {'p1': 'sk-secret-1'});
  });

  test('v1 链同口径：默认不写 Key，勾选才写', () async {
    await service.importBackup(v1BackupWithKey, ImportMode.append);
    expect(settingsRepo.savedApiKeys, isEmpty);

    await service.importBackup(
      v1BackupWithKey,
      ImportMode.append,
      importApiKeys: true,
    );
    expect(settingsRepo.savedApiKeys.values, contains('sk-secret-v1'));
  });
}

class _RecordingBackupRepository implements BackupRepository {
  @override
  Future<bool> importPreset(
    Map<String, dynamic> preset, {
    required ImportMode mode,
  }) async =>
      true;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _RecordingSettingsRepository implements SettingsRepository {
  final Map<String, String> savedApiKeys = {};

  @override
  Future<void> saveApiKey(String presetId, String apiKey) async =>
      savedApiKeys[presetId] = apiKey;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _StubChatRepository implements ChatRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _StubPresetRepository implements ApiPresetRepository {
  int _counter = 0;

  @override
  Future<List<ApiPreset>> getAllPresets() async => const [];

  @override
  Future<ApiPreset> createPreset({
    required String name,
    String baseUrl = '',
    LlmProtocol protocol = LlmProtocol.openaiCompatible,
    bool omitSamplingParams = true,
  }) async =>
      ApiPreset(
        presetId: 'stub-p${++_counter}',
        name: name,
        baseUrl: baseUrl,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
