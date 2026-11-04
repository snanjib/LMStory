import 'dart:typed_data';

// ignore_for_file: avoid_redundant_argument_values
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/vector/vector_engine.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/memory/data/repositories/experience_repository_impl.dart';
import 'package:lmstory/features/memory/domain/entities/scored_memory.dart';

/// searchExperiencesMultiChannel 单元测试
///
/// 验证 5 路并行检索（3 FTS5 + 2 Vector）的核心行为：
/// - 多通道命中后分数合并（同 memoryId 取最高分）
/// - 空通道自动跳过（空 query / null vector）
/// - topK 截断
/// - FTS5 + Vector 跨通道合并打分
///
/// 独立文件原因：experience_repository_impl_test.dart 已 1452 行（超 500 行红线），
/// 本文件复制必要 setup，避免继续膨胀主测试文件。
///
/// trigram 分词器要求查询 ≥3 字符，故所有中文关键词用 4 字。
void main() {
  late AppDatabase db;
  late ExperienceRepositoryImpl repo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = ExperienceRepositoryImpl(
      database: db,
      vectorEngine: const VectorEngine(),
    );
  });

  tearDown(() async => db.close());

  // 默认检索参数（与 RetrievalConfig 默认值一致）
  const topK = 10;
  const fts5Weight = 0.5;
  const vectorWeight = 0.5;
  const keyEventThreshold = 4;
  const keyEventBoost = 1.5;
  const epsilon = 0.01;

  /// 便捷封装：调用 searchExperiencesMultiChannel。
  Future<List<ScoredMemory>> searchMulti({
    required String sessionId,
    List<String> fts5Queries = const [],
    List<({String query, Float32List? vector})> vectorQueries = const [],
    int tk = topK,
  }) {
    return repo.searchExperiencesMultiChannel(
      sessionId: sessionId,
      fts5Queries: fts5Queries,
      vectorQueries: vectorQueries,
      topK: tk,
      fts5Weight: fts5Weight,
      vectorWeight: vectorWeight,
      keyEventThreshold: keyEventThreshold,
      keyEventBoost: keyEventBoost,
      normalizationEpsilon: epsilon,
    );
  }

  group('searchExperiencesMultiChannel', () {
    test('1. 5 通道全部命中 → 合并后按 finalScore 降序返回', () async {
      // 3 条 FTS5 记忆（角色/物品/地点各 1 条）
      final memChar = await repo.appendExperience(
        sessionId: 's1',
        summary: '勇者古碑角色',
        importance: 3,
        tags: ['角色'],
        turnNumber: 1,
      );
      await repo.insertFtsIndex(
        memoryId: memChar.memoryId,
        summary: '勇者古碑角色',
        sessionId: 's1',
      );

      final memItem = await repo.appendExperience(
        sessionId: 's1',
        summary: '宝剑物品锻造',
        importance: 3,
        tags: ['物品'],
        turnNumber: 2,
      );
      await repo.insertFtsIndex(
        memoryId: memItem.memoryId,
        summary: '宝剑物品锻造',
        sessionId: 's1',
      );

      final memLoc = await repo.appendExperience(
        sessionId: 's1',
        summary: '密林地点深处',
        importance: 3,
        tags: ['地点'],
        turnNumber: 3,
      );
      await repo.insertFtsIndex(
        memoryId: memLoc.memoryId,
        summary: '密林地点深处',
        sessionId: 's1',
      );

      // 2 条 Vector 记忆（行动/剧情各 1 条）
      final memAct = await repo.appendExperience(
        sessionId: 's1',
        summary: '行动探索前进',
        importance: 3,
        tags: ['行动'],
        turnNumber: 4,
      );
      await repo.updateEmbedding(
        memAct.memoryId,
        Float32List.fromList([1, 0, 0, 0]),
      );

      final memPlot = await repo.appendExperience(
        sessionId: 's1',
        summary: '剧情高潮转折',
        importance: 3,
        tags: ['剧情'],
        turnNumber: 5,
      );
      await repo.updateEmbedding(
        memPlot.memoryId,
        Float32List.fromList([0, 1, 0, 0]),
      );

      final results = await searchMulti(
        sessionId: 's1',
        fts5Queries: [
          '勇者古碑', // 命中 memChar
          '宝剑物品', // 命中 memItem
          '密林地点', // 命中 memLoc
        ],
        vectorQueries: [
          (query: '行动探索', vector: Float32List.fromList([1, 0, 0, 0])),
          (query: '剧情高潮', vector: Float32List.fromList([0, 1, 0, 0])),
        ],
      );

      // 5 条全部命中
      expect(results.length, 5);
      // 按 finalScore 降序
      for (var i = 0; i < results.length - 1; i++) {
        expect(
          results[i].finalScore,
          greaterThanOrEqualTo(results[i + 1].finalScore),
        );
      }
    });

    test('2. 部分 FTS5 通道为空字符串 → 自动跳过空通道', () async {
      final memChar = await repo.appendExperience(
        sessionId: 's1',
        summary: '勇者古碑角色',
        importance: 3,
        tags: [],
        turnNumber: 1,
      );
      await repo.insertFtsIndex(
        memoryId: memChar.memoryId,
        summary: '勇者古碑角色',
        sessionId: 's1',
      );

      // items / locations 通道为空字符串 → 只有 characters 通道搜索
      final results = await searchMulti(
        sessionId: 's1',
        fts5Queries: ['勇者古碑', '', ''],
        vectorQueries: const [],
      );

      expect(results.length, 1);
      expect(results.first.memory.memoryId, memChar.memoryId);
      expect(results.first.fts5Score, greaterThan(0));
    });

    test('3. 部分 Vector 通道 vector=null → 自动跳过 null 通道', () async {
      final memAct = await repo.appendExperience(
        sessionId: 's1',
        summary: '行动探索前进',
        importance: 3,
        tags: [],
        turnNumber: 1,
      );
      await repo.updateEmbedding(
        memAct.memoryId,
        Float32List.fromList([1, 0, 0, 0]),
      );

      // plots 通道 vector=null → 只有 actions 通道搜索
      final results = await searchMulti(
        sessionId: 's1',
        fts5Queries: const [],
        vectorQueries: [
          (query: '行动探索', vector: Float32List.fromList([1, 0, 0, 0])),
          (query: '剧情高潮', vector: null),
        ],
      );

      expect(results.length, 1);
      expect(results.first.memory.memoryId, memAct.memoryId);
      expect(results.first.vectorScore, greaterThan(0));
    });

    test('4. 全部通道空 → 返回空列表（不抛异常）', () async {
      await repo.appendExperience(
        sessionId: 's1',
        summary: '勇者古碑角色',
        importance: 3,
        tags: [],
        turnNumber: 1,
      );

      final results = await searchMulti(
        sessionId: 's1',
        fts5Queries: const ['', '', ''],
        vectorQueries: const [
          (query: '', vector: null),
          (query: '', vector: null),
        ],
      );

      expect(results, isEmpty);
    });

    test('5. 同一 memoryId 在多路 FTS5 中命中 → 取最高分', () async {
      // 一条记忆同时包含角色和物品关键词
      final mem = await repo.appendExperience(
        sessionId: 's1',
        summary: '勇者宝剑古碑',
        importance: 3,
        tags: [],
        turnNumber: 1,
      );
      await repo.insertFtsIndex(
        memoryId: mem.memoryId,
        summary: '勇者宝剑古碑',
        sessionId: 's1',
      );

      // characters 和 items 通道都命中同一条记忆
      final results = await searchMulti(
        sessionId: 's1',
        fts5Queries: ['勇者古碑', '宝剑古碑', ''],
        vectorQueries: const [],
      );

      // 只返回 1 条（不重复）
      expect(results.length, 1);
      expect(results.first.memory.memoryId, mem.memoryId);
      // fts5Score 应为两路中的最高分
      expect(results.first.fts5Score, greaterThan(0));
    });

    test('6. topK 截断：结果数 > topK 时只返回 topK 条', () async {
      // 创建 5 条 FTS5 记忆
      for (var i = 0; i < 5; i++) {
        final mem = await repo.appendExperience(
          sessionId: 's1',
          summary: '勇者古碑探索$i',
          importance: 3,
          tags: [],
          turnNumber: i + 1,
        );
        await repo.insertFtsIndex(
          memoryId: mem.memoryId,
          summary: '勇者古碑探索$i',
          sessionId: 's1',
        );
      }

      // topK=3 → 只返回 3 条
      final results = await searchMulti(
        sessionId: 's1',
        fts5Queries: ['勇者古碑', '', ''],
        vectorQueries: const [],
        tk: 3,
      );

      expect(results.length, 3);
      // 验证降序
      for (var i = 0; i < results.length - 1; i++) {
        expect(
          results[i].finalScore,
          greaterThanOrEqualTo(results[i + 1].finalScore),
        );
      }
    });

    test('7. FTS5 + Vector 跨通道合并：同记忆两路命中 → 分数叠加', () async {
      // 一条记忆同时有 FTS5 索引和 Vector embedding
      final mem = await repo.appendExperience(
        sessionId: 's1',
        summary: '勇者古碑探索',
        importance: 5, // 关键事件 → ×1.5 加权
        tags: [],
        turnNumber: 1,
      );
      await repo.insertFtsIndex(
        memoryId: mem.memoryId,
        summary: '勇者古碑探索',
        sessionId: 's1',
      );
      await repo.updateEmbedding(
        mem.memoryId,
        Float32List.fromList([1, 0, 0, 0]),
      );

      // 另一条只有 FTS5
      final memFtsOnly = await repo.appendExperience(
        sessionId: 's1',
        summary: '勇者古碑战斗',
        importance: 3,
        tags: [],
        turnNumber: 2,
      );
      await repo.insertFtsIndex(
        memoryId: memFtsOnly.memoryId,
        summary: '勇者古碑战斗',
        sessionId: 's1',
      );

      final results = await searchMulti(
        sessionId: 's1',
        fts5Queries: ['勇者古碑', '', ''],
        vectorQueries: [
          (query: '探索行动', vector: Float32List.fromList([1, 0, 0, 0])),
        ],
      );

      // 两记忆都命中 FTS5，但 mem 还命中 Vector
      expect(results.length, 2);
      // mem 有 FTS5 + Vector 双路命中 + 关键事件加权 → 排第一
      expect(results.first.memory.memoryId, mem.memoryId);
      expect(results.first.fts5Score, greaterThan(0));
      expect(results.first.vectorScore, greaterThan(0));
      // memFtsOnly 只有 FTS5 命中
      expect(results.last.memory.memoryId, memFtsOnly.memoryId);
      expect(results.last.fts5Score, greaterThan(0));
      expect(results.last.vectorScore, 0);
    });

    test('8. 会话隔离：只检索当前 sessionId 的记忆', () async {
      // s1 的记忆
      final mem1 = await repo.appendExperience(
        sessionId: 's1',
        summary: '勇者古碑探索',
        importance: 3,
        tags: [],
        turnNumber: 1,
      );
      await repo.insertFtsIndex(
        memoryId: mem1.memoryId,
        summary: '勇者古碑探索',
        sessionId: 's1',
      );

      // s2 的记忆（同名但不同 session）
      final mem2 = await repo.appendExperience(
        sessionId: 's2',
        summary: '勇者古碑探索',
        importance: 3,
        tags: [],
        turnNumber: 1,
      );
      await repo.insertFtsIndex(
        memoryId: mem2.memoryId,
        summary: '勇者古碑探索',
        sessionId: 's2',
      );

      final results = await searchMulti(
        sessionId: 's1',
        fts5Queries: ['勇者古碑', '', ''],
        vectorQueries: const [],
      );

      expect(results.length, 1);
      expect(results.first.memory.sessionId, 's1');
    });
  });
}
