import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/repositories/chat_repository.dart';
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
/// 4. 不传钩子（旧调用方/自动化）行为不变
void main() {
  /// v2 备份 JSON（含 1 会话触发覆盖删除链）
  String backupJson() => '''
{
  "version": 2,
  "sessions": [
    {
      "session": {"sessionId": "imported-1", "title": "导入", "mode": "chat"},
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
    backupRepo.orderLog = calls;

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
    backupRepo.orderLog = calls;

    await expectLater(
      service.importBackup(
        backupJson(),
        ImportMode.overwrite,
        preImportSnapshot: () async => throw Exception('disk full'),
      ),
      throwsException,
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

  test('不传钩子（旧调用方）：行为不变', () async {
    final result =
        await service.importBackup(backupJson(), ImportMode.overwrite);
    expect(result.importedSessions, 1);
  });
}

/// 记录调用顺序的 BackupRepository 桩（importSessionData 返回 1 条插入）
class _OrderTrackingBackupRepository implements BackupRepository {
  List<String> orderLog = [];

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
