import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/chat/data/repositories/chat_repository_impl.dart';
import 'package:lmstory/features/chat/domain/repositories/chat_repository.dart';
import 'package:lmstory/features/settings/data/repositories/backup_repository_impl.dart';
import 'package:lmstory/features/settings/domain/entities/data_management_models.dart';

/// 会话输入草稿跨重启持久（chat_sessions.draft_input，schemaVersion 52）
///
/// 钉死五链：
/// - 新装含列；v51 旧库（无列）升级补列且既有数据保留；
/// - 半迁移（列缺但版本号已 52）beforeOpen 幂等自愈；
/// - 窄列读写跨重启往返（写入→关库→重开→读回）；
/// - 备份导出携带新列，覆盖导入恢复草稿；
/// - 窄列写隔离（草稿写不倒灌标题，收藏写不清草稿）。
void main() {
  late AppDatabase db;
  late ChatRepositoryImpl chatRepo;
  late ChatRepository chatRepoIface;
  late BackupRepositoryImpl backupRepo;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.customSelect('SELECT 1').get();
    chatRepo = ChatRepositoryImpl(database: db);
    chatRepoIface = chatRepo;
    backupRepo = BackupRepositoryImpl(database: db);
  });

  tearDown(() async => db.close());

  Future<String> seedSession(ChatRepositoryImpl repo) async {
    final s = await repo.createSession(title: '草稿会话');
    return s.sessionId;
  }

  /// 触发 drift 打开并跑 onCreate/onUpgrade（懒打开：不查询不建库）。
  Future<void> prime(AppDatabase db) async {
    await db.customSelect('SELECT 1').get();
  }

  Future<bool> hasDraftColumn(AppDatabase database) async {
    final cols =
        await database.customSelect('PRAGMA table_info(chat_sessions)').get();
    return cols.map((r) => r.read<String>('name')).contains('draft_input');
  }

  test('新装：chat_sessions 含 draft_input 列', () async {
    expect(await hasDraftColumn(db), isTrue);
  });

  test('v51 旧库升级：补列且既有会话数据保留', () async {
    final dir = Directory.systemTemp.createTempSync('lmstory_draft_v51');
    final file = File('${dir.path}/old.db');

    // 满库落一行会话，关库后原生降回 v51 形态（无列、版本号 51）
    final db1 = AppDatabase.forTesting(NativeDatabase(file));
    await prime(db1);
    final repo1 = ChatRepositoryImpl(database: db1);
    final sid = (await repo1.createSession(title: '旧库会话')).sessionId;
    await db1.close();

    final db2 = AppDatabase.forTesting(
      NativeDatabase(
        file,
        setup: (raw) {
          raw
            ..execute('ALTER TABLE chat_sessions DROP COLUMN draft_input')
            ..execute('PRAGMA user_version = 51');
        },
      ),
    );
    await prime(db2);

    expect(await hasDraftColumn(db2), isTrue, reason: 'onUpgrade 增量补列');
    final restored = await ChatRepositoryImpl(database: db2).getSession(sid);
    expect(restored.title, '旧库会话', reason: '升级不丢既有数据');
    await db2.close();
  });

  test('半迁移自愈：列缺但版本号已 52，beforeOpen 幂等补列', () async {
    final dir = Directory.systemTemp.createTempSync('lmstory_draft_half');
    final file = File('${dir.path}/half.db');

    final db1 = AppDatabase.forTesting(NativeDatabase(file));
    await prime(db1);
    await db1.close();

    final db2 = AppDatabase.forTesting(
      NativeDatabase(
        file,
        setup: (raw) {
          raw.execute('ALTER TABLE chat_sessions DROP COLUMN draft_input');
          // 版本号保持 52——onUpgrade 不再跑，走 beforeOpen 自愈
        },
      ),
    );
    await prime(db2);
    expect(await hasDraftColumn(db2), isTrue, reason: 'beforeOpen 幂等补列');
    await db2.close();
  });

  test('窄列读写：写→读回；null=清空', () async {
    final sessionId = await seedSession(chatRepo);
    await chatRepo.setSessionDraft(sessionId, '未发送的半句话');
    expect(await chatRepo.getSessionDraft(sessionId), '未发送的半句话');

    await chatRepo.setSessionDraft(sessionId, null);
    expect(await chatRepo.getSessionDraft(sessionId), isNull);
  });

  test('备份往返：导出携带草稿，覆盖导入恢复', () async {
    final sessionId = await seedSession(chatRepo);
    await chatRepo.setSessionDraft(sessionId, '随备份走的草稿');

    final data = await backupRepo.exportSessionData(sessionId);
    expect(
      (data['session'] as Map<String, dynamic>)['draft_input'],
      '随备份走的草稿',
      reason: 'SELECT * 导出自动携带新列',
    );

    await backupRepo.deleteSessionData(sessionId);
    expect(await chatRepo.getSessionDraft(sessionId), isNull);

    await backupRepo.importSessionData(data, mode: ImportMode.overwrite);
    expect(
      await chatRepo.getSessionDraft(sessionId),
      '随备份走的草稿',
      reason: '覆盖导入恢复草稿列',
    );
  });

  test('窄列写隔离：草稿写不倒灌标题，收藏写不清草稿', () async {
    final sessionId = await seedSession(chatRepo);
    await chatRepo.setSessionDraft(sessionId, '草稿');

    // 模拟并发自动命名（CAS）后再写草稿——窄列写不得倒灌旧标题
    final renamed = await chatRepoIface.updateSessionTitleIfCurrentTitleIn(
      sessionId,
      '自动命名的新标题',
      const {'草稿会话', '', '新对话'},
    );
    expect(renamed, isTrue, reason: '前置：CAS 命名成功');
    await chatRepo.setSessionDraft(sessionId, '第二次草稿');

    final s = await chatRepo.getSession(sessionId);
    expect(s.title, '自动命名的新标题', reason: '窄列写不触碰标题列');
    expect(await chatRepo.getSessionDraft(sessionId), '第二次草稿');

    // 收藏切换同样窄列——不清草稿
    await chatRepo.setSessionStarred(sessionId, starred: true);
    expect(await chatRepo.getSessionDraft(sessionId), '第二次草稿');
    expect((await chatRepo.getSession(sessionId)).isStarred, isTrue);
  });
}
