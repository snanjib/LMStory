import 'dart:typed_data';

import 'package:drift/drift.dart' show Variable;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/demo/data/demo_session_handover.dart';

/// 在库中布置一个「已完成一回合」的导演会话夹具（直接 SQL 精确控制列值）
Future<void> seedRoundFixture(AppDatabase db, String sessionId) async {
  await db.customStatement(
    'INSERT INTO chat_sessions (session_id, title, mode, created_at, '
    'last_active_at, message_count, preset_id, model_id, '
    'generating_preset_id, generating_model_id, draft_input, next_turn, '
    'system_prompt_override, temperature, top_p, max_tokens, '
    'presence_penalty, frequency_penalty, stream_enabled) VALUES '
    "(?, '演示会话', 'advanced', 1000, 1001, 2, 'demo-preset-x', 'demo-model-x', "
    "'demo-preset-x', 'demo-model-x', '（残留草稿）', 2, '异世界模板全文', "
    '0.7, 0.9, 4096, 0.0, 0.0, 1)',
    [sessionId],
  );
  await db.customStatement(
    'INSERT INTO chat_messages (message_id, session_id, role, content, '
    "created_at) VALUES (?, ?, 'user', '（推开木门）', 1000)",
    ['m-u-$sessionId', sessionId],
  );
  await db.customStatement(
    'INSERT INTO chat_messages (message_id, session_id, role, content, '
    "created_at) VALUES (?, ?, 'assistant', '正文两段……', 1001)",
    ['m-a-$sessionId', sessionId],
  );
  await db.customStatement(
    'INSERT INTO experiential_memories (memory_id, session_id, '
    'importance, turn_number, summary, has_embedding, embedding, '
    'embedding_dimensions) VALUES '
    "(?, ?, 4, 1, '初入白鹿旅店与玛尔塔相遇', 1, ?, 8)",
    [
      'mem-$sessionId',
      sessionId,
      Uint8List.fromList([1, 2, 3, 4]),
    ],
  );
  await db.customStatement(
    'INSERT INTO factual_entities (entity_id, session_id, primary_name, '
    "type, created_turn) VALUES (?, ?, '玛尔塔', 'character', 1)",
    ['ent-$sessionId', sessionId],
  );
  await db.customStatement(
    'INSERT INTO factual_attributes (attribute_id, entity_id, session_id, '
    "attr_key, value) VALUES (?, ?, ?, 'description', '老板娘')",
    ['attr-$sessionId', 'ent-$sessionId', sessionId],
  );
  await db.customStatement(
    'INSERT INTO intermediate_round_artifacts (session_id, turn_number, '
    "generated_text, created_at) VALUES (?, 1, '正文两段……', 1001)",
    [sessionId],
  );
  await db.customStatement(
    'INSERT INTO agent_events (session_id, seq, type, time, data) VALUES '
    "(?, 1, 'round_started', 1000, '{}')",
    [sessionId],
  );
  await db.customStatement(
    'INSERT INTO memories_fts (summary, memory_id, session_id) '
    "VALUES ('初入白鹿旅店与玛尔塔相遇', ?, ?)",
    ['mem-$sessionId', sessionId],
  );
}

Future<int> count(
  AppDatabase db,
  String sql, [
  List<String> vars = const [],
]) async {
  final rows = await db.customSelect(
    sql,
    variables: [for (final v in vars) Variable.withString(v)],
  ).get();
  return rows.first.read<int>('n');
}

void main() {
  late AppDatabase demoDb;
  late AppDatabase realDb;

  setUp(() async {
    demoDb = AppDatabase.forTesting(NativeDatabase.memory());
    realDb = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await demoDb.close();
    await realDb.close();
  });

  group('T-HO-1 全量交接', () {
    test('11 表搬运 + 变换（清引用/剥向量/去草稿）+ FTS 重建 + 源清理', () async {
      const sid = 'sess-round-1';
      await seedRoundFixture(demoDb, sid);

      final result = await DemoSessionHandover().run(
        demoDb: demoDb,
        realDb: realDb,
        sourceSessionId: sid,
      );
      expect(result, DemoHandoverResult.imported);

      // 会话行：存在且引用已清空
      final sessionRows = await realDb.customSelect(
        'SELECT generating_preset_id, generating_model_id, preset_id, '
        'model_id, draft_input, next_turn, system_prompt_override '
        'FROM chat_sessions WHERE session_id = ?',
        variables: [Variable.withString(sid)],
      ).get();
      final s = sessionRows.single.data;
      expect(s['generating_preset_id'], '');
      expect(s['generating_model_id'], '');
      expect(s['preset_id'], '');
      expect(s['model_id'], '');
      expect(s['draft_input'], isNull);
      expect(s['next_turn'], 2);
      expect(s['system_prompt_override'], '异世界模板全文');

      // 消息/实体/属性/产物/事件全数到位
      expect(await count(realDb, 'SELECT COUNT(*) n FROM chat_messages'), 2);
      expect(
        await count(
          realDb,
          'SELECT COUNT(*) n FROM factual_entities WHERE primary_name = ?',
          ['玛尔塔'],
        ),
        1,
      );
      expect(
        await count(realDb, 'SELECT COUNT(*) n FROM factual_attributes'),
        1,
      );
      expect(
        await count(
          realDb,
          'SELECT COUNT(*) n FROM intermediate_round_artifacts',
        ),
        1,
      );
      expect(await count(realDb, 'SELECT COUNT(*) n FROM agent_events'), 1);

      // 记忆行：文本保留、向量三字段清除
      final mem = (await realDb.customSelect(
        'SELECT summary, has_embedding, embedding, embedding_dimensions '
        'FROM experiential_memories WHERE session_id = ?',
        variables: [Variable.withString(sid)],
      ).get())
          .single
          .data;
      expect(mem['summary'], contains('白鹿旅店'));
      expect(mem['has_embedding'], 0);
      expect(mem['embedding'], isNull);
      expect(mem['embedding_dimensions'], isNull);

      // FTS 已重建（正式库 memories_fts 可查）
      final fts = await realDb.customSelect(
        'SELECT COUNT(*) n FROM memories_fts WHERE session_id = ? '
        "AND summary MATCH '白鹿旅店'",
        variables: [Variable.withString(sid)],
      ).get();
      expect(fts.first.read<int>('n'), 1);

      // demo 库源会话已清理
      expect(
        await count(demoDb, 'SELECT COUNT(*) n FROM chat_sessions'),
        0,
      );
    });

    test('sourceMissing：演示库无源会话', () async {
      final result = await DemoSessionHandover().run(
        demoDb: demoDb,
        realDb: realDb,
        sourceSessionId: 'nope',
      );
      expect(result, DemoHandoverResult.sourceMissing);
    });
  });

  group('T-HO-2/3 幂等与崩溃窗口', () {
    test('重复交接 → alreadyImported 且正式库无重复', () async {
      const sid = 'sess-round-2';
      await seedRoundFixture(demoDb, sid);
      final handover = DemoSessionHandover();
      expect(
        await handover.run(
          demoDb: demoDb,
          realDb: realDb,
          sourceSessionId: sid,
        ),
        DemoHandoverResult.imported,
      );
      // 重跑（模拟提交后状态标记前崩溃→重启）
      expect(
        await handover.run(
          demoDb: demoDb,
          realDb: realDb,
          sourceSessionId: sid,
        ),
        DemoHandoverResult.alreadyImported,
      );
      expect(await count(realDb, 'SELECT COUNT(*) n FROM chat_messages'), 2);
      expect(await count(realDb, 'SELECT COUNT(*) n FROM chat_sessions'), 1);
      expect(
        await count(realDb, 'SELECT COUNT(*) n FROM memories_fts'),
        1,
        reason: 'FTS 重建幂等（重建前先清）',
      );
    });

    test('导入提交前崩溃（事务内注入失败）→ 正式库零残留、源数据完好、可重试', () async {
      const sid = 'sess-round-3';
      await seedRoundFixture(demoDb, sid);

      final crashed = DemoSessionHandover(
        failBeforeCommit: () => throw Exception('boom-before-commit'),
      );
      await expectLater(
        crashed.run(demoDb: demoDb, realDb: realDb, sourceSessionId: sid),
        throwsException,
      );

      // 正式库零残留（事务回滚）
      expect(await count(realDb, 'SELECT COUNT(*) n FROM chat_sessions'), 0);
      expect(await count(realDb, 'SELECT COUNT(*) n FROM chat_messages'), 0);
      expect(await count(realDb, 'SELECT COUNT(*) n FROM memories_fts'), 0);

      // 源数据完好（demo 库未清理）
      expect(await count(demoDb, 'SELECT COUNT(*) n FROM chat_sessions'), 1);

      // 重试成功
      final retried = await DemoSessionHandover().run(
        demoDb: demoDb,
        realDb: realDb,
        sourceSessionId: sid,
      );
      expect(retried, DemoHandoverResult.imported);
      expect(await count(realDb, 'SELECT COUNT(*) n FROM chat_messages'), 2);
    });
  });
}
