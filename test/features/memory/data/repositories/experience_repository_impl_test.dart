import 'dart:typed_data';

// ignore_for_file: avoid_redundant_argument_values
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/exceptions/app_exceptions.dart';
import 'package:lmstory/core/vector/vector_engine.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/memory/data/repositories/experience_repository_impl.dart';
import 'package:lmstory/features/memory/domain/entities/experiential_memory.dart';
import 'package:lmstory/features/memory/domain/entities/scored_memory.dart';

/// ExperienceRepositoryImpl 单元测试
///
/// 使用内存 drift 数据库（NativeDatabase.memory），验证：
/// - FTS5 单路 / Vector 单路 / 两路合并检索
/// - append + getRecent 往返
/// - updateEmbedding + insertFtsIndex 增量同步
/// - deleteAllExperiences 会话级清理
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
  const topK = 5;
  const fts5Weight = 0.5;
  const vectorWeight = 0.5;
  const keyEventThreshold = 4;
  const keyEventBoost = 1.5;
  const epsilon = 0.01;

  Future<List<ScoredMemory>> search({
    required String sessionId,
    required String query,
    Float32List? queryVector,
  }) async {
    return repo.searchExperiences(
      sessionId: sessionId,
      query: query,
      queryVector: queryVector,
      topK: topK,
      fts5Weight: fts5Weight,
      vectorWeight: vectorWeight,
      keyEventThreshold: keyEventThreshold,
      keyEventBoost: keyEventBoost,
      normalizationEpsilon: epsilon,
    );
  }

  group('searchExperiences', () {
    test('1. FTS5 单路检索（queryVector=null）', () async {
      final mem = await repo.appendExperience(
        sessionId: 's1',
        summary: '勇者击败了恶龙',
        importance: 3,
        tags: ['战斗'],
        turnNumber: 1,
      );
      await repo.insertFtsIndex(
        memoryId: mem.memoryId,
        summary: '勇者击败了恶龙',
        sessionId: 's1',
      );

      final results = await search(
        sessionId: 's1',
        query: '勇者击败',
      );

      expect(results.length, 1);
      expect(results.first.memory.memoryId, mem.memoryId);
      expect(results.first.fts5Score, greaterThan(0));
      expect(results.first.vectorScore, 0);
    });

    test('2. Vector 单路检索（FTS5 无索引，Vector 命中）', () async {
      final queryVec = Float32List.fromList([1, 0, 0, 0]);
      final mem = await repo.appendExperience(
        sessionId: 's1',
        summary: '完全不相关摘要',
        importance: 3,
        tags: [],
        turnNumber: 1,
      );
      await repo.updateEmbedding(
        mem.memoryId,
        Float32List.fromList([1, 0, 0, 0]),
      );
      // 未插入 FTS 索引 -> FTS5 通道空

      final results = await search(
        sessionId: 's1',
        query: '关键词不存在',
        queryVector: queryVec,
      );

      expect(results.length, 1);
      expect(results.first.memory.memoryId, mem.memoryId);
      expect(results.first.vectorScore, greaterThan(0));
      expect(results.first.fts5Score, 0);
    });

    test('3. 两路合并 + 关键事件加权（importance>=4 -> ×1.5）', () async {
      final queryVec = Float32List.fromList([1, 0, 0, 0]);
      final mem = await repo.appendExperience(
        sessionId: 's1',
        summary: '勇者击败恶龙',
        importance: 5, // 关键事件
        tags: ['战斗'],
        turnNumber: 1,
      );
      await repo.insertFtsIndex(
        memoryId: mem.memoryId,
        summary: '勇者击败恶龙',
        sessionId: 's1',
      );
      await repo.updateEmbedding(
        mem.memoryId,
        Float32List.fromList([1, 0, 0, 0]),
      );

      final results = await search(
        sessionId: 's1',
        query: '勇者击败',
        queryVector: queryVec,
      );

      expect(results.length, 1);
      final r = results.first;
      // FTS5 单条结果：rank 相同 -> 归一化 1.0 × (1-ε) + ε = 1.0
      expect(r.fts5Score, closeTo(1.0, 1e-6));
      // Vector cosine=1.0 -> (1+1)/2 = 1.0
      expect(r.vectorScore, closeTo(1.0, 1e-6));
      // finalScore = (1.0×0.5 + 1.0×0.5) × 1.5 = 1.5
      expect(r.finalScore, closeTo(1.5, 1e-6));
    });

    test('4. 空结果（无数据）', () async {
      final results = await search(
        sessionId: 's1',
        query: '什么都没有',
      );
      expect(results, isEmpty);
    });

    test('会话隔离：只检索当前 session', () async {
      final mem1 = await repo.appendExperience(
        sessionId: 's1',
        summary: '勇者击败恶龙',
        importance: 3,
        tags: [],
        turnNumber: 1,
      );
      await repo.insertFtsIndex(
        memoryId: mem1.memoryId,
        summary: '勇者击败恶龙',
        sessionId: 's1',
      );
      // s2 有数据但不应被 s1 检索到
      final mem2 = await repo.appendExperience(
        sessionId: 's2',
        summary: '勇者击败恶龙',
        importance: 3,
        tags: [],
        turnNumber: 1,
      );
      await repo.insertFtsIndex(
        memoryId: mem2.memoryId,
        summary: '勇者击败恶龙',
        sessionId: 's2',
      );

      final s1Results = await search(sessionId: 's1', query: '勇者击败');
      expect(s1Results.length, 1);
      expect(s1Results.first.memory.sessionId, 's1');
    });
  });

  group('append + getRecent', () {
    test('5. append + getRecent 往返（按 turnNumber 降序）', () async {
      for (var i = 1; i <= 3; i++) {
        await repo.appendExperience(
          sessionId: 's1',
          summary: '事件$i',
          importance: 3,
          tags: ['tag$i'],
          turnNumber: i,
        );
      }

      final recent = await repo.getRecentExperiences('s1', limit: 10);
      expect(recent.length, 3);
      expect(recent[0].turnNumber, 3);
      expect(recent[1].turnNumber, 2);
      expect(recent[2].turnNumber, 1);
      expect(recent[0].tags, ['tag3']);
      expect(recent[0].hasEmbedding, false);
    });

    test('getRecent limit 截断', () async {
      for (var i = 1; i <= 5; i++) {
        await repo.appendExperience(
          sessionId: 's1',
          summary: '事件$i',
          importance: 3,
          tags: [],
          turnNumber: i,
        );
      }
      final recent = await repo.getRecentExperiences('s1', limit: 2);
      expect(recent.length, 2);
      expect(recent[0].turnNumber, 5);
      expect(recent[1].turnNumber, 4);
    });
  });

  group('embedding + FTS index', () {
    test('6. updateEmbedding 后 Vector 检索命中', () async {
      final mem = await repo.appendExperience(
        sessionId: 's1',
        summary: '测试摘要',
        importance: 3,
        tags: [],
        turnNumber: 1,
      );

      // 无 embedding 时 Vector 通道不命中
      var results = await search(
        sessionId: 's1',
        query: '其他关键词',
        queryVector: Float32List.fromList([1, 0, 0, 0]),
      );
      expect(results, isEmpty);

      // 更新 embedding 后命中
      await repo.updateEmbedding(
        mem.memoryId,
        Float32List.fromList([1, 0, 0, 0]),
      );
      results = await search(
        sessionId: 's1',
        query: '其他关键词',
        queryVector: Float32List.fromList([1, 0, 0, 0]),
      );
      expect(results.length, 1);
      expect(results.first.memory.hasEmbedding, true);
    });

    test('7. insertFtsIndex 手动补索引后 FTS5 命中（indexForRetrieval=false 形态）',
        () async {
      final mem = await repo.appendExperience(
        sessionId: 's1',
        summary: '神秘事件',
        importance: 3,
        tags: [],
        turnNumber: 1,
        // 单一写入口默认建索引；显式关闭以验证"手动补索引"路径
        indexForRetrieval: false,
      );

      // 无 FTS 索引时不命中
      var results = await search(
        sessionId: 's1',
        query: '神秘事件',
      );
      expect(results, isEmpty);

      await repo.insertFtsIndex(
        memoryId: mem.memoryId,
        summary: '神秘事件',
        sessionId: 's1',
      );
      results = await search(
        sessionId: 's1',
        query: '神秘事件',
      );
      expect(results.length, 1);
      expect(results.first.memory.memoryId, mem.memoryId);
    });

    test('updateEmbedding 不存在的 memoryId 抛 ModelNotFoundException', () async {
      expect(
        () => repo.updateEmbedding(
          'non-existent',
          Float32List.fromList([1, 0, 0, 0]),
        ),
        throwsA(isA<ModelNotFoundException>()),
      );
    });
  });

  group('deleteAllExperiences', () {
    test('8. 会话级清理（仅清当前 session，FTS 索引同步清理）', () async {
      final mem1 = await repo.appendExperience(
        sessionId: 's1',
        summary: '事件甲乙',
        importance: 3,
        tags: [],
        turnNumber: 1,
      );
      await repo.insertFtsIndex(
        memoryId: mem1.memoryId,
        summary: '事件甲乙',
        sessionId: 's1',
      );
      final mem2 = await repo.appendExperience(
        sessionId: 's2',
        summary: '事件丙丁',
        importance: 3,
        tags: [],
        turnNumber: 1,
      );
      await repo.insertFtsIndex(
        memoryId: mem2.memoryId,
        summary: '事件丙丁',
        sessionId: 's2',
      );

      await repo.deleteAllExperiences('s1');

      // s1 数据 + FTS 索引均清空
      final s1Recent = await repo.getRecentExperiences('s1', limit: 10);
      expect(s1Recent, isEmpty);
      final s1Fts = await search(sessionId: 's1', query: '事件甲乙');
      expect(s1Fts, isEmpty);

      // s2 不受影响
      final s2Recent = await repo.getRecentExperiences('s2', limit: 10);
      expect(s2Recent.length, 1);
      final s2Fts = await search(sessionId: 's2', query: '事件丙丁');
      expect(s2Fts.length, 1);
    });
  });

  group('deleteExperienceByTurns', () {
    test('9. 仅删 turn_number >= fromTurnNumber 的记忆 + FTS 索引', () async {
      // 准备 s1 三轮记忆
      final mem1 = await repo.appendExperience(
        sessionId: 's1',
        summary: '第一轮甲乙',
        importance: 3,
        tags: [],
        turnNumber: 1,
      );
      await repo.insertFtsIndex(
        memoryId: mem1.memoryId,
        summary: '第一轮甲乙',
        sessionId: 's1',
      );
      final mem2 = await repo.appendExperience(
        sessionId: 's1',
        summary: '第二轮丙丁',
        importance: 3,
        tags: [],
        turnNumber: 2,
      );
      await repo.insertFtsIndex(
        memoryId: mem2.memoryId,
        summary: '第二轮丙丁',
        sessionId: 's1',
      );
      final mem3 = await repo.appendExperience(
        sessionId: 's1',
        summary: '第三轮戊己',
        importance: 3,
        tags: [],
        turnNumber: 3,
      );
      await repo.insertFtsIndex(
        memoryId: mem3.memoryId,
        summary: '第三轮戊己',
        sessionId: 's1',
      );

      // 从第 2 轮开始删（含第 2、3 轮）
      await repo.deleteExperienceByTurns(
        sessionId: 's1',
        fromTurnNumber: 2,
      );

      // 第 1 轮保留
      final recent = await repo.getRecentExperiences('s1', limit: 10);
      expect(recent.length, 1);
      expect(recent.first.turnNumber, 1);
      expect(recent.first.summary, '第一轮甲乙');

      // 第 2、3 轮的 FTS 索引也清除（搜不到）
      final fts2 = await search(sessionId: 's1', query: '第二轮丙丁');
      expect(fts2, isEmpty);
      final fts3 = await search(sessionId: 's1', query: '第三轮戊己');
      expect(fts3, isEmpty);
      // 第 1 轮 FTS 仍可搜到
      final fts1 = await search(sessionId: 's1', query: '第一轮甲乙');
      expect(fts1.length, 1);
    });

    test('10. fromTurnNumber 超过最大轮次时无操作', () async {
      final mem = await repo.appendExperience(
        sessionId: 's1',
        summary: '事件甲乙',
        importance: 3,
        tags: [],
        turnNumber: 1,
      );
      await repo.insertFtsIndex(
        memoryId: mem.memoryId,
        summary: '事件甲乙',
        sessionId: 's1',
      );

      await repo.deleteExperienceByTurns(
        sessionId: 's1',
        fromTurnNumber: 99,
      );

      // 数据不变
      final recent = await repo.getRecentExperiences('s1', limit: 10);
      expect(recent.length, 1);
      final fts = await search(sessionId: 's1', query: '事件甲乙');
      expect(fts.length, 1);
    });

    test('11. 不影响其他 session 的记忆', () async {
      await repo.appendExperience(
        sessionId: 's1',
        summary: 's1第二轮甲乙',
        importance: 3,
        tags: [],
        turnNumber: 2,
      );
      // s1 第 2 轮未建 FTS（简化测试，只验数据层隔离）
      final s2Mem = await repo.appendExperience(
        sessionId: 's2',
        summary: 's2第二轮丙丁',
        importance: 3,
        tags: [],
        turnNumber: 2,
      );
      await repo.insertFtsIndex(
        memoryId: s2Mem.memoryId,
        summary: 's2第二轮丙丁',
        sessionId: 's2',
      );

      await repo.deleteExperienceByTurns(
        sessionId: 's1',
        fromTurnNumber: 2,
      );

      // s1 第 2 轮被删
      final s1Recent = await repo.getRecentExperiences('s1', limit: 10);
      expect(s1Recent, isEmpty);
      // s2 第 2 轮不受影响
      final s2Recent = await repo.getRecentExperiences('s2', limit: 10);
      expect(s2Recent.length, 1);
      expect(s2Recent.first.turnNumber, 2);
    });

    test('12. 可嵌套在外层事务内（与 persistRound 同模式）', () async {
      // 验证 deleteExperienceByTurns 不开自身事务，可嵌套
      final mem = await repo.appendExperience(
        sessionId: 's1',
        summary: '事件甲乙',
        importance: 3,
        tags: [],
        turnNumber: 1,
      );
      await repo.insertFtsIndex(
        memoryId: mem.memoryId,
        summary: '事件甲乙',
        sessionId: 's1',
      );

      // 在外层事务内调用
      await db.transaction(() async {
        await repo.deleteExperienceByTurns(
          sessionId: 's1',
          fromTurnNumber: 1,
        );
      });

      // 删除生效
      final recent = await repo.getRecentExperiences('s1', limit: 10);
      expect(recent, isEmpty);
    });

    // 手动记忆不随重生成/删除本轮的
    // turn 窗清理消失——记忆库手动新增的行 source='manual'，即使 turn 号
    // 落在删除窗内也不是该轮产物。
    test('13. manual 来源记忆不被 turn 窗删除，auto 行照删', () async {
      final autoMem = await repo.appendExperience(
        sessionId: 's1',
        summary: '第三轮管线摘要甲乙',
        importance: 3,
        tags: [],
        turnNumber: 3,
      );
      final manualMem = await repo.appendExperience(
        sessionId: 's1',
        summary: '用户手写补充丙丁',
        importance: 5,
        tags: [],
        turnNumber: 3, // 记忆库新增默认取 max+1，恰好落在重生成窗口内
        source: 'manual',
      );
      expect(autoMem.source, 'auto');
      expect(manualMem.source, 'manual');

      await repo.deleteExperienceByTurns(
        sessionId: 's1',
        fromTurnNumber: 3,
      );

      final recent = await repo.getRecentExperiences('s1', limit: 10);
      expect(recent, hasLength(1));
      expect(
        recent.single.memoryId,
        manualMem.memoryId,
        reason: '手动记忆必须幸存；轮管线产物照删',
      );
      // 手动记忆的 FTS 索引一并幸存（仍可全文检索）
      final hits = await search(sessionId: 's1', query: '手写补充');
      expect(hits, hasLength(1));
      expect(hits.single.memory.memoryId, manualMem.memoryId);
    });

    test('14. deleteExperienceById 带 sessionId 谓词不误删他库同 id', () async {
      final mem = await repo.appendExperience(
        sessionId: 's1',
        summary: '会话一记忆甲乙',
        importance: 3,
        tags: [],
        turnNumber: 1,
      );

      // 以「别的会话」身份删同 memoryId → 谓词拦下，行仍在
      await repo.deleteExperienceById(mem.memoryId, sessionId: 's-other');
      var recent = await repo.getRecentExperiences('s1', limit: 10);
      expect(recent, hasLength(1));

      // 以所属会话身份删 → 生效
      await repo.deleteExperienceById(mem.memoryId, sessionId: 's1');
      recent = await repo.getRecentExperiences('s1', limit: 10);
      expect(recent, isEmpty);
    });
  });

  // ── V1 维度过滤防护 ────────────────────────────────────────────────
  // 切换 embedding 模型后旧向量维度可能与 queryVector 不一致，
  // _vectorSearch 按 vec.length != queryVector.length 跳过候选（非破坏性）。
  group('vectorSearch 维度过滤 (V1)', () {
    test('13. 混合维度候选：queryVector 只命中相同维度的 embedding', () async {
      // mem384：384 维 embedding
      final mem384 = await repo.appendExperience(
        sessionId: 's1',
        summary: '维度甲乙记忆',
        importance: 3,
        tags: [],
        turnNumber: 1,
      );
      await repo.updateEmbedding(
        mem384.memoryId,
        Float32List.fromList(List.filled(384, 0.1)),
      );

      // mem768：768 维 embedding
      final mem768 = await repo.appendExperience(
        sessionId: 's1',
        summary: '维度丙丁记忆',
        importance: 3,
        tags: [],
        turnNumber: 2,
      );
      await repo.updateEmbedding(
        mem768.memoryId,
        Float32List.fromList(List.filled(768, 0.2)),
      );

      // 不插入 FTS 索引，让 Vector 通道独立验证（query 用不匹配的关键词）

      // 用 384 维 queryVector 检索 -> 只命中 mem384
      final results384 = await search(
        sessionId: 's1',
        query: '完全不匹配的关键词甲乙',
        queryVector: Float32List.fromList(List.filled(384, 0.1)),
      );
      expect(results384.length, 1);
      expect(results384.first.memory.memoryId, mem384.memoryId);
      expect(results384.first.vectorScore, greaterThan(0));

      // 用 768 维 queryVector 检索 -> 只命中 mem768
      final results768 = await search(
        sessionId: 's1',
        query: '完全不匹配的关键词甲乙',
        queryVector: Float32List.fromList(List.filled(768, 0.2)),
      );
      expect(results768.length, 1);
      expect(results768.first.memory.memoryId, mem768.memoryId);
      expect(results768.first.vectorScore, greaterThan(0));
    });

    test('14. 全部候选维度不匹配 -> Vector 通道空，仅 FTS5 命中（降级）', () async {
      final mem = await repo.appendExperience(
        sessionId: 's1',
        summary: '维度不匹配的记忆甲乙',
        importance: 3,
        tags: [],
        turnNumber: 1,
      );
      // 候选是 768 维
      await repo.updateEmbedding(
        mem.memoryId,
        Float32List.fromList(List.filled(768, 0.5)),
      );
      await repo.insertFtsIndex(
        memoryId: mem.memoryId,
        summary: '维度不匹配的记忆甲乙',
        sessionId: 's1',
      );

      // 用 384 维 queryVector 检索（与候选 768 维不匹配）
      final results = await search(
        sessionId: 's1',
        query: '维度不匹配',
        queryVector: Float32List.fromList(List.filled(384, 0.5)),
      );
      // Vector 通道被维度过滤清空，FTS5 命中
      expect(results.length, 1);
      expect(results.first.memory.memoryId, mem.memoryId);
      expect(results.first.fts5Score, greaterThan(0));
      expect(results.first.vectorScore, 0);
    });
  });

  // ──  检索优化 ──────────────────────────────────────────────────
  // 验证质量过滤 + recencyBoost + importance 加权三个新特性。
  group('searchExperiences B4-3 优化', () {
    test('15. 质量过滤：vec < threshold 且 fts5 == 0 -> 跳过', () async {
      // memLow：embedding 与 query 相反方向（cosine=-1 -> vectorScore=0）
      final memLow = await repo.appendExperience(
        sessionId: 's1',
        summary: '低相关记忆甲乙',
        importance: 3,
        tags: [],
        turnNumber: 1,
      );
      await repo.updateEmbedding(
        memLow.memoryId,
        Float32List.fromList([-1, 0, 0, 0]),
      );
      // 不插入 FTS 索引 -> fts5=0

      // memHigh：embedding 与 query 相同方向（cosine=1 -> vectorScore=1.0）
      final memHigh = await repo.appendExperience(
        sessionId: 's1',
        summary: '高相关记忆丙丁',
        importance: 3,
        tags: [],
        turnNumber: 2,
      );
      await repo.updateEmbedding(
        memHigh.memoryId,
        Float32List.fromList([1, 0, 0, 0]),
      );

      // 启用质量过滤：threshold=0.3
      final results = await repo.searchExperiences(
        sessionId: 's1',
        query: '完全不匹配的关键词戊己',
        queryVector: Float32List.fromList([1, 0, 0, 0]),
        topK: 5,
        fts5Weight: 0.5,
        vectorWeight: 0.5,
        keyEventThreshold: 4,
        keyEventBoost: 1.5,
        normalizationEpsilon: epsilon,
        vectorScoreThreshold: 0.3,
      );

      // memLow（vec=0 < 0.3，fts5=0）被过滤；memHigh（vec=1.0）保留
      expect(results.length, 1);
      expect(results.first.memory.memoryId, memHigh.memoryId);
    });

    test('16. recencyBoost：近期记忆排序靠前', () async {
      // 两条记忆 embedding 相同（vectorScore 相同），FTS5 都无索引
      // 仅靠 recencyBoost 区分排序
      final memOld = await repo.appendExperience(
        sessionId: 's1',
        summary: '远期记忆甲乙',
        importance: 3,
        tags: [],
        turnNumber: 1,
      );
      await repo.updateEmbedding(
        memOld.memoryId,
        Float32List.fromList([1, 0, 0, 0]),
      );

      final memRecent = await repo.appendExperience(
        sessionId: 's1',
        summary: '近期记忆丙丁',
        importance: 3,
        tags: [],
        turnNumber: 10,
      );
      await repo.updateEmbedding(
        memRecent.memoryId,
        Float32List.fromList([1, 0, 0, 0]),
      );

      // currentTurnNumber=11，recencyHalfLife=5
      // memOld: turnsAgo=10 -> boost=0.5^(10/5)=0.25
      // memRecent: turnsAgo=1 -> boost=0.5^(1/5)≈0.87
      final results = await repo.searchExperiences(
        sessionId: 's1',
        query: '完全不匹配的关键词戊己',
        queryVector: Float32List.fromList([1, 0, 0, 0]),
        topK: 5,
        fts5Weight: 0.5,
        vectorWeight: 0.5,
        keyEventThreshold: 4,
        keyEventBoost: 1.5,
        normalizationEpsilon: epsilon,
        recencyWeight: 0.5,
        recencyHalfLife: 5,
        currentTurnNumber: 11,
      );

      expect(results.length, 2);
      // 近期记忆应排在前面
      expect(results.first.memory.memoryId, memRecent.memoryId);
      expect(results.last.memory.memoryId, memOld.memoryId);
    });

    test('17. importance 加权：高重要性排序靠前', () async {
      // 两条记忆 embedding 相同，turnNumber 相同，仅 importance 不同
      final memLow = await repo.appendExperience(
        sessionId: 's1',
        summary: '低重要性记忆甲乙',
        importance: 1,
        tags: [],
        turnNumber: 1,
      );
      await repo.updateEmbedding(
        memLow.memoryId,
        Float32List.fromList([1, 0, 0, 0]),
      );

      final memHigh = await repo.appendExperience(
        sessionId: 's1',
        summary: '高重要性记忆丙丁',
        importance: 5,
        tags: [],
        turnNumber: 1,
      );
      await repo.updateEmbedding(
        memHigh.memoryId,
        Float32List.fromList([1, 0, 0, 0]),
      );

      // 启用 importanceWeight=0.5（不启用 recency 避免干扰）
      // memLow: +1/5*0.5=0.1
      // memHigh: +5/5*0.5=0.5
      final results = await repo.searchExperiences(
        sessionId: 's1',
        query: '完全不匹配的关键词戊己',
        queryVector: Float32List.fromList([1, 0, 0, 0]),
        topK: 5,
        fts5Weight: 0.5,
        vectorWeight: 0.5,
        keyEventThreshold: 4,
        keyEventBoost: 1.5,
        normalizationEpsilon: epsilon,
        importanceWeight: 0.5,
      );

      expect(results.length, 2);
      expect(results.first.memory.memoryId, memHigh.memoryId);
      expect(results.last.memory.memoryId, memLow.memoryId);
    });

    test('18. 默认参数（0/null）不启用 B4-3 优化，行为与旧逻辑一致', () async {
      // memLow：vec=0（相反方向），无 FTS 索引
      // 默认参数下不过滤（vectorScoreThreshold=0），memLow 仍返回
      final memLow = await repo.appendExperience(
        sessionId: 's1',
        summary: '低相关记忆甲乙',
        importance: 3,
        tags: [],
        turnNumber: 1,
      );
      await repo.updateEmbedding(
        memLow.memoryId,
        Float32List.fromList([-1, 0, 0, 0]),
      );

      // 不传任何  参数（使用默认值 0/null）
      final results = await search(
        sessionId: 's1',
        query: '完全不匹配的关键词丙丁',
        queryVector: Float32List.fromList([1, 0, 0, 0]),
      );

      // memLow 仍被返回（质量过滤未启用）
      expect(results.length, 1);
      expect(results.first.memory.memoryId, memLow.memoryId);
      expect(results.first.vectorScore, 0); // cosine=-1 -> (−1+1)/2=0
    });
  });

  group('getUnindexedExperiences', () {
    test('1. 未建 FTS 索引的记忆 -> 返回', () async {
      // indexForRetrieval=false（模拟 importance < threshold 的低重要性记忆）
      await repo.appendExperience(
        sessionId: 's1',
        summary: '低重要性记忆甲乙',
        importance: 2,
        tags: ['探索'],
        turnNumber: 1,
        indexForRetrieval: false,
      );
      await repo.appendExperience(
        sessionId: 's1',
        summary: '另一条低重要性记忆丙丁',
        importance: 1,
        tags: [],
        turnNumber: 2,
        indexForRetrieval: false,
      );

      final result = await repo.getUnindexedExperiences(
        's1',
        limit: 10,
      );

      expect(result, hasLength(2));
      // 按 turn_number 升序
      expect(result[0].turnNumber, 1);
      expect(result[1].turnNumber, 2);
    });

    test('2. 已建 FTS 索引的记忆 -> 不返回', () async {
      await repo.appendExperience(
        sessionId: 's1',
        summary: '高重要性记忆甲乙',
        importance: 4,
        tags: [],
        turnNumber: 1,
      );

      final result = await repo.getUnindexedExperiences(
        's1',
        limit: 10,
      );

      expect(result, isEmpty);
    });

    test('3. 混合场景：仅返回未建索引的部分', () async {
      // 记忆 A：建索引（单一写入口默认）
      await repo.appendExperience(
        sessionId: 's1',
        summary: '高重要性记忆甲乙',
        importance: 4,
        tags: [],
        turnNumber: 1,
      );
      // 记忆 B：不建索引
      await repo.appendExperience(
        sessionId: 's1',
        summary: '低重要性记忆丙丁',
        importance: 2,
        tags: [],
        turnNumber: 2,
        indexForRetrieval: false,
      );
      // 记忆 C：不建索引
      await repo.appendExperience(
        sessionId: 's1',
        summary: '另一条低重要性记忆戊己',
        importance: 1,
        tags: [],
        turnNumber: 3,
        indexForRetrieval: false,
      );

      final result = await repo.getUnindexedExperiences(
        's1',
        limit: 10,
      );

      expect(result, hasLength(2));
      expect(result[0].turnNumber, 2);
      expect(result[1].turnNumber, 3);
    });

    test('4. limit 参数限制返回数量', () async {
      for (var i = 1; i <= 5; i++) {
        await repo.appendExperience(
          sessionId: 's1',
          summary: '低重要性记忆序号$i',
          importance: 1,
          tags: [],
          turnNumber: i,
          indexForRetrieval: false,
        );
      }

      final result = await repo.getUnindexedExperiences(
        's1',
        limit: 3,
      );

      expect(result, hasLength(3));
      // 取 turn_number 升序的前 3 条
      expect(result[0].turnNumber, 1);
      expect(result[1].turnNumber, 2);
      expect(result[2].turnNumber, 3);
    });

    test('5. 跨会话隔离：仅返回指定 sessionId 的记忆', () async {
      await repo.appendExperience(
        sessionId: 's1',
        summary: '会话1低重要性记忆',
        importance: 1,
        tags: [],
        turnNumber: 1,
        indexForRetrieval: false,
      );
      await repo.appendExperience(
        sessionId: 's2',
        summary: '会话2低重要性记忆',
        importance: 1,
        tags: [],
        turnNumber: 1,
        indexForRetrieval: false,
      );

      final result = await repo.getUnindexedExperiences(
        's1',
        limit: 10,
      );

      expect(result, hasLength(1));
      expect(result[0].sessionId, 's1');
    });
  });

  group('deleteExperiencesByIds', () {
    test('1. 按 memoryId 列表批量删除', () async {
      final mem1 = await repo.appendExperience(
        sessionId: 's1',
        summary: '记忆一甲乙',
        importance: 2,
        tags: [],
        turnNumber: 1,
      );
      final mem2 = await repo.appendExperience(
        sessionId: 's1',
        summary: '记忆二甲乙',
        importance: 2,
        tags: [],
        turnNumber: 2,
      );
      // mem3 不删
      await repo.appendExperience(
        sessionId: 's1',
        summary: '记忆三甲乙',
        importance: 2,
        tags: [],
        turnNumber: 3,
      );

      await repo.deleteExperiencesByIds(
        sessionId: 's1',
        memoryIds: [mem1.memoryId, mem2.memoryId],
      );

      final remaining = await repo.getRecentExperiences('s1', limit: 10);
      expect(remaining, hasLength(1));
      expect(remaining[0].memoryId, isNot(mem1.memoryId));
      expect(remaining[0].memoryId, isNot(mem2.memoryId));
    });

    test('2. 空 memoryIds 列表 -> 无操作', () async {
      await repo.appendExperience(
        sessionId: 's1',
        summary: '记忆甲乙',
        importance: 2,
        tags: [],
        turnNumber: 1,
      );

      await repo.deleteExperiencesByIds(
        sessionId: 's1',
        memoryIds: const [],
      );

      final remaining = await repo.getRecentExperiences('s1', limit: 10);
      expect(remaining, hasLength(1));
    });

    test('3. 同步删除 FTS5 索引行', () async {
      final mem = await repo.appendExperience(
        sessionId: 's1',
        summary: '已索引记忆甲乙',
        importance: 3,
        tags: [],
        turnNumber: 1,
      );
      await repo.insertFtsIndex(
        memoryId: mem.memoryId,
        summary: '已索引记忆甲乙',
        sessionId: 's1',
      );

      // 删除前可检索到
      final before = await repo.searchExperiences(
        sessionId: 's1',
        query: '已索引记忆甲乙',
        queryVector: null,
        topK: 5,
        fts5Weight: 0.5,
        vectorWeight: 0.5,
        keyEventThreshold: 4,
        keyEventBoost: 1.5,
        normalizationEpsilon: 0.01,
      );
      expect(before, hasLength(1));

      await repo.deleteExperiencesByIds(
        sessionId: 's1',
        memoryIds: [mem.memoryId],
      );

      // 删除后检索不到（FTS5 索引也同步删除）
      final after = await repo.searchExperiences(
        sessionId: 's1',
        query: '已索引记忆甲乙',
        queryVector: null,
        topK: 5,
        fts5Weight: 0.5,
        vectorWeight: 0.5,
        keyEventThreshold: 4,
        keyEventBoost: 1.5,
        normalizationEpsilon: 0.01,
      );
      expect(after, isEmpty);
    });

    test('4. 跨会话隔离：不影响其他会话的同 memoryId（理论应唯一）', () async {
      // memoryId 是 UUID，跨会话不会重复；此用例验证 sessionId 过滤生效
      final memS1 = await repo.appendExperience(
        sessionId: 's1',
        summary: '会话1记忆甲乙',
        importance: 2,
        tags: [],
        turnNumber: 1,
      );
      await repo.appendExperience(
        sessionId: 's2',
        summary: '会话2记忆甲乙',
        importance: 2,
        tags: [],
        turnNumber: 1,
      );

      // 删除 s1 的记忆，s2 不受影响
      await repo.deleteExperiencesByIds(
        sessionId: 's1',
        memoryIds: [memS1.memoryId],
      );

      final remainingS1 = await repo.getRecentExperiences('s1', limit: 10);
      final remainingS2 = await repo.getRecentExperiences('s2', limit: 10);
      expect(remainingS1, isEmpty);
      expect(remainingS2, hasLength(1));
    });
  });

  // ── DOC-10 §3 多粒度记忆数据层接口 ──────────────────────────────
  // 验证 appendMacroExperience / getLastMacroTurnNumber / getMicroSummariesInRange
  group('多粒度记忆数据层接口 (DOC-10 §3)', () {
    test('5. appendMacroExperience：写入 macro 记忆，字段完整', () async {
      final memory = await repo.appendMacroExperience(
        sessionId: 's1',
        summary: '宏摘要正文',
        importance: 4,
        tags: ['战斗', '龙巢'],
        turnNumber: 5,
        parentEventIds: const ['micro1', 'micro2', 'micro3'],
        triggerReason: MacroTriggerReason.eventEnd,
      );

      expect(memory.memoryId, isNotEmpty);
      expect(memory.memoryLevel, MemoryLevel.macro);
      expect(memory.isMacro, isTrue);
      expect(memory.summary, '宏摘要正文');
      expect(memory.importance, 4);
      expect(memory.tags, ['战斗', '龙巢']);
      expect(memory.turnNumber, 5);
      expect(memory.parentEventIds, ['micro1', 'micro2', 'micro3']);
      expect(memory.macroTriggerReason, MacroTriggerReason.eventEnd);

      // getRecentExperiences 能读到
      final recent = await repo.getRecentExperiences('s1', limit: 10);
      expect(recent.length, 1);
      expect(recent.first.memoryId, memory.memoryId);
      expect(recent.first.isMacro, isTrue);
    });

    test('6. getLastMacroTurnNumber：返回最近 macro 的 turnNumber', () async {
      // 无 macro 时返回 null
      expect(await repo.getLastMacroTurnNumber('s1'), isNull);

      // 写入 micro 不影响
      await repo.appendExperience(
        sessionId: 's1',
        summary: '微摘要',
        importance: 3,
        tags: [],
        turnNumber: 1,
      );
      expect(await repo.getLastMacroTurnNumber('s1'), isNull);

      // 写入 macro turn=3
      await repo.appendMacroExperience(
        sessionId: 's1',
        summary: '宏1',
        importance: 4,
        tags: [],
        turnNumber: 3,
        parentEventIds: const ['m1'],
        triggerReason: MacroTriggerReason.eventEnd,
      );
      expect(await repo.getLastMacroTurnNumber('s1'), 3);

      // 写入更晚的 macro turn=7
      await repo.appendMacroExperience(
        sessionId: 's1',
        summary: '宏2',
        importance: 5,
        tags: [],
        turnNumber: 7,
        parentEventIds: const ['m2'],
        triggerReason: MacroTriggerReason.roundLimit,
      );
      expect(await repo.getLastMacroTurnNumber('s1'), 7);
    });

    test('7. getLastMacroTurnNumber 会话隔离', () async {
      await repo.appendMacroExperience(
        sessionId: 's1',
        summary: 's1 宏',
        importance: 4,
        tags: [],
        turnNumber: 5,
        parentEventIds: const ['m1'],
        triggerReason: MacroTriggerReason.eventEnd,
      );
      await repo.appendMacroExperience(
        sessionId: 's2',
        summary: 's2 宏',
        importance: 4,
        tags: [],
        turnNumber: 8,
        parentEventIds: const ['m2'],
        triggerReason: MacroTriggerReason.eventEnd,
      );

      expect(await repo.getLastMacroTurnNumber('s1'), 5);
      expect(await repo.getLastMacroTurnNumber('s2'), 8);
    });

    test('8. getMicroSummariesInRange：返回 [fromTurn, toTurn] 区间内 micro',
        () async {
      // 写入 5 条 micro：turn 1-5
      for (var i = 1; i <= 5; i++) {
        await repo.appendExperience(
          sessionId: 's1',
          summary: '微摘要 $i',
          importance: 3,
          tags: [],
          turnNumber: i,
        );
      }
      // 写入 1 条 macro turn=3（不应被返回）
      await repo.appendMacroExperience(
        sessionId: 's1',
        summary: '宏摘要',
        importance: 4,
        tags: [],
        turnNumber: 3,
        parentEventIds: const ['m1'],
        triggerReason: MacroTriggerReason.eventEnd,
      );

      final result = await repo.getMicroSummariesInRange(
        sessionId: 's1',
        fromTurn: 2,
        toTurn: 4,
      );

      expect(result.length, 3);
      // 按 turnNumber 升序
      expect(result[0].turnNumber, 2);
      expect(result[1].turnNumber, 3);
      expect(result[2].turnNumber, 4);
      // 全部是 micro
      expect(result.every((m) => m.memoryLevel == MemoryLevel.micro), isTrue);
    });

    test('9. getMicroSummariesInRange 不返回已归档记忆', () async {
      // 注：appendExperience 默认 isArchived=false，无归档 API（v0.3 启用）
      // 这里测试的是"不返回归档"的 where 子句不误杀正常记忆
      await repo.appendExperience(
        sessionId: 's1',
        summary: '微摘要甲乙',
        importance: 3,
        tags: [],
        turnNumber: 1,
      );

      final result = await repo.getMicroSummariesInRange(
        sessionId: 's1',
        fromTurn: 1,
        toTurn: 5,
      );

      expect(result.length, 1);
      expect(result.first.turnNumber, 1);
    });

    test('10. getMicroSummariesInRange 会话隔离', () async {
      await repo.appendExperience(
        sessionId: 's1',
        summary: 's1 微',
        importance: 3,
        tags: [],
        turnNumber: 1,
      );
      await repo.appendExperience(
        sessionId: 's2',
        summary: 's2 微',
        importance: 3,
        tags: [],
        turnNumber: 1,
      );

      final s1Result = await repo.getMicroSummariesInRange(
        sessionId: 's1',
        fromTurn: 1,
        toTurn: 5,
      );
      expect(s1Result.length, 1);
      expect(s1Result.first.sessionId, 's1');

      final s2Result = await repo.getMicroSummariesInRange(
        sessionId: 's2',
        fromTurn: 1,
        toTurn: 5,
      );
      expect(s2Result.length, 1);
      expect(s2Result.first.sessionId, 's2');
    });
  });
}
