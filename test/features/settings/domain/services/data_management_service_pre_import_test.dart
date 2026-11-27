import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/services/data_store_operation_guard.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/chat/data/repositories/chat_repository_impl.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/repositories/chat_repository.dart';
import 'package:lmstory/features/settings/data/repositories/backup_repository_impl.dart';
import 'package:lmstory/features/settings/domain/entities/data_management_models.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/backup_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/settings/domain/services/data_management_service.dart';

/// 覆盖导入前置自动快照——服务层契约
///
/// 1. 覆盖模式：快照钩子在**任何删除动作之前**执行（顺序可断言）
/// 2. 快照失败 → fail-closed：导入中止，库未被删（没有回滚网的覆盖
///    不值得跑——导入文件本身损坏时这是唯一防线）
/// 3. append 模式非破坏性：不触发快照
/// 4. 确认受影响域无旧数据时，可以省略快照
void main() {
  /// v2 备份 JSON（含 1 会话触发覆盖删除链）
  String backupJson() => '''
{
  "version": 2,
  "sessions": [
    {
      "session": {"session_id": "imported-1", "title": "导入", "mode": "chat"},
      "messages": [
        {"messageId": "m1", "role": "user", "content": "hi", "createdAt": "2026-01-01T00:00:00.000"}
      ]
    }
  ]
}
''';

  late _OrderTrackingBackupRepository backupRepo;
  late DataManagementService service;

  setUp(() {
    backupRepo = _OrderTrackingBackupRepository();
    service = DataManagementService(
      chatRepository: _StubChatRepository(),
      presetRepository: _StubPresetRepository(),
      settingsRepository: _StubSettingsRepository(),
      backupRepository: backupRepo,
    );
  });

  test('覆盖模式：快照先于任何删除动作', () async {
    final calls = <String>[];
    backupRepo
      ..orderLog = calls
      ..hasData = true;

    await service.importBackup(
      backupJson(),
      ImportMode.overwrite,
      preImportSnapshot: () async => calls.add('snapshot'),
    );

    expect(calls.first, 'snapshot', reason: 'A6：快照必须先于删除');
    expect(calls, contains('deleteAllSessionData'));
    expect(
      calls.indexOf('snapshot'),
      lessThan(calls.indexOf('deleteAllSessionData')),
    );
  });

  test('快照失败 → 导入中止且库未被删（fail-closed）', () async {
    final calls = <String>[];
    backupRepo
      ..orderLog = calls
      ..hasData = true;

    await expectLater(
      service.importBackup(
        backupJson(),
        ImportMode.overwrite,
        preImportSnapshot: () async => throw Exception('disk full'),
      ),
      throwsA(isA<BackupSnapshotException>()),
    );

    expect(
      calls.where((c) => c.startsWith('delete')),
      isEmpty,
      reason: '快照失败时不得执行任何删除',
    );
  });

  test('append 模式非破坏性：不触发快照', () async {
    var snapshotCalls = 0;
    await service.importBackup(
      backupJson(),
      ImportMode.append,
      preImportSnapshot: () async => snapshotCalls++,
    );
    expect(snapshotCalls, 0);
  });

  test('写入范围没有旧数据时可省略快照', () async {
    final result =
        await service.importBackup(backupJson(), ImportMode.overwrite);
    expect(result.importedSessions, 1);
  });

  group('同一数据存储上的覆盖导入', () {
    final busy = throwsA(isA<BackupOverwriteBusyException>());
    late DataStoreOperationGuard guard;
    late _GatedChatRepository chatRepo;
    late _GatedBackupRepository backupRepo;
    late DataManagementService service;

    DataManagementService createService() => DataManagementService(
          chatRepository: chatRepo,
          presetRepository: _StubPresetRepository(),
          settingsRepository: _StubSettingsRepository(),
          backupRepository: backupRepo,
          operationGuard: guard,
        );

    setUp(() {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      guard = DataStoreOperationGuard();
      chatRepo = _GatedChatRepository(db);
      backupRepo = _GatedBackupRepository(db);
      service = createService();
    });

    test('覆盖停在落库前时拒绝另一次覆盖', () async {
      final gate = _Gate();
      backupRepo.beforeSessionWrite = (data) async {
        final session = data['session'] as Map<String, dynamic>;
        if (session['session_id'] == 'first') await gate.wait();
      };
      await chatRepo.createSession(title: 'Existing session');

      final first = service.importBackup(
        _rowBackupJson('first'),
        ImportMode.overwrite,
        preImportSnapshot: () async {},
      );
      try {
        await gate.entered;
        expect(guard.tryBeginWrite(), isNull);

        var secondSnapshotCalls = 0;
        final second = service.importBackup(
          _rowBackupJson('second'),
          ImportMode.overwrite,
          preImportSnapshot: () async => secondSnapshotCalls++,
        );
        final secondOutcome = await second
            .then<Object>((result) => result, onError: (Object error) => error)
            .timeout(_deadline);
        expect(
          secondOutcome,
          isA<BackupOverwriteBusyException>(),
        );
        expect(secondSnapshotCalls, 0);
        expect(backupRepo.deleteCalls, 1);
        expect(backupRepo.sessionWriteCalls, 1);
      } finally {
        gate.release();
        await first.timeout(_deadline);
      }

      expect((await first).importedMessages, 1);
      expect((await chatRepo.getAllSessions()).single.sessionId, 'first');
      expect(
        (await chatRepo.getMessages('first')).single.content,
        'first text',
      );
      expect(guard.isOverwriting, isFalse);
    });

    test('共享保护拒绝快照期间的其他操作，快照失败后可重试', () async {
      final gate = _Gate();
      final failure = StateError('snapshot unavailable');
      final original = await chatRepo.createSession(title: 'Existing session');
      final first = expectLater(
        service.importBackup(
          _rowBackupJson('first'),
          ImportMode.overwrite,
          preImportSnapshot: () async {
            await gate.wait();
            throw failure;
          },
        ),
        throwsA(isA<BackupSnapshotException>()),
      );

      try {
        await gate.entered;
        expect(guard.tryBeginWrite(), isNull);
        var secondSnapshotCalls = 0;
        await expectLater(
          createService()
              .importBackup(
                _rowBackupJson('second'),
                ImportMode.overwrite,
                preImportSnapshot: () async => secondSnapshotCalls++,
              )
              .timeout(_deadline),
          busy,
        );
        expect(secondSnapshotCalls, 0);
        expect(backupRepo.deleteCalls, 0);
        expect(backupRepo.sessionWriteCalls, 0);
      } finally {
        gate.release();
        await first.timeout(_deadline);
      }

      expect(guard.isOverwriting, isFalse);
      expect(
        (await chatRepo.getAllSessions()).single.sessionId,
        original.sessionId,
      );
      final result = await service.importBackup(
        _rowBackupJson('retry'),
        ImportMode.overwrite,
        preImportSnapshot: () async {},
      );
      expect(result.importedMessages, 1);
      expect(
        (await chatRepo.getMessages('retry')).single.content,
        'retry text',
      );
    });

    test('最后一个写入结束前不执行覆盖的快照或落库', () async {
      final original = await chatRepo.createSession(title: 'Existing session');
      final releaseFirst = guard.tryBeginWrite() ?? fail('第一次写入未获得许可');
      final releaseSecond = guard.tryBeginWrite() ?? fail('第二次写入未获得许可');
      var snapshotCalls = 0;

      Future<ImportResult> overwrite() => service.importBackup(
            _rowBackupJson('replacement'),
            ImportMode.overwrite,
            preImportSnapshot: () async => snapshotCalls++,
          );

      await expectLater(overwrite().timeout(_deadline), busy);
      releaseFirst();
      releaseFirst();
      await expectLater(overwrite().timeout(_deadline), busy);
      expect(snapshotCalls, 0);
      expect(backupRepo.deleteCalls, 0);
      expect(backupRepo.sessionWriteCalls, 0);
      expect(
        (await chatRepo.getAllSessions()).single.sessionId,
        original.sessionId,
      );

      releaseSecond();
      final result = await overwrite();
      expect(snapshotCalls, 1);
      expect(backupRepo.deleteCalls, 1);
      expect(backupRepo.sessionWriteCalls, 1);
      expect(result.importedMessages, 1);
      expect((await chatRepo.getAllSessions()).single.sessionId, 'replacement');
    });

    for (final legacy in [false, true]) {
      final format = legacy ? '未标版本' : 'v1';
      test('$format 覆盖保持占用至消息计数写入完成', () async {
        final gate = _Gate();
        chatRepo.beforeMessageCountWrite = gate.wait;
        await chatRepo.createSession(title: 'Existing session');

        final imported = service.importBackup(
          _oldBackupJson('restored', legacy: legacy),
          ImportMode.overwrite,
          preImportSnapshot: () async {},
        );
        try {
          await gate.entered;
          expect(guard.tryBeginWrite(), isNull);
          expect(guard.tryBeginOverwrite(), isNull);
        } finally {
          gate.release();
          await imported.timeout(_deadline);
        }

        final result = await imported;
        final sessions = await chatRepo.getAllSessions();
        final restored = sessions.singleWhere((s) => s.title == 'restored');
        expect(sessions, hasLength(legacy ? 2 : 1));
        expect(backupRepo.deleteCalls, legacy ? 0 : 1);
        expect(result.mode, legacy ? ImportMode.append : ImportMode.overwrite);
        expect(result.importedMessages, 1);
        expect(restored.messageCount, 1);
        expect(
          (await chatRepo.getMessages(restored.sessionId)).single.content,
          'restored text',
        );
        expect(guard.isOverwriting, isFalse);
      });
    }

    test('v3 覆盖保持占用至全局资产写入完成', () async {
      final gate = _Gate();
      backupRepo.beforeAssetWrite = () async {
        expect(
          (await chatRepo.getMessages('restored')).single.content,
          'restored text',
        );
        await gate.wait();
      };
      final imported = service.importBackup(
        _rowBackupJson('restored', version: 3),
        ImportMode.overwrite,
      );
      try {
        await gate.entered;
        expect(guard.tryBeginWrite(), isNull);
      } finally {
        gate.release();
        await imported.timeout(_deadline);
      }

      expect((await imported).importedAssets, 1);
      final assets = await backupRepo.exportGlobalAssets();
      expect(assets['characterCards']?.single['card_id'], 'restored-card');
      expect(guard.isOverwriting, isFalse);
    });

    test('导入写入出错后释放覆盖占用', () async {
      final failure = StateError('store unavailable');
      backupRepo.beforeDelete = () async => throw failure;
      await expectLater(
        service.importBackup(_rowBackupJson('first'), ImportMode.overwrite),
        throwsA(same(failure)),
      );

      expect(guard.isOverwriting, isFalse);
      expect(backupRepo.sessionWriteCalls, 0);
      backupRepo.beforeDelete = null;
      final result = await service.importBackup(
        _rowBackupJson('retry'),
        ImportMode.overwrite,
      );
      expect(result.importedMessages, 1);
      expect((await chatRepo.getAllSessions()).single.sessionId, 'retry');
    });

    test('追加导入保留原会话，不做快照并跳过重复项', () async {
      final original = await chatRepo.createSession(title: 'Existing session');
      final release = guard.tryBeginWrite() ?? fail('写入未获得许可');
      var snapshotCalls = 0;
      try {
        final result = await service.importBackup(
          _rowBackupJson('appended'),
          ImportMode.append,
          preImportSnapshot: () async => snapshotCalls++,
        );
        final duplicate = await service.importBackup(
          _rowBackupJson('appended'),
          ImportMode.append,
        );

        expect(result.importedSessions, 1);
        expect(duplicate.skippedSessions, 1);
        expect(snapshotCalls, 0);
        expect(backupRepo.deleteCalls, 0);
        expect(
          (await chatRepo.getAllSessions()).map((s) => s.sessionId),
          unorderedEquals([original.sessionId, 'appended']),
        );
        expect(
          (await chatRepo.getMessages('appended')).single.content,
          'appended text',
        );
      } finally {
        release();
      }
    });
  });

  test('重复释放上一次覆盖的许可不会解除当前覆盖', () {
    final guard = DataStoreOperationGuard();
    final releaseFirst = guard.tryBeginOverwrite() ?? fail('首次覆盖未获得许可');
    releaseFirst();

    final releaseSecond = guard.tryBeginOverwrite() ?? fail('再次覆盖未获得许可');
    releaseFirst();
    expect(guard.isOverwriting, isTrue);
    expect(guard.tryBeginWrite(), isNull);
    releaseSecond();
    expect(guard.isOverwriting, isFalse);
  });
}

const _deadline = Duration(seconds: 5);

String _rowBackupJson(String sessionId, {int version = 2}) => jsonEncode({
      'version': version,
      'sessions': [
        {
          'session': {'session_id': sessionId, 'title': sessionId},
          'messages': [
            {
              'message_id': '$sessionId-message',
              'session_id': sessionId,
              'role': 'user',
              'content': '$sessionId text',
            },
          ],
        },
      ],
      if (version == 3)
        'characterCards': [
          {
            'card_id': '$sessionId-card',
            'name': 'Imported Card',
            'raw_json': '{}',
            'source_format': 'v2',
          },
        ],
    });

String _oldBackupJson(String title, {required bool legacy}) {
  final sessions = [
    {
      'name': title,
      'messages': [
        {'role': 'user', 'content': '$title text'},
      ],
    },
  ];
  return jsonEncode(legacy ? sessions : {'version': 1, 'sessions': sessions});
}

class _Gate {
  final _entered = Completer<void>();
  final _released = Completer<void>();

  Future<void> get entered => _entered.future.timeout(_deadline);

  Future<void> wait() {
    _entered.complete();
    return _released.future;
  }

  void release() => _released.complete();
}

class _GatedBackupRepository extends BackupRepositoryImpl {
  _GatedBackupRepository(AppDatabase database) : super(database: database);

  Future<void> Function(Map<String, dynamic>)? beforeSessionWrite;
  Future<void> Function()? beforeAssetWrite;
  Future<void> Function()? beforeDelete;
  int deleteCalls = 0;
  int sessionWriteCalls = 0;

  @override
  Future<void> deleteAllSessionData() async {
    deleteCalls++;
    await beforeDelete?.call();
    await super.deleteAllSessionData();
  }

  @override
  Future<int> importSessionData(
    Map<String, dynamic> data, {
    required ImportMode mode,
  }) async {
    sessionWriteCalls++;
    await beforeSessionWrite?.call(data);
    return super.importSessionData(data, mode: mode);
  }

  @override
  Future<int> importGlobalAssets(
    Map<String, dynamic> data, {
    required ImportMode mode,
  }) async {
    await beforeAssetWrite?.call();
    return super.importGlobalAssets(data, mode: mode);
  }
}

class _GatedChatRepository extends ChatRepositoryImpl {
  _GatedChatRepository(AppDatabase database) : super(database: database);

  Future<void> Function()? beforeMessageCountWrite;

  @override
  Future<void> updateSessionMessageCount(String sessionId, int count) async {
    await beforeMessageCountWrite?.call();
    await super.updateSessionMessageCount(sessionId, count);
  }
}

/// 记录调用顺序的 BackupRepository 桩（importSessionData 返回 1 条插入）
class _OrderTrackingBackupRepository implements BackupRepository {
  List<String> orderLog = [];
  bool hasData = false;

  @override
  Future<T> runInTransaction<T>(Future<T> Function() action) => action();

  @override
  Future<BackupOverwriteState> readOverwriteState(
    Set<BackupDataDomain> domains,
  ) async =>
      (hasData: hasData, fingerprint: '');

  @override
  Future<void> deleteAllSessionData() async {
    orderLog.add('deleteAllSessionData');
  }

  @override
  Future<void> deleteAllCustomPresets() async {
    orderLog.add('deleteAllCustomPresets');
  }

  @override
  Future<int> importSessionData(
    Map<String, dynamic> data, {
    required ImportMode mode,
  }) async {
    orderLog.add('importSessionData');
    return 1;
  }

  @override
  Future<bool> importPreset(
    Map<String, dynamic> preset, {
    required ImportMode mode,
  }) async {
    orderLog.add('importPreset');
    return true;
  }

  @override
  Future<int> importGlobalAssets(
    Map<String, dynamic> data, {
    required ImportMode mode,
  }) async {
    orderLog.add('importGlobalAssets');
    return 0;
  }

  @override
  Future<List<Map<String, dynamic>>> exportAllPresets() async => [];

  @override
  Future<List<Map<String, dynamic>>> exportAllSessionsData() async => [];

  @override
  Future<Map<String, dynamic>> exportSessionData(String sessionId) async => {};

  @override
  Future<Map<String, List<Map<String, dynamic>>>> exportGlobalAssets({
    bool includeAgentEvents = true,
  }) async =>
      {};

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _StubChatRepository implements ChatRepository {
  @override
  Future<List<ChatSession>> getAllSessions() async => [
        ChatSession(
          sessionId: 's1',
          title: '现有会话',
          mode: 'chat',
          createdAt: DateTime(2026),
          lastActiveAt: DateTime(2026),
          messageCount: 1,
        ),
      ];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _StubPresetRepository implements ApiPresetRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _StubSettingsRepository implements SettingsRepository {
  @override
  Future<Map<String, dynamic>> getUserOverrides() async => {};

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
