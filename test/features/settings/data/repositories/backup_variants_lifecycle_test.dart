import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/vector/vector_engine.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/chat/data/repositories/chat_repository_impl.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/memory/data/repositories/experience_repository_impl.dart';
import 'package:lmstory/features/settings/data/repositories/backup_repository_impl.dart';
import 'package:lmstory/features/settings/domain/entities/data_management_models.dart';
import 'package:lmstory/features/story_runtime/data/persistence_service_impl.dart';
import 'package:lmstory/features/story_runtime/domain/entities/round_artifacts.dart';

/// message_variants 数据生命周期守门测试
///
/// schema v49 新表曾缺席全部生命周期链（导出不含/删除不删/清除不清/
/// 覆盖导入残留幽灵变体可被切换物化进当前消息）——agent_events、
/// copySession（77e04a08）之后第四次同型遗漏。本文件钉死五链：
/// ①导出含变体行 ②导入恢复变体 ③deleteSessionData/deleteAllSessionData
/// 清变体 ④ChatRepository.deleteSession/deleteAllSessions 清变体
/// ⑤recreateConversationTables DROP+重建变体表。
/// 另设「新表守门」断言：含 session_id 列的表清单发生变化时强制 consciously
/// 更新生命周期清单，防第五次同型遗漏。
void main() {
  late AppDatabase db;
  late ChatRepositoryImpl chatRepo;
  late BackupRepositoryImpl backupRepo;
  late StoryPersistenceServiceImpl service;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.customSelect('SELECT 1').get();
    chatRepo = ChatRepositoryImpl(database: db);
    backupRepo = BackupRepositoryImpl(database: db);
    service = StoryPersistenceServiceImpl(
      database: db,
      chatRepository: chatRepo,
      experienceRepository: ExperienceRepositoryImpl(
        database: db,
        vectorEngine: const VectorEngine(),
      ),
    );
  });

  tearDown(() async {
    await db.close();
  });

  Future<String> seedSessionWithVariant(String tag) async {
    final session =
        await chatRepo.createSession(title: '变体链$tag', mode: 'advanced');
    final sessionId = session.sessionId;
    await chatRepo.addMessage(
      ChatMessage(
        messageId: 'u-$tag',
        sessionId: sessionId,
        role: 'user',
        content: '推进$tag',
        createdAt: DateTime(2026),
      ),
    );
    await service.snapshotMessageVariant(
      sessionId: sessionId,
      turnNumber: 1,
      content: '$tag 版正文',
      sourceInput: '推进$tag',
      process: StoryRoundArtifacts(
        sessionId: sessionId,
        turnNumber: 1,
        createdAt: DateTime(2026),
        replyText: '$tag 版正文',
      ),
    );
    return sessionId;
  }

  Future<int> variantRows([String? sessionId]) async {
    final rows = sessionId == null
        ? await db
            .customSelect('SELECT COUNT(*) AS c FROM message_variants')
            .get()
        : await db.customSelect(
            'SELECT COUNT(*) AS c FROM message_variants WHERE session_id = ?',
            variables: [Variable.withString(sessionId)],
          ).get();
    return rows.first.read<int>('c');
  }

  test('①② 导出含变体行，覆盖导入恢复变体（roundtrip）', () async {
    final sessionId = await seedSessionWithVariant('a');
    expect(await variantRows(sessionId), 1, reason: '前置：变体行在库');

    final data = await backupRepo.exportSessionData(sessionId);
    expect(
      (data['messageVariants'] as List).length,
      1,
      reason: '单会话导出必须含 messageVariants 键',
    );

    // 删除后覆盖导入 → 变体行恢复
    await backupRepo.deleteSessionData(sessionId);
    expect(await variantRows(sessionId), 0, reason: '③ deleteSessionData 清变体');
    // 覆盖导入：data 里的 session 行复用原 sessionId
    await backupRepo.importSessionData(
      data,
      mode: ImportMode.overwrite,
    );
    expect(
      await variantRows(sessionId),
      1,
      reason: '导入事务恢复变体行（否则换机/回滚后变体全丢）',
    );
  });

  test('③ deleteAllSessionData 清变体', () async {
    await seedSessionWithVariant('b');
    expect(await variantRows(), 1);
    await backupRepo.deleteAllSessionData();
    expect(await variantRows(), 0, reason: '全量清除不含变体即隐私残留');
  });

  test('④ ChatRepository.deleteSession / deleteAllSessions 清变体', () async {
    final sessionId = await seedSessionWithVariant('c');
    await chatRepo.deleteSession(sessionId);
    expect(
      await variantRows(),
      0,
      reason: '用户删会话主路径必须连带清变体（隐私残留）',
    );

    await seedSessionWithVariant('d');
    await chatRepo.deleteAllSessions();
    expect(await variantRows(), 0, reason: 'deleteAllSessions 同口径');
  });

  test('⑤ recreateConversationTables（清除所有数据）DROP+重建变体表', () async {
    await seedSessionWithVariant('e');
    expect(await variantRows(), 1);
    await db.recreateConversationTables();
    expect(await variantRows(), 0, reason: '清除所有数据后变体表须为空');
  });

  test('新表守门：含 session_id 列的表清单与生命周期覆盖一致（防第五次同型遗漏）', () async {
    final rows = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '%_fts%'",
        )
        .get();
    final sessionTables = <String>[];
    for (final row in rows) {
      final table = row.read<String>('name');
      final cols = await db.customSelect('PRAGMA table_info($table)').get();
      if (cols.any((c) => c.read<String>('name') == 'session_id')) {
        sessionTables.add(table);
      }
    }
    // 基线清单：新增含 session_id 的表时，本断言红——须同时接入
    // 备份导出/导入、deleteSession(Data)、deleteAllSessions(Data)、
    // recreateConversationTables 五链并更新此清单。
    expect(
      sessionTables,
      containsAll(<String>[
        'chat_sessions',
        'chat_messages',
        'compaction_points',
        'chat_session_branches',
        'experiential_memories',
        'factual_entities',
        'factual_attributes',
        'intermediate_round_artifacts',
        'message_variants',
        'agent_events',
        'failure_logs',
        'factual_relationship_migration_backup',
      ]),
    );
    expect(
      sessionTables.length,
      12,
      reason:
          '含 session_id 的表数变化=新表进库——按上文注释接入五链后再更新计数（当前清单：${sessionTables.join(', ')}）',
    );
  });
}
