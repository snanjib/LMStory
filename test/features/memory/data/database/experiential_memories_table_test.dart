import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/vector/vector_engine.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/memory/data/repositories/experience_repository_impl.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async => db.close());

  test('experiential_memories 表创建成功，含全部字段', () async {
    // 触发连接打开 + onCreate
    await db.customSelect('SELECT 1').get();

    // 验证表存在且字段齐全
    final columns = await db
        .customSelect("PRAGMA table_info('experiential_memories')")
        .get();
    final columnNames = columns.map((r) => r.data['name'] as String).toSet();

    expect(
      columnNames,
      containsAll([
        'id',
        'memory_id',
        'session_id',
        'summary',
        'importance',
        'tags',
        'turn_number',
        'narrative_time',
        'narrative_period',
        'embedding',
        'has_embedding',
        'is_archived',
        'is_summary',
        'archived_event_ids',
        'created_at',
      ]),
    );
  });

  test('memories_fts 虚拟表创建成功（trigram 支持中文检索）', () async {
    await db.customSelect('SELECT 1').get();

    // FTS5 表通过插入 + MATCH 查询验证
    // tokenize='trigram'：对中文按 3 字符滑动窗口切分（UTF-8 字符级）
    // ≥3 字符查询走 trigram MATCH；<3 字符查询自动 fallback 到 LIKE
    await db.customStatement(
      'INSERT INTO memories_fts(summary, memory_id, memory_type, session_id) '
      "VALUES ('测试摘要内容', 'm1', 'experiential', 's1')",
    );

    // 4 字符中文查询：trigram 提取 ['测试摘', '试摘要']，应命中
    final rows = await db
        .customSelect(
          "SELECT memory_id FROM memories_fts WHERE memories_fts MATCH '测试摘要'",
        )
        .get();

    expect(rows.length, 1);
    expect(rows.first.data['memory_id'], 'm1');
  });

  test('experiential_memories 索引创建成功', () async {
    await db.customSelect('SELECT 1').get();

    final indexes = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type='index' "
          "AND tbl_name='experiential_memories'",
        )
        .get();
    final indexNames = indexes.map((r) => r.data['name'] as String).toSet();

    expect(
      indexNames,
      containsAll([
        'idx_exp_session_archived_imp',
        'idx_exp_session_turn',
        'idx_exp_session_embedding',
      ]),
    );
  });

  test('memory_id 唯一约束生效', () async {
    await db.customSelect('SELECT 1').get();

    await db.customStatement(
      'INSERT INTO experiential_memories(memory_id, session_id, summary, turn_number) '
      "VALUES ('m1', 's1', '摘要1', 1)",
    );

    // 重复 memory_id 应抛异常
    expect(
      () => db.customStatement(
        'INSERT INTO experiential_memories(memory_id, session_id, summary, turn_number) '
        "VALUES ('m1', 's1', '摘要2', 2)",
      ),
      throwsA(isA<Object>()),
    );
  });

  test('v50 迁移：旧库缺 embedding_dimensions 列，打开后补列并按 BLOB 回填', () async {
    final dir = Directory.systemTemp.createTempSync('lmstory_v50_upgrade');
    final file = File('${dir.path}/test.db');
    AppDatabase fileDb;

    try {
      // 1. 以当前 schema 建库，写入两条带向量的记忆（维度随 updateEmbedding 落库）
      fileDb = AppDatabase.forTesting(NativeDatabase(file));
      await fileDb.customSelect('SELECT 1').get();
      final repo = ExperienceRepositoryImpl(
        database: fileDb,
        vectorEngine: const VectorEngine(),
      );
      for (var i = 0; i < 2; i++) {
        final memory = await repo.appendExperience(
          sessionId: 's1',
          summary: '带向量的记忆 $i',
          importance: 4,
          tags: const [],
          turnNumber: i + 1,
        );
        await repo.updateEmbedding(
          memory.memoryId,
          Float32List.fromList(List.filled(8, 0.1)),
        );
      }
      await fileDb.close();

      // 2. 模拟 v49 旧库：DROP 维度列 + 回拨版本号（存量行有向量但维度未知）
      final native = NativeDatabase(
        file,
        setup: (raw) {
          raw
            ..execute(
              'ALTER TABLE experiential_memories DROP COLUMN embedding_dimensions',
            )
            ..execute('PRAGMA user_version = 49');
        },
      );

      // 3. 重新打开：onUpgrade(49→50) → repairSchema 补列 → beforeOpen 幂等回填
      fileDb = AppDatabase.forTesting(native);
      await fileDb.customSelect('SELECT 1').get();

      final cols = await fileDb
          .customSelect('PRAGMA table_info(experiential_memories)')
          .get();
      expect(
        cols.map((r) => r.read<String>('name')),
        contains('embedding_dimensions'),
        reason: 'repairSchema 必须补齐维度列',
      );

      final rows = await fileDb
          .customSelect(
            'SELECT memory_id, LENGTH(embedding) AS bytes, '
            'embedding_dimensions FROM experiential_memories',
          )
          .get();
      expect(rows, hasLength(2));
      for (final row in rows) {
        expect(row.read<int>('bytes'), 8 * 4, reason: 'Float32 × 8 维 = 32 字节');
        expect(
          row.readNullable<int>('embedding_dimensions'),
          8,
          reason: '回填后维度 = LENGTH(blob)/4',
        );
      }
      await fileDb.close();
    } finally {
      dir.deleteSync(recursive: true);
    }
  });
}
