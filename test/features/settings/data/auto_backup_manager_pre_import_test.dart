import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/repositories/chat_repository.dart';
import 'package:lmstory/features/settings/data/auto_backup_manager.dart';
import 'package:lmstory/features/settings/domain/entities/data_management_models.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/settings/domain/services/data_management_service.dart';

/// 覆盖导入前置快照——AutoBackupManager 侧
///
/// 1. 快照写入 backups/，前缀 lmstory_pre_import_ 区别于自动备份
/// 2. 滚动保留最近 2 份（自动备份 3 份窗口互不挤占）
/// 3. 自动备份的 _rollingTrim 不得删快照，也不得删用户手放的外来 .json
///
/// 4. 空库不快照（无物可保护，避免堆积无意义文件）
/// 5. 快照失败向上抛（fail-closed，由导入链中止——与 runIfNeeded 的
///   「失败仅记日志」不同口径）
void main() {
  late Directory tempDir;
  late _RecordingDataManagementService dataService;
  late _StubChatRepository chatRepo;
  late _StubSettingsRepository settingsRepo;
  late AutoBackupManager manager;
  final now = DateTime(2026, 9, 4, 12);

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('lmstory_pre_import_test');
    dataService = _RecordingDataManagementService();
    chatRepo = _StubChatRepository();
    settingsRepo = _StubSettingsRepository();
    manager = AutoBackupManager(
      dataManagementService: dataService,
      settingsRepository: settingsRepo,
      chatRepository: chatRepo,
      documentsDirectory: () async => tempDir,
      clock: () => now,
    );
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  ChatSession session() => ChatSession(
        sessionId: 's1',
        title: 't',
        mode: 'chat',
        createdAt: DateTime(2026),
        lastActiveAt: DateTime(2026),
        messageCount: 1,
      );

  File writeFile(String name, {DateTime? mtime}) {
    final f = File(
      '${tempDir.path}${Platform.pathSeparator}backups${Platform.pathSeparator}$name',
    )
      ..createSync(recursive: true)
      ..writeAsStringSync('{"version":3}');
    if (mtime != null) {
      f.setLastModifiedSync(mtime);
    }
    return f;
  }

  test('快照写入 pre_import 前缀文件，内容为 v3 全量导出（不含 Key）', () async {
    final file = await manager.createPreImportSnapshot();

    expect(file, isNotNull);
    expect(file!.path, contains(AutoBackupManager.preImportFileNamePrefix));
    expect(
      dataService.lastExportOptions?.includeApiKeys,
      isFalse,
      reason: '快照与自动备份同口径：不含 API Key',
    );
    expect(dataService.lastExportOptions?.includeSessions, isTrue);
  });

  test('原子写——目录内不留 .tmp 残留且内容完整可解析', () async {
    final file = await manager.createPreImportSnapshot();

    expect(file, isNotNull);
    final backupsDir = Directory(
      '${tempDir.path}${Platform.pathSeparator}backups',
    );
    final tmpLeftovers = backupsDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.tmp'))
        .toList();
    expect(tmpLeftovers, isEmpty, reason: 'temp+rename 落定后不得残留 .tmp');
    // 内容完整（rename 前已 flush，非半截 JSON）
    expect(jsonDecode(file!.readAsStringSync()), isA<Map<String, dynamic>>());
  });

  test('空库不快照', () async {
    chatRepo.sessions = [];
    final file = await manager.createPreImportSnapshot();
    expect(file, isNull);
  });

  test('快照失败向上抛（fail-closed，交由导入链中止）', () async {
    dataService.exportError = Exception('disk full');
    await expectLater(
      manager.createPreImportSnapshot(),
      throwsException,
    );
  });

  test('滚动保留最近 2 份快照（自动备份 3 份窗口互不挤占）', () async {
    final old1 = writeFile(
      '${AutoBackupManager.preImportFileNamePrefix}20260901_000000.json',
      mtime: DateTime(2026, 9),
    );
    final old2 = writeFile(
      '${AutoBackupManager.preImportFileNamePrefix}20260902_000000.json',
      mtime: DateTime(2026, 9, 2),
    );

    await manager.createPreImportSnapshot(); // 09-04，挤出 old1

    expect(old1.existsSync(), isFalse, reason: '只保留最近 2 份快照');
    expect(old2.existsSync(), isTrue);
  });

  test('自动备份 trim 不删快照也不删外来 .json（改进机会 2 收口）', () async {
    final preImport = writeFile(
      '${AutoBackupManager.preImportFileNamePrefix}20260903_000000.json',
      mtime: DateTime(2026, 9, 3),
    );
    final foreign = writeFile('我的手动导出.json', mtime: DateTime(2026, 9, 3));
    // 4 份自动备份（超 3 份窗口，最旧一份应被 trim）
    final stale = writeFile(
      '${AutoBackupManager.fileNamePrefix}20260801_000000.json',
      mtime: DateTime(2026, 8),
    );
    for (var d = 1; d <= 3; d++) {
      writeFile(
        '${AutoBackupManager.fileNamePrefix}2026090${d}_000000.json',
        mtime: DateTime(2026, 9, d),
      );
    }

    await manager.runIfNeeded(force: true);

    expect(preImport.existsSync(), isTrue, reason: '快照不受自动备份 trim 影响');
    expect(foreign.existsSync(), isTrue, reason: '用户手放文件不得被滚动清理');
    expect(stale.existsSync(), isFalse, reason: '自动备份自身仍按 3 份滚动');
  });

  test('原子写残留的过期 .tmp 孤儿被顺带清理，新鲜 .tmp 保留', () async {
    // 写后 rename 前崩溃/断电留下的孤儿：listBackups/_rollingTrim 按
    // `.json` 过滤都看不到它，只会无限累积
    final staleAutoTmp = writeFile(
      '${AutoBackupManager.fileNamePrefix}20260801_000000.json.tmp',
      mtime: DateTime(2026, 8, 20),
    );
    final stalePreImportTmp = writeFile(
      '${AutoBackupManager.preImportFileNamePrefix}20260901_000000.json.tmp',
      mtime: DateTime(2026, 8, 30),
    );
    // 另一链路可能正在写的 .tmp（未满清理时限）不得误删
    final freshTmp = writeFile(
      '${AutoBackupManager.fileNamePrefix}20260904_115959.json.tmp',
      mtime: now.subtract(const Duration(hours: 1)),
    );

    await manager.runIfNeeded(force: true);

    expect(staleAutoTmp.existsSync(), isFalse, reason: '过期自动备份 .tmp 孤儿应被清理');
    expect(
      stalePreImportTmp.existsSync(),
      isFalse,
      reason: '过期快照 .tmp 孤儿同样应被清理（不限前缀）',
    );
    expect(freshTmp.existsSync(), isTrue, reason: '时限内的新鲜 .tmp 可能正在写入，不得误删');
  });

  test('listBackups 只列自动备份（间隔检查不被快照/外来文件干扰）', () async {
    writeFile(
      '${AutoBackupManager.preImportFileNamePrefix}20260904_000000.json',
      mtime: DateTime(2026, 9, 4),
    );
    writeFile('外来.json', mtime: DateTime(2026, 9, 4));
    final auto = writeFile(
      '${AutoBackupManager.fileNamePrefix}20260901_000000.json',
      mtime: DateTime(2026, 9),
    );

    final list = await manager.listBackups();

    expect(list, hasLength(1));
    expect(list.single.path, auto.path);
  });

  test('24h 间隔检查只看自动备份（刚做过快照不抑制自动备份）', () async {
    // 只有快照与外来文件（无自动备份）：间隔检查不因它们跳过
    writeFile(
      '${AutoBackupManager.preImportFileNamePrefix}20260904_120000.json',
      mtime: DateTime(2026, 9, 4, 12),
    );
    final written = await manager.runIfNeeded();
    expect(written, isNotNull, reason: '快照不算「最近已备份」');
  });

  /// 自动备份失败可见性——失败落键/成功清除
  group('备份失败记录键', () {
    test('成功备份后不写失败键；先失败再成功时清除', () async {
      chatRepo.sessions = [session()];
      // 1) 失败：导出抛异常 → lastFailureKey 写入（ISO|类型名）
      dataService.exportError = Exception('disk full');
      final failed = await manager.runIfNeeded(force: true);
      expect(failed, isNull);
      final recorded = settingsRepo.overrides[AutoBackupManager.lastFailureKey];
      expect(recorded, isA<String>());
      expect(recorded as String, startsWith('2026-09-04T12:00:00.000'));
      expect(recorded, contains('Exception'));

      // 2) 成功：键被清除
      dataService.exportError = null;
      final ok = await manager.runIfNeeded(force: true);
      expect(ok, isNotNull);
      expect(
        settingsRepo.overrides.containsKey(AutoBackupManager.lastFailureKey),
        isFalse,
      );
    });
  });
}

class _RecordingDataManagementService implements DataManagementService {
  DataExportOptions? lastExportOptions;
  Exception? exportError;

  @override
  Future<String> exportFullBackup(DataExportOptions options) async {
    if (exportError != null) throw exportError!;
    lastExportOptions = options;
    return '{"version":3,"sessions":[]}';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _StubChatRepository implements ChatRepository {
  List<ChatSession> sessions = [
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
  Future<List<ChatSession>> getAllSessions() async => sessions;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _StubSettingsRepository implements SettingsRepository {
  final Map<String, dynamic> overrides = {};

  @override
  Future<Map<String, dynamic>> getUserOverrides() async => overrides;

  @override
  Future<void> setUserOverride(String key, dynamic value) async {
    overrides[key] = value;
  }

  @override
  Future<void> removeUserOverride(String key) async {
    overrides.remove(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
