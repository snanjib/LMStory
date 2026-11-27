import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/config_loader.dart';
import 'package:lmstory/core/services/data_store_operation_guard.dart';
import 'package:lmstory/core/storage/preferences.dart';
import 'package:lmstory/core/vector/vector_engine.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/chat/data/repositories/chat_repository_impl.dart';
import 'package:lmstory/features/demo/data/demo_secure_storage.dart';
import 'package:lmstory/features/memory/data/repositories/experience_repository_impl.dart';
import 'package:lmstory/features/memory/data/repositories/memory_fts_rebuilder.dart';
import 'package:lmstory/features/settings/data/auto_backup_manager.dart';
import 'package:lmstory/features/settings/data/datasources/api_key_datasource.dart';
import 'package:lmstory/features/settings/data/repositories/backup_repository_impl.dart';
import 'package:lmstory/features/settings/data/repositories/settings_repository_impl.dart';
import 'package:lmstory/features/settings/domain/entities/data_management_models.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/settings/domain/services/data_management_service.dart';

const _settingsKey = 'intermediate.generation.temperature';
const _oldKey = 'fixture-credential-old';
const _incomingKey = 'fixture-credential-new';

void main() {
  late AppDatabase db;
  late BackupRepositoryImpl backup;
  late ChatRepositoryImpl chat;
  late _TestSettings settings;
  late DataStoreOperationGuard guard;
  late DataManagementService service;
  late AutoBackupManager snapshots;
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('lmstory_overwrite');
    db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() async {
      await db.close();
      await temp.delete(recursive: true);
    });
    chat = ChatRepositoryImpl(database: db);
    backup = BackupRepositoryImpl(database: db);
    settings = _TestSettings();
    guard = DataStoreOperationGuard();
    service = DataManagementService(
      chatRepository: chat,
      presetRepository: _UnusedPresetRepository(),
      settingsRepository: settings,
      backupRepository: backup,
      operationGuard: guard,
    );
    snapshots = AutoBackupManager(
      dataManagementService: service,
      settingsRepository: settings,
      chatRepository: chat,
      documentsDirectory: () async => temp,
    );
  });

  Future<void> saveSnapshot() async {
    await snapshots.createPreImportSnapshot();
  }

  Future<Map<String, dynamic>> readDomains() async => {
        'sessions': await backup.exportAllSessionsData(),
        'presets': await backup.exportAllPresets(),
        'assets': await backup.exportGlobalAssets(),
        'preferences': await settings.getUserOverrides(),
        'experienceSearch': (await db
                .customSelect(
                  "SELECT memory_id FROM memories_fts WHERE memories_fts MATCH 'lighthouse'",
                )
                .get())
            .map((row) => row.data)
            .toList(),
        'factsSearch': (await db
                .customSelect(
                  "SELECT entity_id FROM factual_fts WHERE factual_fts MATCH 'compass'",
                )
                .get())
            .map((row) => row.data)
            .toList(),
      };

  for (final domain in ['presets', 'preferences', 'characterCards']) {
    test('零会话覆盖 $domain 前保存快照并通过导入恢复原值', () async {
      final Map<String, Object> payload;
      switch (domain) {
        case 'presets':
          await db.customStatement(
            'INSERT INTO api_presets (preset_id, name, base_url, is_built_in) '
            "VALUES ('provider-a', 'Original', 'https://provider.test', 0)",
          );
          await settings.saveApiKey('provider-a', _oldKey);
          payload = {
            'presets': [_preset('provider-b', key: _incomingKey)],
          };
        case 'preferences':
          await settings.setUserOverride(_settingsKey, 0.75);
          payload = {
            'preferences': {_settingsKey: 0.2},
          };
        case 'characterCards':
          await db.customStatement(
            'INSERT INTO character_cards '
            '(card_id, name, raw_json, source_format) '
            "VALUES ('card-a', 'Original Card', '{}', 'v2')",
          );
          payload = {
            'characterCards': [
              {
                'card_id': 'card-b',
                'name': 'Replacement Card',
                'raw_json': '{}',
                'source_format': 'v2',
              },
            ],
          };
        default:
          fail('Unexpected test domain');
      }

      final before = await readDomains();
      await service.importBackup(
        jsonEncode({'version': 3, ...payload}),
        ImportMode.overwrite,
        preImportSnapshot: () async {
          await saveSnapshot();
          expect(await readDomains(), before);
        },
      );

      final files = await snapshots.listPreImportSnapshots();
      expect(files, hasLength(1));
      expect(await readDomains(), isNot(equals(before)));
      final snapshot = await files.single.readAsString();
      expect(snapshot.contains('api_key'), isFalse);
      expect(snapshot.contains('contains_secrets'), isFalse);
      expect(snapshot.contains(_oldKey), isFalse);
      await service.importBackup(
        snapshot,
        ImportMode.overwrite,
        preImportSnapshot: saveSnapshot,
      );

      // 自增行号是本地存储细节，业务 ID、引用和值保留。
      final restored = await readDomains();
      expect(
        _withoutRowIds(restored),
        equals(_withoutRowIds(before)),
      );
      if (domain == 'presets') {
        expect(await settings.getApiKey('provider-a') == _oldKey, isTrue);
        expect(await settings.getApiKey('provider-b'), isNull);
      }
    });
  }

  test('SQLite 插入异常发生在清空后，旧会话和各域仍可读', () async {
    await _seedStory(db);
    await settings.setUserOverride(_settingsKey, 0.75);
    final before = await readDomains();
    await db.customStatement(
      'CREATE TRIGGER test_reject_backup_message BEFORE INSERT ON chat_messages '
      "WHEN NEW.message_id = 'replacement-msg' "
      "BEGIN SELECT RAISE(ABORT, 'injected SQLite storage failure'); END",
    );

    final outcome = await _outcome(
      service.importBackup(
        _replacement(version: 2),
        ImportMode.overwrite,
        preImportSnapshot: saveSnapshot,
      ),
    );
    expect((await chat.getMessages('story-a')).map((m) => m.content), [
      'Synthetic original story',
    ]);
    expect(await readDomains(), before);
    expect(outcome, isNot(isA<ImportResult>()));
    expect(guard.isOverwriting, isFalse);
  });

  test('偏好已写后抛出异常，回读旧偏好、故事和各域', () async {
    await _seedStory(db);
    await settings.setUserOverride(_settingsKey, 0.75);
    final before = await readDomains();
    settings.afterOverrideWrite = (key) {
      if (key == 'fixture.new.preference') {
        throw StateError('injected preference write failure');
      }
    };

    final outcome = await _outcome(
      service.importBackup(
        _replacement(),
        ImportMode.overwrite,
        preImportSnapshot: saveSnapshot,
      ),
    );
    expect(await settings.getUserOverrides(), before['preferences']);
    expect(await readDomains(), before);
    expect(outcome, isNot(isA<ImportResult>()));
  });

  test('显式导入密钥写后抛出异常，回读旧值并去除原本不存在的键', () async {
    await _seedStory(db);
    await settings.saveApiKey('provider-a', _oldKey);
    await settings.setUserOverride(_settingsKey, 0.75);
    final before = await readDomains();
    settings.afterKeyWrite = (id) {
      if (id == 'provider-b') {
        throw StateError('injected secure store write failure');
      }
    };

    final outcome = await _outcome(
      service.importBackup(
        _replacement(),
        ImportMode.overwrite,
        importApiKeys: true,
        preImportSnapshot: saveSnapshot,
      ),
    );
    expect(await settings.getApiKey('provider-a') == _oldKey, isTrue);
    expect(await settings.getApiKey('provider-b'), isNull);
    expect(await readDomains(), before);
    expect(outcome, isNot(isA<ImportResult>()));
  });

  test('格式或版本错误不会触碰快照或原有数据', () async {
    await _seedStory(db);
    final before = await readDomains();
    var snapshots = 0;
    final outcome = await _outcome(
      service.importBackup(
        _replacement(version: 4),
        ImportMode.overwrite,
        preImportSnapshot: () async => snapshots++,
      ),
    );
    expect(snapshots, 0);
    expect(await readDomains(), before);
    expect(
      outcome,
      isA<BackupVersionTooNewException>()
          .having((e) => e.version, 'version', 4),
    );
  });

  test('格式错误不包含 JSON 原文并在写入前返回', () async {
    const malformed = '{"version":3,"private":"fixture-secret",]';
    expect(
      () => DataManagementService.validateBackup(malformed),
      throwsA(
        isA<FormatException>().having((e) => e.source, 'source', isNull).having(
              (e) => e.toString(),
              'error',
              isNot(contains('fixture-secret')),
            ),
      ),
    );
    final before = await readDomains();
    var snapshotCalls = 0;
    await expectLater(
      service.importBackup(
        malformed,
        ImportMode.overwrite,
        preImportSnapshot: () async => snapshotCalls++,
      ),
      throwsFormatException,
    );
    expect(snapshotCalls, 0);
    expect(await readDomains(), before);
  });

  test('找不到可用的快照方式时保护现有数据', () async {
    await _seedStory(db);
    final before = await readDomains();
    final outcome = await _outcome(
      service.importBackup(_replacement(), ImportMode.overwrite),
    );
    expect(await readDomains(), before);
    expect(outcome, isA<BackupSnapshotException>());
  });

  test('明确的替换范围不包含已有故事时可省略快照', () async {
    await _seedStory(db);
    await settings.setUserOverride(_settingsKey, 0.75);
    final before = await readDomains();
    var snapshotCalls = 0;
    final result = await service.importBackup(
      '{"version":3,"worldbooks":[],"sessions":[]}',
      ImportMode.overwrite,
      preImportSnapshot: () async => snapshotCalls++,
    );
    expect(result.importedSessions, 0);
    expect(snapshotCalls, 0);
    expect(await readDomains(), before);
  });

  test('全部无效的域保留原数据，坏条目计数准确', () async {
    await _seedStory(db);
    await settings.setUserOverride(_settingsKey, 0.75);
    final before = await readDomains();
    final result = await service.importBackup(
      '{"version":3,"sessions":[{"session":{}}],"presets":[42],'
      '"preferences":{"bad":null},"characterCards":[{"card_id":"bad"}]}',
      ImportMode.overwrite,
    );
    expect(result.skippedSessions, 1);
    expect(result.skippedPresets, 1);
    expect(result.skippedPreferences, 1);
    expect(result.skippedAssets, 1);
    expect(await readDomains(), before);
  });

  test('不能写进可恢复快照的孤立消息仍可在导入被拒后找回', () async {
    await db.customStatement(
      'INSERT INTO chat_messages (message_id, session_id, role, content) '
      "VALUES ('orphan-msg', 'missing-story', 'user', 'Recoverable text')",
    );
    await expectLater(
      service.importBackup(
        _replacement(),
        ImportMode.overwrite,
        preImportSnapshot: saveSnapshot,
      ),
      throwsA(isA<BackupSnapshotException>()),
    );
    final groups = await service.scanOrphanMessages();
    expect(groups.single.orphanSessionId, 'missing-story');
    expect(groups.single.messages.single.content, 'Recoverable text');
  });

  test('两个导入会话竞争同一个经历 ID 时保留完整原库', () async {
    await _seedStory(db);
    final before = await readDomains();
    final payload = jsonEncode({
      'version': 3,
      'sessions': [
        for (final id in ['first', 'second'])
          {
            'session': {'session_id': id, 'title': id},
            'experientialMemories': [
              {
                'session_id': id,
                'memory_id': 'shared-memory-id',
                'summary': 'fixture memory for $id',
                'turn_number': 1,
              },
            ],
          },
      ],
    });
    final outcome = await _outcome(
      service.importBackup(
        payload,
        ImportMode.overwrite,
        preImportSnapshot: saveSnapshot,
      ),
    );
    expect(outcome, isA<FormatException>());
    expect(await snapshots.listPreImportSnapshots(), isEmpty);
    expect(await readDomains(), before);
  });

  test('v1 会话写入异常会回退实际仓储已写入的会话', () async {
    await _seedStory(db);
    final before = await readDomains();
    await db.customStatement(
      'CREATE TRIGGER test_reject_old_message BEFORE INSERT ON chat_messages '
      "WHEN NEW.message_id = 'v1-msg' "
      "BEGIN SELECT RAISE(ABORT, 'injected v1 storage failure'); END",
    );
    final outcome = await _outcome(
      service.importBackup(
        '{"version":1,"sessions":[{"name":"v1","messages":['
        '{"messageId":"v1-msg","role":"user","content":"v1 text"}]}]}',
        ImportMode.overwrite,
        preImportSnapshot: saveSnapshot,
      ),
    );
    expect(outcome, isNot(isA<ImportResult>()));
    expect(await readDomains(), before);
  });

  test('快照文件无法生成时 SQLite 与偏好保持可读', () async {
    await _seedStory(db);
    await settings.setUserOverride(_settingsKey, 0.75);
    final before = await readDomains();
    snapshots = AutoBackupManager(
      dataManagementService: service,
      settingsRepository: settings,
      chatRepository: chat,
      documentsDirectory: () async => throw const FileSystemException(
        'injected backup location failure',
      ),
    );
    await expectLater(
      service.importBackup(
        _replacement(),
        ImportMode.overwrite,
        preImportSnapshot: saveSnapshot,
      ),
      throwsA(isA<BackupSnapshotException>()),
    );
    expect(await readDomains(), before);
    expect(guard.isOverwriting, isFalse);
  });

  test('从预导入快照恢复可读回正文、记忆与引用', () async {
    await _seedStory(db);
    await settings.setUserOverride(_settingsKey, 0.75);
    final before = await readDomains();

    await service.importBackup(
      _replacement(),
      ImportMode.overwrite,
      preImportSnapshot: saveSnapshot,
    );
    expect((await chat.getAllSessions()).single.sessionId, 'replacement');
    final file = (await snapshots.listPreImportSnapshots()).single;
    await service.importBackup(
      await file.readAsString(),
      ImportMode.overwrite,
      preImportSnapshot: saveSnapshot,
    );

    expect(_withoutRowIds(await readDomains()), _withoutRowIds(before));
    final original = await chat.getSession('story-a');
    expect(original.presetId, 'provider-a');
    expect(original.characterInitCardId, 'card-a');
  });

  test('跳过 v2/v3 重复会话和 v1 重复消息，保留第一条已写入记录', () async {
    final v3 = jsonEncode({
      'version': 3,
      'sessions': [
        {
          'session': {'session_id': 'duplicate', 'title': 'First copy'},
          'messages': [
            {
              'message_id': 'repeated-msg',
              'session_id': 'duplicate',
              'role': 'user',
              'content': 'First body',
            },
          ],
        },
        {
          'session': {'session_id': 'duplicate', 'title': 'Second copy'},
        },
      ],
    });
    final fresh = await service.importBackup(v3, ImportMode.overwrite);
    expect(fresh.importedSessions, 1);
    expect(fresh.skippedSessions, 1);
    expect(fresh.skippedMessages, 0);
    expect((await chat.getSession('duplicate')).title, 'First copy');
    final appended = await service.importBackup(
      '{"version":1,"sessions":[{"name":"v1","messages":['
      '{"messageId":"repeated-msg","content":"Second copy"}, '
      '{"messageId":"unique-msg","content":"New message"}]}]}',
      ImportMode.append,
    );
    expect(appended.importedMessages, 1);
    expect(appended.skippedMessages, 1);
    expect((await chat.getMessages('duplicate')).single.content, 'First body');
    final legacy =
        (await chat.getAllSessions()).singleWhere((s) => s.title == 'v1');
    expect(legacy.messageCount, 1);
    expect(
      (await chat.getMessages(legacy.sessionId)).single.content,
      'New message',
    );
  });

  test('持有覆盖许可直到失败后的密钥补偿和读回结束', () async {
    await _seedStory(db);
    await settings.saveApiKey('provider-a', _oldKey);
    final restoring = Completer<void>();
    final allowRestore = Completer<void>();
    settings.afterKeyWrite = (id) async {
      if (id == 'provider-b') throw StateError('injected write failure');
      if (await settings.getApiKey(id) == _oldKey) {
        restoring.complete();
        await allowRestore.future;
      }
    };
    final overwrite = _outcome(
      service.importBackup(
        _replacement(),
        ImportMode.overwrite,
        importApiKeys: true,
        preImportSnapshot: saveSnapshot,
      ),
    );
    try {
      await restoring.future.timeout(const Duration(seconds: 5));
      expect(guard.tryBeginWrite(), isNull);
      expect(guard.tryBeginOverwrite(), isNull);
      expect(
        (await chat.getMessages('story-a')).single.content,
        'Synthetic original story',
      );
      await expectLater(
        service.importBackup(_replacement(), ImportMode.append),
        throwsA(isA<BackupOverwriteBusyException>()),
      );
    } finally {
      allowRestore.complete();
    }
    expect(await overwrite, isA<StateError>());
    expect(guard.isOverwriting, isFalse);
    settings.afterKeyWrite = null;
    final retry = await service.importBackup(
      _replacement(),
      ImportMode.overwrite,
      preImportSnapshot: saveSnapshot,
      importApiKeys: true,
    );
    expect(retry.importedApiKeys, 2);
  });

  for (final hadPreferences in [true, false]) {
    test('实际偏好适配器写后失败会恢复原始偏好状态（有值=$hadPreferences）', () async {
      await _seedStory(db);
      final before = await readDomains();
      final old = hadPreferences ? '{ "$_settingsKey" : 0.75 }' : null;
      final preferences = _MemoryPreferences(old);
      final realSettings = SettingsRepositoryImpl(
        preferences: preferences,
        configLoader: ConfigLoader(),
        apiKeyDatasource: ApiKeyDatasource(secureStorage: DemoSecureStorage()),
      );
      service = DataManagementService(
        chatRepository: chat,
        presetRepository: _UnusedPresetRepository(),
        settingsRepository: realSettings,
        backupRepository: backup,
        operationGuard: guard,
      );
      snapshots = AutoBackupManager(
        dataManagementService: service,
        settingsRepository: realSettings,
        chatRepository: chat,
        documentsDirectory: () async => temp,
      );
      preferences.failAfterWrite = true;

      final outcome = await _outcome(
        service.importBackup(
          _replacement(),
          ImportMode.overwrite,
          preImportSnapshot: saveSnapshot,
        ),
      );
      expect(outcome, isA<StateError>());
      expect(preferences.persisted, old);
      expect(await readDomains(), before);
      expect(
        await realSettings.getUserOverrides(),
        hadPreferences ? {_settingsKey: 0.75} : isEmpty,
      );
    });
  }

  test('实际密钥适配器读失败和缺键有不同的保护结果', () async {
    await _seedStory(db);
    final before = await readDomains();
    final keys = _FaultingSecureStorage()..failRead = true;
    final realSettings = SettingsRepositoryImpl(
      preferences: _MemoryPreferences(null),
      configLoader: ConfigLoader(),
      apiKeyDatasource: ApiKeyDatasource(secureStorage: keys),
    );
    service = DataManagementService(
      chatRepository: chat,
      presetRepository: _UnusedPresetRepository(),
      settingsRepository: realSettings,
      backupRepository: backup,
      operationGuard: guard,
    );
    var snapshotCalls = 0;
    final outcome = await _outcome(
      service.importBackup(
        _replacement(),
        ImportMode.overwrite,
        preImportSnapshot: () async => snapshotCalls++,
        importApiKeys: true,
      ),
    );
    expect(outcome, isA<BackupSnapshotException>());
    expect(snapshotCalls, 0);
    expect(await readDomains(), before);
    expect(keys.debugStore.isEmpty, isTrue);
  });

  test('实际密钥适配器写后失败，补偿旧值和不存在的键', () async {
    await _seedStory(db);
    final keys = _FaultingSecureStorage();
    final preferences = _MemoryPreferences(null);
    final realSettings = SettingsRepositoryImpl(
      preferences: preferences,
      configLoader: ConfigLoader(),
      apiKeyDatasource: ApiKeyDatasource(secureStorage: keys),
    );
    await realSettings.saveApiKey('provider-a', _oldKey);
    service = DataManagementService(
      chatRepository: chat,
      presetRepository: _UnusedPresetRepository(),
      settingsRepository: realSettings,
      backupRepository: backup,
      operationGuard: guard,
    );
    snapshots = AutoBackupManager(
      dataManagementService: service,
      settingsRepository: realSettings,
      chatRepository: chat,
      documentsDirectory: () async => temp,
    );
    final before = await readDomains();
    keys.failAfterWrite = 'api_key_provider-b';
    final outcome = await _outcome(
      service.importBackup(
        _replacement(),
        ImportMode.overwrite,
        preImportSnapshot: saveSnapshot,
        importApiKeys: true,
      ),
    );
    expect(outcome, isA<StateError>());
    expect(await realSettings.getApiKey('provider-a') == _oldKey, isTrue);
    expect(await realSettings.getApiKey('provider-b'), isNull);
    expect(preferences.persisted, isNull);
    expect(await readDomains(), before);
  });

  test('密钥补偿无法确认时保留恢复快照并发出单独的错误', () async {
    await _seedStory(db);
    await settings.saveApiKey('provider-a', _oldKey);
    final before = await readDomains();
    settings
      ..beforeKeyWrite = (id, value) {
        if (id == 'provider-a' && value == _oldKey) {
          throw StateError('injected compensation failure');
        }
      }
      ..afterKeyWrite = (id) {
        if (id == 'provider-b') {
          throw StateError('injected secure write failure');
        }
      };
    await expectLater(
      service.importBackup(
        _replacement(),
        ImportMode.overwrite,
        preImportSnapshot: saveSnapshot,
        importApiKeys: true,
      ),
      throwsA(isA<BackupRollbackException>()),
    );
    expect(await readDomains(), before);
    expect(await settings.getApiKey('provider-a') == _incomingKey, isTrue);
    expect(await settings.getApiKey('provider-b'), isNull);
    final file = (await snapshots.listPreImportSnapshots()).single;
    expect(
      () => DataManagementService.validatePreImportSnapshot(
        file.readAsStringSync(),
      ),
      returnsNormally,
    );
    expect(guard.isOverwriting, isFalse);
  });
}

Future<Object> _outcome(Future<ImportResult> result) =>
    result.then<Object>((value) => value, onError: (Object error) => error);

Map<String, Object> _preset(String id, {required String key}) => {
      'preset_id': id,
      'name': id,
      'base_url': 'https://provider.test',
      'api_key': key,
    };

String _replacement({int version = 3}) => jsonEncode({
      'version': version,
      'sessions': [
        {
          'session': {'session_id': 'replacement', 'title': 'Replacement'},
          'messages': [
            {
              'message_id': 'replacement-msg',
              'session_id': 'replacement',
              'role': 'user',
              'content': 'Synthetic incoming story',
            },
          ],
        },
      ],
      'presets': [
        _preset('provider-a', key: _incomingKey),
        _preset('provider-b', key: _incomingKey),
      ],
      'preferences': {_settingsKey: 0.2, 'fixture.new.preference': true},
      if (version >= 3) 'characterCards': <Object>[],
    });

Object? _withoutRowIds(Object? data) {
  if (data is List) return data.map(_withoutRowIds).toList();
  if (data is Map<String, dynamic>) {
    return {
      for (final entry in data.entries)
        if (entry.key != 'id') entry.key: _withoutRowIds(entry.value),
    };
  }
  return data;
}

Future<void> _seedStory(AppDatabase db) async {
  await db.customStatement(
    'INSERT INTO chat_sessions (session_id, title, preset_id, character_init_card_id) '
    "VALUES ('story-a', 'Original story', 'provider-a', 'card-a')",
  );
  await db.customStatement(
    'INSERT INTO chat_messages (message_id, session_id, role, content) '
    "VALUES ('story-message', 'story-a', 'user', 'Synthetic original story')",
  );
  await db.customStatement(
    'INSERT INTO api_presets (preset_id, name, base_url, is_built_in) '
    "VALUES ('provider-a', 'Original provider', 'https://provider.test', 0)",
  );
  await db.customStatement(
    'INSERT INTO character_cards (card_id, name, raw_json, source_format) '
    "VALUES ('card-a', 'Original Card', '{}', 'v2')",
  );
  final experience = ExperienceRepositoryImpl(
    database: db,
    vectorEngine: const VectorEngine(),
  );
  await experience.appendExperience(
    sessionId: 'story-a',
    summary: 'Crossed the lighthouse bridge',
    importance: 4,
    tags: const ['fixture'],
    turnNumber: 1,
  );
  await db.customStatement(
    'INSERT INTO factual_entities '
    '(entity_id, session_id, primary_name, type, importance, '
    'is_archived, aliases, source, force_inject, created_turn) '
    "VALUES ('fact-a', 'story-a', 'Silver compass', 'lore', 3, 0, '[]', "
    "'worldbook', 'none', 1)",
  );
  await db.customStatement(
    'INSERT INTO factual_attributes '
    '(attribute_id, entity_id, session_id, attr_key, value, source) '
    "VALUES ('attr-a', 'fact-a', 'story-a', 'description', 'Points north', 'auto')",
  );
  await db.customStatement(
    'INSERT INTO factual_memory_history '
    '(entity_id, attribute_id, action, old_value, new_value, turn_number) '
    "VALUES ('fact-a', 'attr-a', 'update_attr', 'Points south', 'Points north', 1)",
  );
  await rebuildSessionFts(db, 'story-a');
  await db.customStatement(
    'INSERT INTO agent_events (session_id, seq, type, time, data) '
    "VALUES ('story-a', 1, 'turn/begin', 1000, ?)",
    ['{"turn":1}'],
  );
}

class _TestSettings implements SettingsRepository {
  final _overrides = <String, dynamic>{};
  final _keys = <String, String>{};
  void Function(String key)? afterOverrideWrite;
  FutureOr<void> Function(String id)? afterKeyWrite;
  void Function(String id, String value)? beforeKeyWrite;

  @override
  Future<Map<String, dynamic>> getUserOverrides() async => Map.of(_overrides);

  @override
  Future<void> setUserOverride(String key, dynamic value) async {
    _overrides[key] = value;
    afterOverrideWrite?.call(key);
  }

  @override
  Future<void> removeUserOverride(String key) async => _overrides.remove(key);

  @override
  Future<void> clearAllUserOverrides() async => _overrides.clear();

  @override
  Future<String?> getApiKey(String presetId) async => _keys[presetId];

  @override
  Future<void> saveApiKey(String presetId, String apiKey) async {
    beforeKeyWrite?.call(presetId, apiKey);
    _keys[presetId] = apiKey;
    await afterKeyWrite?.call(presetId);
  }

  @override
  Future<void> deleteApiKey(String presetId) async => _keys.remove(presetId);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _MemoryPreferences extends Preferences {
  _MemoryPreferences(this.persisted) : _cache = persisted;

  String? persisted;
  String? _cache;
  bool failAfterWrite = false;

  @override
  Future<String?> getString(String key) async => _cache;

  @override
  Future<bool> setString(String key, String value) async {
    persisted = _cache = value;
    return !(failAfterWrite && value.contains('fixture.new.preference'));
  }

  @override
  Future<bool> remove(String key) async {
    persisted = _cache = null;
    return true;
  }

  @override
  Future<void> reload() async => _cache = persisted;
}

class _FaultingSecureStorage extends DemoSecureStorage {
  bool failRead = false;
  String? failAfterWrite;

  @override
  Future<String?> readStrict(String key) async {
    if (failRead) throw StateError('injected secure read failure');
    return super.readStrict(key);
  }

  @override
  Future<void> writeStrict(String key, String value) async {
    await super.writeStrict(key, value);
    if (key == failAfterWrite) {
      throw StateError('injected secure write failure');
    }
  }
}

class _UnusedPresetRepository implements ApiPresetRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
