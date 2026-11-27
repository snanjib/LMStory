import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/config_loader.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/chat/data/repositories/chat_repository_impl.dart';
import 'package:lmstory/features/demo/data/demo_preferences.dart';
import 'package:lmstory/features/demo/data/demo_secure_storage.dart';
import 'package:lmstory/features/settings/data/datasources/api_key_datasource.dart';
import 'package:lmstory/features/settings/data/repositories/backup_repository_impl.dart';
import 'package:lmstory/features/settings/data/repositories/settings_repository_impl.dart';
import 'package:lmstory/features/settings/domain/entities/data_management_models.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/services/data_management_service.dart';

const _sessionId = 'sample-session';

void main() {
  late AppDatabase database;
  late ChatRepositoryImpl chat;
  late BackupRepositoryImpl backup;
  late DataManagementService service;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    chat = ChatRepositoryImpl(database: database);
    backup = BackupRepositoryImpl(database: database);
    service = DataManagementService(
      chatRepository: chat,
      backupRepository: backup,
      presetRepository: _UnusedPresets(),
      settingsRepository: SettingsRepositoryImpl(
        preferences: DemoPreferences(),
        configLoader: ConfigLoader(),
        apiKeyDatasource: ApiKeyDatasource(secureStorage: DemoSecureStorage()),
      ),
    );
  });

  test('recovery inspection distinguishes damaged collections and empty data',
      () {
    for (final file in [
      '{"version":3,"sessions":"damaged"}',
      '{"version":3,"preferences":[]}',
      '{"version":3,"worldbooks":null}',
      _payload(_story()..['factualHistory'] = 'damaged'),
    ]) {
      expect(
        () => DataManagementService.inspectRecoveryBackup(file),
        throwsA(
          allOf(
            isA<FormatException>(),
            isNot(isA<BackupNoRestorableDataException>()),
          ),
        ),
      );
    }
    for (final file in [
      '{"version":3}',
      '{"version":3,"exportedAt":"2026-11-20T00:00:00Z"}',
      '{"version":3,"presets":[42],"sessions":[]}',
      '{"messages":[null]}',
      '[]',
    ]) {
      expect(
        () => DataManagementService.inspectRecoveryBackup(file),
        throwsA(isA<BackupNoRestorableDataException>()),
      );
    }
    expect(
      () => DataManagementService.inspectRecoveryBackup('{"version":4}'),
      throwsA(
        isA<BackupVersionTooNewException>()
            .having((e) => e.version, 'version', 4),
      ),
    );
  });

  test('inspection reports identifiable bad items and retains valid rows',
      () async {
    final story = _story();
    (story['factualEntities']! as List<Map<String, Object>>).add({
      'entity_id': 'no-name',
      'session_id': _sessionId,
      'type': 'character',
      'created_turn': 1,
    });
    story['messages'] = [...story['messages']! as List<Object>, 42];
    final file = _payload(story);
    final details = DataManagementService.inspectRecoveryBackup(file);
    expect(details.version, 3);
    expect(details.exportedAt, DateTime.utc(2026, 11, 20));
    expect(details.skippedItems, 2);

    final result = await service.importBackup(file, ImportMode.overwrite);
    expect(result.skippedSessionRows, 1);
    expect(result.skippedMessages, 1);
    await service.verifyRecoveryReadback(file);
    expect(
      (await chat.getMessages(_sessionId)).single.content,
      'Synthetic text',
    );
  });

  test('fact attributes and history require a restorable owning entity',
      () async {
    final file = _payload(_story()..remove('factualEntities'));
    expect(
      () => DataManagementService.inspectRecoveryBackup(file),
      throwsFormatException,
    );
    await expectLater(
      service.importBackup(file, ImportMode.overwrite),
      throwsFormatException,
    );
    expect(await chat.getAllSessions(), isEmpty);
  });

  test(
      'shared import preflight rejects cross-session ownership before snapshot or clear',
      () async {
    final original = await chat.createSession(title: 'Original fixture');
    final story = _story();
    (story['messages']! as List<Map<String, Object?>>).single['session_id'] =
        'other-session';
    final file = _payload(story);
    var snapshots = 0;

    expect(
      () => DataManagementService.inspectRecoveryBackup(file),
      throwsFormatException,
    );
    await expectLater(
      service.importBackup(
        file,
        ImportMode.overwrite,
        preImportSnapshot: () async => snapshots++,
      ),
      throwsFormatException,
    );
    expect(snapshots, 0);
    expect((await chat.getAllSessions()).single.sessionId, original.sessionId);
    expect(await service.scanOrphanMessages(), isEmpty);
  });

  for (final version in [2, 3]) {
    test('v$version re-exports the same owned facts, history, and experiences',
        () async {
      final file = _payload(_story(), version: version);
      final result = await service.importBackup(file, ImportMode.overwrite);
      expect(result.importedSessions, 1);
      expect(result.importedMessages, 1);
      await service.verifyRecoveryReadback(file);

      final restored = await backup.exportSessionData(_sessionId);
      final history =
          (restored['factualHistory'] as List<Map<String, dynamic>>).single;
      expect(history['entity_id'], 'fact-a');
      expect(history['attribute_id'], 'removed-attr');
      expect(
        (restored['experientialMemories'] as List<Map<String, dynamic>>)
            .single['memory_id'],
        'experience-a',
      );
    });
  }

  test('SQLite silently skipping a valid fact prevents trial acceptance',
      () async {
    await database.customStatement(
      'CREATE TRIGGER no_fixture_fact BEFORE INSERT ON factual_entities '
      "WHEN NEW.entity_id = 'fact-a' BEGIN SELECT RAISE(IGNORE); END",
    );
    final file = _payload(_story());
    final result = await service.importBackup(file, ImportMode.overwrite);
    expect(result.importedSessions, 1);
    expect(result.importedMessages, 1);
    expect(
      (await backup.exportSessionData(_sessionId))['factualEntities'],
      isEmpty,
    );
    await expectLater(service.verifyRecoveryReadback(file), throwsStateError);
  });

  for (final edit in [
    "UPDATE chat_messages SET session_id = 'missing-session'",
    "UPDATE factual_entities SET primary_name = 'Different fact'",
    "UPDATE factual_attributes SET value = 'Different value'",
    "UPDATE factual_memory_history SET old_value = 'Different history'",
    "UPDATE experiential_memories SET summary = 'Different experience'",
  ]) {
    test('trial readback detects changed data despite identical counts: $edit',
        () async {
      final file = _payload(_story());
      await service.importBackup(file, ImportMode.overwrite);
      await service.verifyRecoveryReadback(file);
      final table = edit.split(' ')[1];
      final sql = 'SELECT COUNT(*) AS count FROM $table';
      final before =
          (await database.customSelect(sql).getSingle()).read<int>('count');

      await database.customStatement(edit);
      final after =
          (await database.customSelect(sql).getSingle()).read<int>('count');
      expect(before, 1);
      expect(after, before);
      await expectLater(service.verifyRecoveryReadback(file), throwsStateError);
    });
  }

  for (final legacy in [false, true]) {
    test('trial readback handles generated session IDs (legacy=$legacy)',
        () async {
      final sessions = [
        {
          'sessionId': 'legacy-original',
          'name': 'Synthetic legacy story',
          'messages': [
            {
              'messageId': 'legacy-message',
              'role': 'user',
              'content': 'Legacy text',
            },
            {'role': 'assistant', 'content': 'Generated-ID text'},
            'damaged',
          ],
        },
      ];
      final file =
          jsonEncode(legacy ? sessions : {'version': 1, 'sessions': sessions});
      final details = DataManagementService.inspectRecoveryBackup(file);
      expect(details.skippedItems, 1);
      final result = await service.importBackup(file, ImportMode.overwrite);
      expect(result.importedMessages, 2);
      expect(result.skippedMessages, 1);
      await service.verifyRecoveryReadback(file);

      final session = (await chat.getAllSessions()).single;
      expect(session.sessionId, isNot('legacy-original'));
      final messages = await chat.getMessages(session.sessionId);
      expect(
        messages.any((message) => message.messageId == 'legacy-message'),
        !legacy,
      );
    });
  }
}

String _payload(Map<String, Object> session, {int version = 3}) => jsonEncode({
      'version': version,
      'exportedAt': '2026-11-20T00:00:00Z',
      'sessions': [session],
    });

Map<String, Object> _story() => {
      'session': {'session_id': _sessionId, 'title': 'Synthetic story'},
      'messages': <Map<String, Object?>>[
        {
          'message_id': 'message-a',
          'session_id': _sessionId,
          'role': 'user',
          'content': 'Synthetic text',
        },
      ],
      'factualEntities': <Map<String, Object>>[
        {
          'entity_id': 'fact-a',
          'session_id': _sessionId,
          'primary_name': 'Fixture fact',
          'type': 'character',
          'created_turn': 1,
        },
      ],
      'factualAttributes': [
        {
          'attribute_id': 'attribute-a',
          'entity_id': 'fact-a',
          'session_id': _sessionId,
          'attr_key': 'description',
          'value': 'Current value',
        },
      ],
      'factualHistory': [
        {
          'entity_id': 'fact-a',
          'attribute_id': 'removed-attr',
          'action': 'REMOVE_ATTR',
          'old_value': 'Historical value',
          'turn_number': 2,
        },
      ],
      'experientialMemories': [
        {
          'memory_id': 'experience-a',
          'session_id': _sessionId,
          'summary': 'Synthetic experience',
          'turn_number': 1,
        },
      ],
    };

class _UnusedPresets implements ApiPresetRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName}');
}
