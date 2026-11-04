import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/vector/vector_engine.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/memory/data/repositories/experience_repository_impl.dart';
import 'package:lmstory/features/memory/domain/services/memory_index_health.dart';

/// 记忆索引体检与补齐
///
/// 只把"应索引却缺行"算成缺口：低重要性记忆按策略不建索引（由主表子串
/// 通道兜底 + 批量提炼消费），不算异常、也不被一键补齐拉进 FTS。
void main() {
  late AppDatabase db;
  late ExperienceRepositoryImpl repo;
  late MemoryIndexHealthService service;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = ExperienceRepositoryImpl(
      database: db,
      vectorEngine: const VectorEngine(),
    );
    service = MemoryIndexHealthService(experienceRepository: repo);
  });

  tearDown(() async => db.close());

  test('体检：应索引却缺行才算缺口，低重要性记忆不算', () async {
    // 应索引（importance=4）却故意不建索引 → 缺口 1
    await repo.appendExperience(
      sessionId: 's1',
      summary: '高重要性但缺索引',
      importance: 4,
      tags: const [],
      turnNumber: 1,
      indexForRetrieval: false,
    );
    // 低重要性（importance=1）按策略不索引 → 不算缺口
    await repo.appendExperience(
      sessionId: 's1',
      summary: '低重要性记忆',
      importance: 1,
      tags: const [],
      turnNumber: 2,
      indexForRetrieval: false,
    );
    // 正常索引 → 不算缺口
    await repo.appendExperience(
      sessionId: 's1',
      summary: '正常记忆',
      importance: 4,
      tags: const [],
      turnNumber: 3,
    );

    final health = await service.inspect(
      's1',
      importanceStorageThreshold: 3,
      microVectorizeThreshold: 4,
    );

    expect(health.activeMemories, 3);
    expect(health.unindexedIndexableMemories, 1);
    expect(health.keywordIndexHealthy, isFalse);
    // 向量缺口只算达到向量化门槛（≥4）的两条；低重要性按策略不向量化
    expect(health.memoriesWithoutEmbedding, 2);
  });

  test('补齐：只补应索引记忆，低重要性保持不索引', () async {
    await repo.appendExperience(
      sessionId: 's1',
      summary: '高重要性但缺索引',
      importance: 4,
      tags: const [],
      turnNumber: 1,
      indexForRetrieval: false,
    );
    await repo.appendExperience(
      sessionId: 's1',
      summary: '低重要性记忆',
      importance: 1,
      tags: const [],
      turnNumber: 2,
      indexForRetrieval: false,
    );

    final repaired = await service.repairKeywordIndex(
      's1',
      importanceStorageThreshold: 3,
    );

    expect(repaired, 1);
    final health = await service.inspect(
      's1',
      importanceStorageThreshold: 3,
      microVectorizeThreshold: 4,
    );
    expect(health.unindexedIndexableMemories, 0);
    expect(health.keywordIndexHealthy, isTrue);
    // 低重要性记忆仍在"未索引"集合里（供合并流程消费）
    final stillUnindexed = await repo.getUnindexedExperiences('s1', limit: 10);
    expect(stillUnindexed.map((m) => m.importance), [1]);
  });

  test('体检：索引完整时 isHealthy（无向量缺口）', () async {
    await repo.appendExperience(
      sessionId: 's1',
      summary: '完整记忆',
      importance: 4,
      tags: const [],
      turnNumber: 1,
    );

    final health = await service.inspect(
      's1',
      importanceStorageThreshold: 3,
      microVectorizeThreshold: 5,
    );

    expect(health.keywordIndexHealthy, isTrue);
    expect(health.memoriesWithoutEmbedding, 0);
    expect(health.isHealthy, isTrue);
  });

  test('体检：两种维度共存 → 陈旧=非最近维度，未向量独立计数', () async {
    final oldA = await repo.appendExperience(
      sessionId: 's1',
      summary: '旧维度A',
      importance: 4,
      tags: const [],
      turnNumber: 1,
    );
    await repo.updateEmbedding(oldA.memoryId, Float32List(6));
    final oldB = await repo.appendExperience(
      sessionId: 's1',
      summary: '旧维度B',
      importance: 4,
      tags: const [],
      turnNumber: 2,
    );
    await repo.updateEmbedding(oldB.memoryId, Float32List(6));
    // 未向量化（未配置嵌入模型时的记忆）
    await repo.appendExperience(
      sessionId: 's1',
      summary: '从未向量化',
      importance: 4,
      tags: const [],
      turnNumber: 3,
    );
    // 最近写入：新模型 8 维——基准翻新后，两条 6 维行成为陈旧
    final newest = await repo.appendExperience(
      sessionId: 's1',
      summary: '新维度',
      importance: 4,
      tags: const [],
      turnNumber: 4,
    );
    await repo.updateEmbedding(newest.memoryId, Float32List(8));

    final health = await service.inspect(
      's1',
      importanceStorageThreshold: 3,
      microVectorizeThreshold: 4,
    );

    expect(health.expectedEmbeddingDimensions, 8);
    expect(health.memoriesWithoutEmbedding, 1, reason: '只有未配置那一条');
    expect(health.staleEmbeddingMemories, 2, reason: '两条 6 维旧向量算陈旧');
    expect(health.isHealthy, isFalse);

    // 「重建」：未向量化 + 陈旧全部补成基准维度后 → 健康
    final pending = await repo.getMemoriesWithoutEmbedding(
      's1',
      minImportance: 4,
      expectedDimensions: health.expectedEmbeddingDimensions,
    );
    expect(pending, hasLength(3));
    for (final memory in pending) {
      await repo.updateEmbedding(memory.memoryId, Float32List(8));
    }
    final after = await service.inspect(
      's1',
      importanceStorageThreshold: 3,
      microVectorizeThreshold: 4,
    );
    expect(after.memoriesWithoutEmbedding, 0);
    expect(after.staleEmbeddingMemories, 0);
    expect(after.isHealthy, isTrue);
  });
}
