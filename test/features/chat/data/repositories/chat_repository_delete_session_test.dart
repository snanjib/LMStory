import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/chat/data/repositories/chat_repository_impl.dart';
import 'package:lmstory/features/memory/data/repositories/factual_repository_impl.dart';
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';

/// deleteSession 会话级数据完整性测试
///
/// 删除会话必须清掉该会话的全部衍生数据：
/// 消息/压缩点/分支/事件日志（既有）+ 经历记忆/事实三表/轮次产物/
/// 两个 FTS 索引/失败日志（本批补齐）。同库其他会话不受影响。
void main() {
  late AppDatabase db;
  late ChatRepositoryImpl repo;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.customSelect('SELECT 1').get();
    repo = ChatRepositoryImpl(database: db);
  });

  tearDown(() async {
    await db.close();
  });

  Future<int> count(String sql, [List<Object?> args = const []]) async {
    final rows = await db
        .customSelect(sql, variables: args.map(Variable.new).toList())
        .get();
    return rows.first.read<int>('c');
  }

  test('deleteSession 清空该会话全部衍生数据且不伤及其他会话', () async {
    const s1 = 's1';
    const s2 = 's2';
    final now = DateTime.now();

    // 会话与消息
    await db.customStatement(
      'INSERT INTO chat_sessions (session_id, title) VALUES (?, ?), (?, ?)',
      [s1, '会话一', s2, '会话二'],
    );
    await db.customStatement(
      'INSERT INTO chat_messages (message_id, session_id, role, content) '
      "VALUES ('m1', ?, 'user', 'hi'), ('m2', ?, 'user', 'yo')",
      [s1, s2],
    );

    // 经历记忆
    await db.customStatement(
      'INSERT INTO experiential_memories (memory_id, session_id, summary, '
      'turn_number) VALUES (?, ?, ?, ?), (?, ?, ?, ?)',
      ['mem1', s1, '经历一', 1, 'mem2', s2, '经历二', 1],
    );

    // 事实层（实体走仓库，历史与 FTS 走原生语句）
    final factualRepo = FactualRepositoryImpl(database: db);
    for (final (id, sid) in [('ent_1', s1), ('ent_2', s2)]) {
      await factualRepo.createEntity(
        FactualEntity(
          entityId: id,
          sessionId: sid,
          type: FactualEntityType.character,
          primaryName: '角色$id',
          aliases: const [],
          importance: 3,
          createdTurn: 0,
          createdAt: now,
        ),
      );
    }
    await db.customStatement(
      'INSERT INTO factual_memory_history (entity_id, action, turn_number) '
      "VALUES ('ent_1', 'create', 0), ('ent_2', 'create', 0)",
    );
    await db.customStatement(
      'INSERT INTO factual_fts (primary_name, aliases, description, '
      'entity_id, session_id) VALUES (?, ?, ?, ?, ?), (?, ?, ?, ?, ?)',
      ['角色一', '', '', 'ent_1', s1, '角色二', '', '', 'ent_2', s2],
    );

    // 轮次产物
    await db.customStatement(
      'INSERT INTO intermediate_round_artifacts (session_id, turn_number, '
      'extracted_keywords, retrieved_memories, review_executed, created_at) '
      'VALUES (?, 1, ?, ?, 0, 1), (?, 1, ?, ?, 0, 1)',
      [s1, '[]', '[]', s2, '[]', '[]'],
    );

    // memories_fts
    await db.customStatement(
      'INSERT INTO memories_fts (summary, memory_id, memory_type, session_id) '
      "VALUES ('s1 摘要', 'mem1', 'micro', ?), ('s2 摘要', 'mem2', 'micro', ?)",
      [s1, s2],
    );

    // 导演事件日志 + 失败日志
    await db.customStatement(
      'INSERT INTO agent_events (session_id, seq, type, time, data) '
      "VALUES (?, 1, 'round_started', 1, '{}'), (?, 1, 'round_started', 1, '{}')",
      [s1, s2],
    );
    await db.customStatement(
      'INSERT INTO failure_logs (session_id, mode, error_category, created_at) '
      "VALUES (?, 'chat', 'network', 1), (?, 'chat', 'network', 1)",
      [s1, s2],
    );

    await repo.deleteSession(s1);

    // s1 全部清空
    expect(
      await count(
        'SELECT COUNT(*) c FROM chat_sessions WHERE session_id = ?',
        [s1],
      ),
      0,
    );
    expect(
      await count(
        'SELECT COUNT(*) c FROM chat_messages WHERE session_id = ?',
        [s1],
      ),
      0,
    );
    expect(
      await count(
        'SELECT COUNT(*) c FROM experiential_memories WHERE session_id = ?',
        [s1],
      ),
      0,
    );
    expect(
      await count(
        'SELECT COUNT(*) c FROM factual_entities WHERE session_id = ?',
        [s1],
      ),
      0,
    );
    expect(
      await count(
        'SELECT COUNT(*) c FROM factual_attributes WHERE session_id = ?',
        [s1],
      ),
      0,
    );
    expect(
      await count(
        'SELECT COUNT(*) c FROM factual_memory_history WHERE entity_id IN '
        '(SELECT entity_id FROM factual_entities WHERE session_id = ?)',
        [s1],
      ),
      0,
    );
    expect(
      await count(
        'SELECT COUNT(*) c FROM factual_fts WHERE session_id = ?',
        [s1],
      ),
      0,
    );
    expect(
      await count(
        'SELECT COUNT(*) c FROM intermediate_round_artifacts WHERE session_id = ?',
        [s1],
      ),
      0,
    );
    expect(
      await count(
        'SELECT COUNT(*) c FROM memories_fts WHERE session_id = ?',
        [s1],
      ),
      0,
    );
    expect(
      await count(
        'SELECT COUNT(*) c FROM agent_events WHERE session_id = ?',
        [s1],
      ),
      0,
    );
    expect(
      await count(
        'SELECT COUNT(*) c FROM failure_logs WHERE session_id = ?',
        [s1],
      ),
      0,
    );

    // s2 完好
    expect(
      await count(
        'SELECT COUNT(*) c FROM chat_sessions WHERE session_id = ?',
        [s2],
      ),
      1,
    );
    expect(
      await count(
        'SELECT COUNT(*) c FROM chat_messages WHERE session_id = ?',
        [s2],
      ),
      1,
    );
    expect(
      await count(
        'SELECT COUNT(*) c FROM experiential_memories WHERE session_id = ?',
        [s2],
      ),
      1,
    );
    expect(
      await count(
        'SELECT COUNT(*) c FROM factual_entities WHERE session_id = ?',
        [s2],
      ),
      1,
    );
    expect(
      await count(
        'SELECT COUNT(*) c FROM factual_fts WHERE session_id = ?',
        [s2],
      ),
      1,
    );
    expect(
      await count(
        'SELECT COUNT(*) c FROM intermediate_round_artifacts WHERE session_id = ?',
        [s2],
      ),
      1,
    );
    expect(
      await count(
        'SELECT COUNT(*) c FROM memories_fts WHERE session_id = ?',
        [s2],
      ),
      1,
    );
    expect(
      await count(
        'SELECT COUNT(*) c FROM agent_events WHERE session_id = ?',
        [s2],
      ),
      1,
    );
    expect(
      await count(
        'SELECT COUNT(*) c FROM failure_logs WHERE session_id = ?',
        [s2],
      ),
      1,
    );
  });

  test('deleteMessages 清空消息时连带清空压缩点（不再依赖失配兜底）', () async {
    await db.customStatement(
      "INSERT INTO chat_sessions (session_id, title) VALUES ('s1', 'T')",
    );
    await db.customStatement(
      'INSERT INTO chat_messages (message_id, session_id, role, content) '
      "VALUES ('m1', 's1', 'user', 'a'), ('m2', 's1', 'assistant', 'b')",
    );
    await db.customStatement(
      'INSERT INTO compaction_points (session_id, summary_message_id, '
      "boundary_message_id) VALUES ('s1', 'm2', 'm1')",
    );

    await repo.deleteMessages('s1');

    expect(await count('SELECT COUNT(*) c FROM compaction_points'), 0);
  });

  test('pruneInvalidCompactionPoints 清理 boundary 已被删除的孤儿压缩点', () async {
    await db.customStatement(
      "INSERT INTO chat_sessions (session_id, title) VALUES ('s1', 'T')",
    );
    // m1 已删除（boundary 指向不存在消息），m2 存在
    await db.customStatement(
      'INSERT INTO chat_messages (message_id, session_id, role, content) '
      "VALUES ('m2', 's1', 'assistant', 'b')",
    );
    await db.customStatement(
      'INSERT INTO compaction_points (session_id, summary_message_id, '
      "boundary_message_id) VALUES ('s1', 'm2', 'm1')",
    );

    await repo.pruneInvalidCompactionPoints('s1');

    expect(
      await count('SELECT COUNT(*) c FROM compaction_points'),
      0,
      reason: 'boundary 消失的压缩点必须被清理，否则下次请求静默退回全量上下文',
    );
  });
}
