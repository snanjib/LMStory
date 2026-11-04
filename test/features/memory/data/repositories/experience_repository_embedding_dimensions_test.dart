import 'dart:typed_data';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/vector/vector_engine.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/memory/data/repositories/experience_repository_impl.dart';

/// embedding_dimensions 维护与陈旧判定
///
/// - updateEmbedding 同步落库维度；
/// - getLatestEmbeddingDimensions 以最近写入维度为基准；
/// - getMemoriesWithoutEmbedding(expectedDimensions) 返回「未向量化 ∪ 维度
///   不符」并集，重建（逐条 updateEmbedding）后归零。
void main() {
  late AppDatabase db;
  late ExperienceRepositoryImpl repo;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.customSelect('SELECT 1').get();
    repo = ExperienceRepositoryImpl(
      database: db,
      vectorEngine: const VectorEngine(),
    );
  });

  tearDown(() async => db.close());

  Future<String> seedMemory(
    String summary,
    int turn, {
    int importance = 4,
  }) async {
    final memory = await repo.appendExperience(
      sessionId: 's1',
      summary: summary,
      importance: importance,
      tags: const [],
      turnNumber: turn,
    );
    return memory.memoryId;
  }

  test('updateEmbedding 落库 embedding_dimensions', () async {
    final id = await seedMemory('带向量记忆', 1);
    await repo.updateEmbedding(id, Float32List.fromList(List.filled(6, 0.2)));

    final row = await db.customSelect(
      'SELECT LENGTH(embedding) AS bytes, embedding_dimensions, '
      'has_embedding FROM experiential_memories WHERE memory_id = ?',
      variables: [Variable.withString(id)],
    ).getSingle();
    expect(row.read<int>('bytes'), 6 * 4);
    expect(row.read<int>('embedding_dimensions'), 6);
    expect(row.read<int>('has_embedding'), 1);
  });

  test('getLatestEmbeddingDimensions 取最近写入的非空维度', () async {
    expect(
      await repo.getLatestEmbeddingDimensions('s1'),
      isNull,
      reason: '会话无任何带维度的向量时返回 null',
    );

    final old = await seedMemory('旧模型记忆', 1);
    await repo.updateEmbedding(old, Float32List(6));
    final latest = await seedMemory('新模型记忆', 2);
    await repo.updateEmbedding(latest, Float32List(8));

    expect(
      await repo.getLatestEmbeddingDimensions('s1'),
      8,
      reason: '以最近一次写入的维度为基准（id 兜底同毫秒写入）',
    );
  });

  test('expectedDimensions 并入陈旧行：未向量化 ∪ 维度不符（含维度 NULL）', () async {
    final missing = await seedMemory('未向量化记忆', 1);
    final oldDim = await seedMemory('旧维度记忆', 2);
    await repo.updateEmbedding(oldDim, Float32List(6));
    final newDim = await seedMemory('新维度记忆', 3);
    await repo.updateEmbedding(newDim, Float32List(8));

    // 旧行为：不传 expected 只看 has_embedding=false
    final withoutExpected =
        await repo.getMemoriesWithoutEmbedding('s1', minImportance: 4);
    expect(withoutExpected.map((m) => m.memoryId), [missing]);

    // 期望 8：missing + 旧维度 6 的行；新维度 8 的行不算
    final union = await repo.getMemoriesWithoutEmbedding(
      's1',
      minImportance: 4,
      expectedDimensions: 8,
    );
    expect(union.map((m) => m.memoryId).toSet(), {missing, oldDim});

    // 维度列为 NULL 的行（旧库迁移前的历史形态）视为陈旧，重建即自愈
    await db.customStatement(
      'UPDATE experiential_memories SET embedding_dimensions = NULL '
      'WHERE memory_id = ?',
      [oldDim],
    );
    final unionWithNull = await repo.getMemoriesWithoutEmbedding(
      's1',
      minImportance: 4,
      expectedDimensions: 8,
    );
    expect(unionWithNull.map((m) => m.memoryId).toSet(), {missing, oldDim});
  });

  test('两种维度共存 → 统计只把非最近维度算缺口，重建后归零', () async {
    // 低重要性记忆按策略不向量化，不应进入任何口径
    await seedMemory('低重要性', 1, importance: 2);

    final oldA = await seedMemory('旧维度A', 2);
    await repo.updateEmbedding(oldA, Float32List(6));
    final oldB = await seedMemory('旧维度B', 3);
    await repo.updateEmbedding(oldB, Float32List(6));
    final newest = await seedMemory('新维度', 4);
    await repo.updateEmbedding(newest, Float32List(8));

    final expected = await repo.getLatestEmbeddingDimensions('s1');
    expect(expected, 8);

    final pending = await repo.getMemoriesWithoutEmbedding(
      's1',
      minImportance: 4,
      expectedDimensions: expected,
    );
    // 少数派/非最近维度（6 维两条）算缺口；8 维与低重要性不算
    expect(pending.map((m) => m.memoryId).toSet(), {oldA, oldB});

    // 「重建」：逐条补新维度向量
    for (final memory in pending) {
      await repo.updateEmbedding(memory.memoryId, Float32List(8));
    }
    final after = await repo.getMemoriesWithoutEmbedding(
      's1',
      minImportance: 4,
      expectedDimensions: expected,
    );
    expect(after, isEmpty, reason: '重建后未向量化与陈旧口径都应归零');
  });
}
