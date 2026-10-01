import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:drift/drift.dart';
import 'package:lmstory/core/exceptions/app_exceptions.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/core/vector/vector_engine.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/memory/domain/entities/experiential_memory.dart';
import 'package:lmstory/features/memory/domain/entities/scored_memory.dart';
import 'package:lmstory/features/memory/domain/repositories/experience_repository.dart';
import 'package:lmstory/features/memory/domain/services/memory_query.dart';
import 'package:lmstory/features/memory/domain/services/memory_retrieval_exception.dart';
import 'package:uuid/uuid.dart';

/// ExperienceRepository 实现（Data 层）
///
/// 使用 drift + VectorEngine 实现中级模式经历类记忆的存储与混合检索。
/// 算法依据 DOC-09A-1 §3（FTS5+Vector 两路检索 + 归一化 + 加权合并）。
///
/// 不依赖 EmbeddingService：关键词向量化由 Controller 负责（网络调用不属
/// Repository 纯数据存取），本类只接收已生成的 queryVector 做检索计算。
class ExperienceRepositoryImpl implements ExperienceRepository {
  ExperienceRepositoryImpl({
    required AppDatabase database,
    required VectorEngine vectorEngine,
  })  : _database = database,
        _vectorEngine = vectorEngine;

  final AppDatabase _database;
  final VectorEngine _vectorEngine;
  final _uuid = const Uuid();
  final _logger = const Logger('ExperienceRepository');

  // ==================== 检索 ====================

  @override
  Future<List<ScoredMemory>> searchExperiences({
    required String sessionId,
    required String query,
    required Float32List? queryVector,
    required int topK,
    required double fts5Weight,
    required double vectorWeight,
    required int keyEventThreshold,
    required double keyEventBoost,
    required double normalizationEpsilon,
    double recencyWeight = 0.0,
    double importanceWeight = 0.0,
    int recencyHalfLife = 20,
    double vectorScoreThreshold = 0.0,
    int? currentTurnNumber,
  }) async {
    // 1. FTS5 通道
    final fts5Result = await _fts5Search(
      sessionId,
      query,
      topK * 2,
      normalizationEpsilon,
    );

    // 2. Vector 通道（仅当 queryVector != null）
    final vectorResult = queryVector == null
        ? (scores: const <String, double>{}, failed: false)
        : await _vectorSearch(sessionId, queryVector, topK * 2);

    // 3. 归并打分 + 排序取 topK
    final scored = await _computeScoredMemories(
      sessionId: sessionId,
      fts5Scores: fts5Result.scores,
      vectorScores: vectorResult.scores,
      fts5Weight: fts5Weight,
      vectorWeight: vectorWeight,
      keyEventThreshold: keyEventThreshold,
      keyEventBoost: keyEventBoost,
      recencyWeight: recencyWeight,
      importanceWeight: importanceWeight,
      recencyHalfLife: recencyHalfLife,
      vectorScoreThreshold: vectorScoreThreshold,
      currentTurnNumber: currentTurnNumber,
    );
    scored.sort((a, b) => b.finalScore.compareTo(a.finalScore));
    return scored.take(topK).toList();
  }

  @override
  Future<List<ScoredMemory>> searchExperiencesMultiChannel({
    required String sessionId,
    required List<String> fts5Queries,
    required List<({String query, Float32List? vector})> vectorQueries,
    required int topK,
    required double fts5Weight,
    required double vectorWeight,
    required int keyEventThreshold,
    required double keyEventBoost,
    required double normalizationEpsilon,
    double recencyWeight = 0.0,
    double importanceWeight = 0.0,
    int recencyHalfLife = 20,
    double vectorScoreThreshold = 0.0,
    int? currentTurnNumber,
  }) async {
    // 1. 过滤空 query（FTS5 空字符串 / Vector 空或 vector=null）
    final validFts5 = fts5Queries.where((q) => q.trim().isNotEmpty).toList();
    final validVector = vectorQueries
        .where((v) => v.query.trim().isNotEmpty && v.vector != null)
        .toList();

    // 2. 多路并行（Future.wait）：每路自带降级，单路失败不阻塞其他路
    final fts5Futures = validFts5
        .map((q) => _fts5Search(sessionId, q, topK * 2, normalizationEpsilon))
        .toList();
    final vectorFutures = validVector
        .map((v) => _vectorSearch(sessionId, v.vector!, topK * 2))
        .toList();
    final results = await Future.wait([
      ...fts5Futures,
      ...vectorFutures,
    ]);

    // 2.5 全通道失败 = 检索不可用，而不是"没有记忆"。
    // 2026-09-09 审查：此前一律吞成空 Map，模型看到的是"未命中"，会据此
    // 断定库里没有并重复建档。抛出类型化异常，由调用方呈现"检索不可用"。
    if (results.isNotEmpty && results.every((r) => r.failed)) {
      _logger.warn(
        'All retrieval channels failed',
        detail: 'session=$sessionId, channels=${results.length}',
      );
      throw MemoryRetrievalUnavailableException(
        sessionId: sessionId,
        attemptedChannels: results.length,
      );
    }

    // 3. 归并：同一 memoryId 在多路 FTS5 / 多路 Vector 中取最高分
    final mergedFts5 = <String, double>{};
    final mergedVector = <String, double>{};
    for (var i = 0; i < validFts5.length; i++) {
      for (final entry in results[i].scores.entries) {
        final existing = mergedFts5[entry.key] ?? 0.0;
        if (entry.value > existing) mergedFts5[entry.key] = entry.value;
      }
    }
    for (var i = 0; i < validVector.length; i++) {
      final idx = validFts5.length + i;
      for (final entry in results[idx].scores.entries) {
        final existing = mergedVector[entry.key] ?? 0.0;
        if (entry.value > existing) mergedVector[entry.key] = entry.value;
      }
    }

    // 4. 归并打分 + 排序取 topK（复用共享方法，公式与 searchExperiences 一致）
    final scored = await _computeScoredMemories(
      sessionId: sessionId,
      fts5Scores: mergedFts5,
      vectorScores: mergedVector,
      fts5Weight: fts5Weight,
      vectorWeight: vectorWeight,
      keyEventThreshold: keyEventThreshold,
      keyEventBoost: keyEventBoost,
      recencyWeight: recencyWeight,
      importanceWeight: importanceWeight,
      recencyHalfLife: recencyHalfLife,
      vectorScoreThreshold: vectorScoreThreshold,
      currentTurnNumber: currentTurnNumber,
    );
    scored.sort((a, b) => b.finalScore.compareTo(a.finalScore));
    return scored.take(topK).toList();
  }

  @override
  Future<List<ExperientialMemory>> searchExperiencesBySubstring(
    String sessionId,
    List<String> terms, {
    int limit = 5,
    bool includeArchived = false,
  }) async {
    final cleaned = <String>[];
    for (final term in terms) {
      final trimmed = term.trim();
      if (trimmed.isEmpty || cleaned.contains(trimmed)) continue;
      cleaned.add(trimmed);
    }
    if (cleaned.isEmpty) return const [];

    final query = _database.select(_database.experientialMemoriesTable)
      ..where((t) {
        var condition = t.sessionId.equals(sessionId);
        if (!includeArchived) {
          condition = condition & t.isArchived.equals(false);
        }
        Expression<bool>? anyTerm;
        for (final term in cleaned) {
          final pattern = Variable.withString(
            '%${MemoryQuery.escapeLike(term)}%',
          );
          Expression<bool> like(Expression<String> column) => column.likeExp(
                pattern,
                escape: const Constant<String>(r'\'),
              );
          final match = like(t.summary) |
              like(t.whenText) |
              like(t.whereText) |
              like(t.whoText) |
              like(t.whatText) |
              like(t.significance) |
              like(t.extra) |
              like(t.tags);
          anyTerm = anyTerm == null ? match : anyTerm | match;
        }
        return condition & anyTerm!;
      })
      ..orderBy([
        (t) => OrderingTerm(expression: t.turnNumber, mode: OrderingMode.desc),
      ])
      ..limit(limit);
    final rows = await query.get();
    return rows.map(_memoryFromTyped).toList();
  }

  /// 归并打分共享逻辑（searchExperiences / searchExperiencesMultiChannel 复用）
  ///
  /// 输入两路归一化分数（memoryId → score），批量加载完整记忆数据，
  /// 计算 finalScore（含关键事件加权 + recency + importance），
  /// 应用 [vectorScoreThreshold] 单路质量过滤。
  ///
  /// 返回未排序的 ScoredMemory 列表（调用方负责排序 + topK 截断）。
  Future<List<ScoredMemory>> _computeScoredMemories({
    required String sessionId,
    required Map<String, double> fts5Scores,
    required Map<String, double> vectorScores,
    required double fts5Weight,
    required double vectorWeight,
    required int keyEventThreshold,
    required double keyEventBoost,
    required double recencyWeight,
    required double importanceWeight,
    required int recencyHalfLife,
    required double vectorScoreThreshold,
    required int? currentTurnNumber,
  }) async {
    // 1. 合并 memoryId 集合
    final allMemoryIds = <String>{...fts5Scores.keys, ...vectorScores.keys};
    if (allMemoryIds.isEmpty) {
      // 返回可变空列表：调用方会调用 .sort()，const 列表不可排序。
      return <ScoredMemory>[];
    }

    // 2. 批量加载完整数据（过滤 is_archived）
    final rows = await (_database.select(_database.experientialMemoriesTable)
          ..where(
            (t) =>
                t.memoryId.isIn(allMemoryIds.toList()) &
                t.isArchived.equals(false),
          ))
        .get();
    final memories = <String, ExperientialMemory>{
      for (final row in rows) row.memoryId: _memoryFromTyped(row),
    };

    // 3. 计算 finalScore + 关键事件加权 +  时间衰减 + importance 加权
    final enableRecency = recencyWeight > 0 && currentTurnNumber != null;
    final enableImportance = importanceWeight > 0;
    final enableQualityFilter = vectorScoreThreshold > 0;
    final scored = <ScoredMemory>[];
    for (final memoryId in allMemoryIds) {
      final memory = memories[memoryId];
      if (memory == null) continue; // 已归档的被过滤
      final fts5 = fts5Scores[memoryId] ?? 0.0;
      final vec = vectorScores[memoryId] ?? 0.0;

      // 质量过滤 - 低相关性记忆直接跳过
      // 2026-08-06 修订：FTS5 经 epsilon 平滑后最小值为 0.01，原条件 fts5==0.0
      // 永远不满足。改为 fts5 < 0.02（低于此值视为偶然命中）。
      if (enableQualityFilter && vec < vectorScoreThreshold && fts5 < 0.02) {
        continue;
      }

      var finalScore = fts5 * fts5Weight + vec * vectorWeight;

      // 基础相关性门槛（2026-08-06 新增）
      // 防止高 importance 但低相关性的记忆被 importance/recency 加成推过阈值
      // 仅在质量过滤启用时生效（vectorScoreThreshold > 0 时），
      // 避免影响"默认参数返回所有结果"的旧行为。
      if (enableQualityFilter && finalScore < 0.1) {
        continue;
      }

      // 关键事件加权
      if (memory.importance >= keyEventThreshold) {
        finalScore *= keyEventBoost;
      }
      // 时间衰减加权（recent memories 优先）
      // recencyBoost = 0.5 ^ (turnsAgo / recencyHalfLife)，范围 (0, 1]
      // turnsAgo <= 0 时（当前轮或未来轮）取 1.0（最高优先）
      if (enableRecency) {
        final turnsAgo = currentTurnNumber - memory.turnNumber;
        final recencyBoost = turnsAgo <= 0
            ? 1.0
            : math.pow(0.5, turnsAgo / recencyHalfLife).toDouble();
        finalScore += recencyBoost * recencyWeight;
      }
      // importance 乘法加权（2026-08-06 修订：从加法改为乘法）
      // 乘法语义：importance 只能放大相关性，不能凭空创造相关性。
      // importance=3 → 1.0x（中性），importance=5 → 1.0+2*weight（提升），
      // importance=1 → 1.0-2*weight（降低）。
      // 原加法公式 (importance/5)*weight 在相关性为 0 时仍贡献固定加分，
      // 导致高 importance 低相关性记忆每轮都被注入。
      if (enableImportance) {
        final importanceMultiplier =
            1.0 + (memory.importance - 3) * importanceWeight;
        finalScore *= importanceMultiplier;
      }

      scored.add(
        ScoredMemory(
          memory: memory,
          fts5Score: fts5,
          vectorScore: vec,
          temporalScore: 0, // 中级模式无 temporal 通道
          finalScore: finalScore,
        ),
      );
    }
    return scored;
  }

  /// FTS5 通道检索 → memoryId → fts5Score（min-max 归一化 + ε 平滑）
  ///
  ///
  /// - 切词收口到 [MemoryQuery]——此前按 `[\s,，]+` 切分后**删除标点并
  ///   粘连**（`林墨(主角)` → `林墨主角`，MATCH 必空），`、。！？；` 不分词；
  /// - <3 rune 的中文短词（"老人""古碑"）在 trigram 下无法构成 token，
  ///   与事实层同构改走主表 LIKE 子串通道（经历层此前缺这条兜底，
  ///   双字人名恒不可召回）；
  /// - 返回 `(scores, failed)`：failed 用于区分"索引坏了"与"确实没有"，
  ///   由调用方决定是否把本轮判为「检索不可用」而不是「未命中」。
  Future<({Map<String, double> scores, bool failed})> _fts5Search(
    String sessionId,
    String query,
    int limit,
    double epsilon,
  ) async {
    final terms = MemoryQuery.tokenize(query);
    if (terms.isEmpty) return (scores: const <String, double>{}, failed: false);

    final scores = <String, double>{};
    var attempted = false;
    var succeeded = false;

    final longTerms = terms.where((t) => !MemoryQuery.isShortTerm(t)).toList();
    if (longTerms.isNotEmpty) {
      final expression = MemoryQuery.buildMatchExpression(longTerms);
      if (expression.isNotEmpty) {
        attempted = true;
        try {
          final rows = await _database.customSelect(
            'SELECT memory_id, rank FROM memories_fts '
            'WHERE memories_fts MATCH ? AND session_id = ? '
            'ORDER BY rank LIMIT ?',
            variables: [
              Variable.withString(expression),
              Variable.withString(sessionId),
              Variable.withInt(limit),
            ],
          ).get();
          succeeded = true;

          if (rows.isNotEmpty) {
            // rank 是 BM25 负值，越小（越负）越相关
            final ranks = rows.map((r) => r.read<double>('rank')).toList();
            final minRank = ranks.reduce((a, b) => a < b ? a : b);
            final maxRank = ranks.reduce((a, b) => a > b ? a : b);
            final range = minRank - maxRank;
            for (final row in rows) {
              final memoryId = row.read<String>('memory_id');
              final rank = row.read<double>('rank');
              final normalized =
                  range.abs() < 1e-10 ? 1.0 : (rank - maxRank) / range;
              // ε 平滑避免 0
              scores[memoryId] = normalized * (1 - epsilon) + epsilon;
            }
          }
        } catch (e) {
          _logger.warn(
            'FTS5 search failed',
            detail: 'session=$sessionId, query="$query", '
                'error=${e.runtimeType}: $e',
          );
        }
      }
    }

    final shortTerms = terms.where(MemoryQuery.isShortTerm).toList();
    if (shortTerms.isNotEmpty) {
      attempted = true;
      try {
        final hitIds = await _shortTermLikeSearch(
          sessionId,
          shortTerms,
          limit,
        );
        succeeded = true;
        for (final id in hitIds) {
          // 无 rank 可依：给中等分（与归一化后的 FTS 分同量级），
          // 去留交给调用方的权重与质量阈值
          const likeScore = 0.5;
          final existing = scores[id] ?? 0.0;
          if (likeScore > existing) scores[id] = likeScore;
        }
      } catch (e) {
        _logger.warn(
          'Short-term LIKE search failed',
          detail: 'session=$sessionId, terms=$shortTerms, '
              'error=${e.runtimeType}: $e',
        );
      }
    }

    return (scores: scores, failed: attempted && !succeeded);
  }

  /// 短词子串检索（<3 rune，trigram 无法召回）→ 命中 memoryId 集合
  ///
  /// 扫主表 7 个内容列 + tags，会话级、排除归档，按轮次倒序取前 limit。
  Future<Set<String>> _shortTermLikeSearch(
    String sessionId,
    List<String> terms,
    int limit,
  ) async {
    final conditions = <String>[];
    final variables = <Variable<Object>>[Variable.withString(sessionId)];
    for (final term in terms) {
      final pattern = Variable.withString('%${MemoryQuery.escapeLike(term)}%');
      conditions.add(
        r"(summary LIKE ? ESCAPE '\'"
        r" OR when_text LIKE ? ESCAPE '\'"
        r" OR where_text LIKE ? ESCAPE '\'"
        r" OR who_text LIKE ? ESCAPE '\'"
        r" OR what_text LIKE ? ESCAPE '\'"
        r" OR significance LIKE ? ESCAPE '\'"
        r" OR extra LIKE ? ESCAPE '\'"
        r" OR tags LIKE ? ESCAPE '\')",
      );
      for (var i = 0; i < 8; i++) {
        variables.add(pattern);
      }
    }
    final rows = await _database.customSelect(
      'SELECT memory_id FROM experiential_memories '
      'WHERE session_id = ? AND is_archived = 0 '
      'AND (${conditions.join(' OR ')}) '
      'ORDER BY turn_number DESC LIMIT ?',
      variables: [...variables, Variable.withInt(limit)],
    ).get();
    return rows.map((r) => r.read<String>('memory_id')).toSet();
  }

  /// Vector 通道检索 → memoryId → vectorScore（(cosine+1)/2 归一化）
  ///
  /// 查询异常时返回空 map（单路降级，DOC-09A-1 §3.7）。
  Future<({Map<String, double> scores, bool failed})> _vectorSearch(
    String sessionId,
    Float32List queryVector,
    int limit,
  ) async {
    try {
      // 加载本 session 全部候选向量
      final rows = await (_database.select(_database.experientialMemoriesTable)
            ..where(
              (t) =>
                  t.sessionId.equals(sessionId) &
                  t.hasEmbedding.equals(true) &
                  t.isArchived.equals(false),
            ))
          .get();

      if (rows.isEmpty) {
        return (scores: const <String, double>{}, failed: false);
      }

      final candidates = <Float32List>[];
      final memoryIds = <String>[];
      for (final row in rows) {
        final blob = row.embedding;
        if (blob == null) continue;
        final vec = _bytesToFloat32(blob);
        // V1 维度防护：切换 embedding 模型后旧向量维度可能与 queryVector 不一致，
        // 跳过维度不匹配的候选（非破坏性，切回原模型时旧向量仍可用）。
        // 偏离 DOC-08 §5.3「切换模型清空向量」的破坏性方案，详见计划 。
        if (vec.length != queryVector.length) continue;
        candidates.add(vec);
        memoryIds.add(row.memoryId);
      }

      if (candidates.isEmpty) {
        return (scores: const <String, double>{}, failed: false);
      }

      // batchSearch（candidateId 用索引，避免暴露 DB 自增 id 给 Core 层）
      final results = await _vectorEngine.batchSearch(
        queryVector: queryVector,
        candidates: candidates,
        candidateIds: [for (var i = 0; i < candidates.length; i++) i],
      );

      // 取 limit 条，归一化 (cosine+1)/2：[-1,1] → [0,1]
      final scores = <String, double>{};
      for (final r in results.take(limit)) {
        final memoryId = memoryIds[r.candidateId];
        scores[memoryId] = (r.cosineScore + 1) / 2;
      }
      return (scores: scores, failed: false);
    } catch (e) {
      // Vector 查询异常 → 单路降级（DOC-09A-1 §3.7）；failed 供调用方
      // 区分"向量通道坏了"与"没有向量命中"
      _logger.warn(
        'Vector search failed, returning empty',
        detail: 'session=$sessionId, error=${e.runtimeType}: $e',
      );
      return (scores: const <String, double>{}, failed: true);
    }
  }

  // ==================== 追加 ====================

  @override
  Future<ExperientialMemory> appendExperience({
    required String sessionId,
    required String? summary,
    required int importance,
    required List<String> tags,
    required int turnNumber,
    String? narrativeTime,
    String? narrativePeriod,
    String? when,
    String? where,
    String? who,
    String? what,
    String? significance,
    String? extra,
    bool indexForRetrieval = true,
    String source = 'auto',
  }) async {
    final memoryId = _uuid.v4();
    final now = DateTime.now();

    await _database.into(_database.experientialMemoriesTable).insert(
          ExperientialMemoriesTableCompanion.insert(
            memoryId: memoryId,
            sessionId: sessionId,
            summary: summary ?? '',
            turnNumber: turnNumber,
            importance: Value(importance),
            tags: Value(jsonEncode(tags)),
            narrativeTime: Value(narrativeTime),
            narrativePeriod: Value(narrativePeriod),
            whenText: Value(when),
            whereText: Value(where),
            whoText: Value(who),
            whatText: Value(what),
            significance: Value(significance),
            extra: Value(extra),
            createdAt: Value(now),
            memoryLevel: const Value('micro'),
            source: Value(source),
          ),
        );

    // 单一写入口（2026-09-09 审查）：索引与主表在同一事务内成对写入，
    // 调用方不再"记得"补 insertFtsIndex——记忆查看器手动新增即因此漏索引。
    if (indexForRetrieval) {
      await insertFtsIndex(
        memoryId: memoryId,
        sessionId: sessionId,
        summary: summary,
        when: when,
        where: where,
        who: who,
        what: what,
        significance: significance,
        extra: extra,
      );
    }

    return ExperientialMemory(
      memoryId: memoryId,
      sessionId: sessionId,
      summary: summary,
      importance: importance,
      tags: tags,
      turnNumber: turnNumber,
      when: when,
      where: where,
      who: who,
      what: what,
      significance: significance,
      extra: extra,
      narrativeTime: narrativeTime,
      narrativePeriod: narrativePeriod,
      createdAt: now,
      source: source,
    );
  }

  // ==================== 读取 ====================

  @override
  Future<List<ExperientialMemory>> getRecentExperiences(
    String sessionId, {
    required int limit,
    bool includeArchived = false,
  }) async {
    final query = _database.select(_database.experientialMemoriesTable)
      ..where((t) {
        var condition = t.sessionId.equals(sessionId);
        if (!includeArchived) {
          condition = condition & t.isArchived.equals(false);
        }
        return condition;
      })
      ..orderBy([
        (t) => OrderingTerm(expression: t.turnNumber, mode: OrderingMode.desc),
      ])
      ..limit(limit);
    final rows = await query.get();
    return rows.map(_memoryFromTyped).toList();
  }

  @override
  Future<List<ExperientialMemory>> getUnindexedExperiences(
    String sessionId, {
    required int limit,
  }) async {
    // 1. 查询本会话已建 FTS5 索引的 memory_id 集合
    //    memories_fts.memory_id 为 UNINDEXED 列，可直接 SELECT
    final ftsRows = await _database.customSelect(
      'SELECT memory_id FROM memories_fts WHERE session_id = ?',
      variables: [Variable.withString(sessionId)],
    ).get();
    final indexedIds = ftsRows.map((r) => r.read<String>('memory_id')).toSet();

    // 2. 查询未归档 + 未建索引的记忆，按 turn_number 升序（时间顺序）
    //    indexedIds 为空时 isNotIn 生成 `NOT IN ()` 在 SQLite 中非法，
    //    故空集时跳过该过滤条件（所有记忆均未索引）。
    final query = _database.select(_database.experientialMemoriesTable)
      ..where((t) {
        var condition =
            t.sessionId.equals(sessionId) & t.isArchived.equals(false);
        if (indexedIds.isNotEmpty) {
          condition = condition & t.memoryId.isNotIn(indexedIds.toList());
        }
        return condition;
      })
      ..orderBy([
        (t) => OrderingTerm(expression: t.turnNumber),
      ])
      ..limit(limit);
    final rows = await query.get();
    return rows.map(_memoryFromTyped).toList();
  }

  // ==================== 向量与索引同步 ====================

  @override
  Future<void> updateEmbedding(String memoryId, Float32List embedding) async {
    final affected =
        await (_database.update(_database.experientialMemoriesTable)
              ..where((t) => t.memoryId.equals(memoryId)))
            .write(
      ExperientialMemoriesTableCompanion(
        embedding: Value(_float32ToBytes(embedding)),
        hasEmbedding: const Value(true),
        // 维度随向量落库（LENGTH(blob)/4 语义），陈旧行才可统计
        embeddingDimensions: Value(embedding.length),
      ),
    );
    if (affected == 0) {
      throw ModelNotFoundException(memoryId);
    }
  }

  @override
  Future<void> insertFtsIndex({
    required String memoryId,
    required String? summary,
    required String sessionId,
    String? when,
    String? where,
    String? who,
    String? what,
    String? significance,
    String? extra,
  }) async {
    // v0.2 Phase C 方案二：FTS5 索引扩展到所有内容字段
    // memories_fts 表在 schemaVersion=21 重建后包含 7 个内容列：
    // summary / when_text / where_text / who_text / what_text / significance / extra
    // null 或空字符串字段插入空字符串（避免 NULL 影响 BM25 排序）
    await _database.customStatement(
      'INSERT INTO memories_fts '
      '(summary, when_text, where_text, who_text, what_text, significance, extra, '
      'memory_id, memory_type, session_id) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        summary ?? '',
        when ?? '',
        where ?? '',
        who ?? '',
        what ?? '',
        significance ?? '',
        extra ?? '',
        memoryId,
        'experiential',
        sessionId,
      ],
    );
  }

  // ==================== 清理 ====================

  @override
  Future<void> deleteAllExperiences(String sessionId) async {
    await _database.transaction(() async {
      await (_database.delete(_database.experientialMemoriesTable)
            ..where((t) => t.sessionId.equals(sessionId)))
          .go();
      await _database.customStatement(
        'DELETE FROM memories_fts WHERE session_id = ?',
        [sessionId],
      );
    });
  }

  @override
  Future<void> deleteExperienceByTurns({
    required String sessionId,
    required int fromTurnNumber,
  }) async {
    // 只删轮管线产物（source='auto'）。
    // 记忆库手动新增的行（source='manual'）turn 号虽落在窗口内，也不是
    // 本轮/下游轮的产物——重生成/删除本轮不得吞删用户手写记忆。
    // 存量行（v51 前无 source 列语义）由列 DEFAULT 归为 auto，行为不变。
    final autoRows =
        await (_database.select(_database.experientialMemoriesTable)
              ..where(
                (t) =>
                    t.sessionId.equals(sessionId) &
                    t.turnNumber.isBiggerOrEqualValue(fromTurnNumber) &
                    t.source.equals('auto'),
              ))
            .get();
    final memoryIds = autoRows.map((r) => r.memoryId).toList();

    if (memoryIds.isEmpty) return;

    // 2. 删 FTS5 索引（按 memory_id 批量）
    //    memory_ids 数量有限（每轮 1 条事件摘要），单条 IN 子句安全。
    final placeholders = List.filled(memoryIds.length, '?').join(', ');
    await _database.customStatement(
      'DELETE FROM memories_fts WHERE session_id = ? AND memory_id IN '
      '($placeholders)',
      [sessionId, ...memoryIds],
    );

    // 3. 删 experiential_memories（含 embedding BLOB，随行删除；仅 auto 行）
    await (_database.delete(_database.experientialMemoriesTable)
          ..where(
            (t) =>
                t.sessionId.equals(sessionId) &
                t.turnNumber.isBiggerOrEqualValue(fromTurnNumber) &
                t.source.equals('auto'),
          ))
        .go();
  }

  @override
  Future<bool> deleteLatestCompactionMacroMemory({
    required String sessionId,
  }) async {
    // 1. 定位最新一条压缩触发的宏摘要（撤销压缩专用，见接口契约）
    final rows = await (_database.select(_database.experientialMemoriesTable)
          ..where(
            (t) =>
                t.sessionId.equals(sessionId) &
                t.memoryLevel.equals('macro') &
                t.macroTriggerReason.equals('compaction'),
          )
          ..orderBy([
            (t) =>
                OrderingTerm(expression: t.turnNumber, mode: OrderingMode.desc),
          ])
          ..limit(1))
        .get();
    if (rows.isEmpty) return false;
    final memoryId = rows.first.memoryId;

    // 2. 删 FTS5 索引
    await _database.customStatement(
      'DELETE FROM memories_fts WHERE session_id = ? AND memory_id = ?',
      [sessionId, memoryId],
    );

    // 3. 删行（embedding BLOB 随行删除）
    await (_database.delete(_database.experientialMemoriesTable)
          ..where(
            (t) => t.sessionId.equals(sessionId) & t.memoryId.equals(memoryId),
          ))
        .go();
    return true;
  }

  // ==================== 记忆查看器 CRUD（2026-07-22 新增）====================

  @override
  Future<List<ExperientialMemory>> getAllExperiences(
    String sessionId, {
    bool includeArchived = true,
  }) async {
    final query = _database.select(_database.experientialMemoriesTable)
      ..where((t) {
        var condition = t.sessionId.equals(sessionId);
        if (!includeArchived) {
          condition = condition & t.isArchived.equals(false);
        }
        return condition;
      })
      ..orderBy([
        (t) => OrderingTerm(expression: t.turnNumber),
        // 根因加固：同轮并列（压缩 macro 与 micro 同 turnNumber）
        // 次序不稳，createdAt 次级排序让「后写入者在后」恒成立
        (t) => OrderingTerm(expression: t.createdAt),
      ]);
    final rows = await query.get();
    return rows.map(_memoryFromTyped).toList();
  }

  @override
  Future<ExperientialMemory?> getExperienceById(String memoryId) async {
    final row = await (_database.select(_database.experientialMemoriesTable)
          ..where((t) => t.memoryId.equals(memoryId)))
        .getSingleOrNull();
    return row == null ? null : _memoryFromTyped(row);
  }

  @override
  Future<void> updateExperience({
    required String memoryId,
    required String sessionId,
    String? summary,
    String? when,
    String? where,
    String? who,
    String? what,
    String? significance,
    String? extra,
    int? importance,
    List<String>? tags,
  }) async {
    await _database.transaction(() async {
      // 1. 构造更新字段（仅非 null 字段）
      //    注：experiential_memories 表无 updatedAt 列，元数据保留 createdAt
      final companion = ExperientialMemoriesTableCompanion(
        summary: summary != null ? Value(summary) : const Value.absent(),
        whenText: when != null ? Value(when) : const Value.absent(),
        whereText: where != null ? Value(where) : const Value.absent(),
        whoText: who != null ? Value(who) : const Value.absent(),
        whatText: what != null ? Value(what) : const Value.absent(),
        significance:
            significance != null ? Value(significance) : const Value.absent(),
        extra: extra != null ? Value(extra) : const Value.absent(),
        importance:
            importance != null ? Value(importance) : const Value.absent(),
        tags: tags != null ? Value(jsonEncode(tags)) : const Value.absent(),
      );

      // （2026-09-09 审查）：UPDATE 带 session 谓词——此前只按
      // memory_id，跨会话 id 可越权改行；FTS 重建也用主表行自己的
      // sessionId（而不是调用方传入值），杜绝"把记忆搬到别的会话索引里"。
      final affected = await (_database
              .update(_database.experientialMemoriesTable)
            ..where(
              (t) =>
                  t.memoryId.equals(memoryId) & t.sessionId.equals(sessionId),
            ))
          .write(companion);
      if (affected == 0) {
        throw ModelNotFoundException(memoryId);
      }

      // 2. 同步 FTS5 索引：删除旧索引 + 插入新索引
      //    仅当内容字段被修改时才重建索引
      final contentChanged = summary != null ||
          when != null ||
          where != null ||
          who != null ||
          what != null ||
          significance != null ||
          extra != null;
      if (contentChanged) {
        await _database.customStatement(
          'DELETE FROM memories_fts WHERE session_id = ? AND memory_id = ?',
          [sessionId, memoryId],
        );

        // 读取更新后的完整字段重新插入索引（sessionId 取主表行，不取入参）
        final row = await (_database.select(_database.experientialMemoriesTable)
              ..where((t) => t.memoryId.equals(memoryId)))
            .getSingle();
        await insertFtsIndex(
          memoryId: memoryId,
          sessionId: row.sessionId,
          summary: row.summary,
          when: row.whenText,
          where: row.whereText,
          who: row.whoText,
          what: row.whatText,
          significance: row.significance,
          extra: row.extra,
        );
      }
    });
  }

  @override
  Future<void> setExperienceArchived(
    String memoryId, {
    required String sessionId,
    required bool archived,
  }) async {
    await _database.transaction(() async {
      final affected = await (_database
              .update(_database.experientialMemoriesTable)
            ..where(
              (t) =>
                  t.memoryId.equals(memoryId) & t.sessionId.equals(sessionId),
            ))
          .write(
        ExperientialMemoriesTableCompanion(
          isArchived: Value(archived),
        ),
      );
      if (affected == 0) {
        throw ModelNotFoundException(memoryId);
      }
      // 归档不移除 FTS 索引行：读侧过滤（is_archived=0）已保证归档记忆
      // 不进检索结果，保留索引让「恢复」零成本回检索面。
    });
  }

  @override
  Future<void> deleteExperienceById(
    String memoryId, {
    String? sessionId,
  }) async {
    await _database.transaction(() async {
      // 1. 删 FTS5 索引
      await _database.customStatement(
        'DELETE FROM memories_fts WHERE memory_id = ?'
        '${sessionId != null ? ' AND session_id = ?' : ''}',
        sessionId != null ? [memoryId, sessionId] : [memoryId],
      );

      // 2. 删主表（含 embedding BLOB，随行删除；sessionId 非空时加会话谓词）
      await (_database.delete(_database.experientialMemoriesTable)
            ..where((t) {
              var condition = t.memoryId.equals(memoryId);
              if (sessionId != null) {
                condition = condition & t.sessionId.equals(sessionId);
              }
              return condition;
            }))
          .go();
    });
  }

  @override
  Future<void> deleteExperiencesByIds({
    required String sessionId,
    required List<String> memoryIds,
  }) async {
    if (memoryIds.isEmpty) return;

    // 1. 删 FTS5 索引（按 memory_id 批量；未索引记忆为空操作，但保留兼容边界场景）
    final placeholders = List.filled(memoryIds.length, '?').join(', ');
    await _database.customStatement(
      'DELETE FROM memories_fts WHERE session_id = ? AND memory_id IN '
      '($placeholders)',
      [sessionId, ...memoryIds],
    );

    // 2. 删 experiential_memories（含 embedding BLOB，随行删除）
    await (_database.delete(_database.experientialMemoriesTable)
          ..where(
            (t) => t.sessionId.equals(sessionId) & t.memoryId.isIn(memoryIds),
          ))
        .go();
  }

  // ==================== 多粒度记忆（DOC-10 v1.1）====================

  @override
  Future<ExperientialMemory> appendMacroExperience({
    required String sessionId,
    required String summary,
    required int importance,
    required List<String> tags,
    required int turnNumber,
    required List<String> parentEventIds,
    required MacroTriggerReason triggerReason,
    bool indexForRetrieval = true,
  }) async {
    final memoryId = _uuid.v4();
    final now = DateTime.now();

    await _database.into(_database.experientialMemoriesTable).insert(
          ExperientialMemoriesTableCompanion.insert(
            memoryId: memoryId,
            sessionId: sessionId,
            summary: summary,
            turnNumber: turnNumber,
            importance: Value(importance),
            tags: Value(jsonEncode(tags)),
            createdAt: Value(now),
            memoryLevel: const Value('macro'),
            parentEventIds: Value(jsonEncode(parentEventIds)),
            macroTriggerReason: Value(triggerReason.toDbString()),
          ),
        );

    // 单一写入口（2026-09-09 审查）：宏摘要索引与主表同事务写入
    if (indexForRetrieval) {
      await insertFtsIndex(
        memoryId: memoryId,
        sessionId: sessionId,
        summary: summary,
      );
    }

    return ExperientialMemory(
      memoryId: memoryId,
      sessionId: sessionId,
      summary: summary,
      importance: importance,
      tags: tags,
      turnNumber: turnNumber,
      createdAt: now,
      memoryLevel: MemoryLevel.macro,
      parentEventIds: parentEventIds,
      macroTriggerReason: triggerReason,
    );
  }

  @override
  Future<int?> getLastMacroTurnNumber(String sessionId) async {
    final rows = await (_database.select(_database.experientialMemoriesTable)
          ..where(
            (t) =>
                t.sessionId.equals(sessionId) & t.memoryLevel.equals('macro'),
          )
          ..orderBy([
            (t) =>
                OrderingTerm(expression: t.turnNumber, mode: OrderingMode.desc),
          ])
          ..limit(1))
        .get();
    if (rows.isEmpty) return null;
    return rows.first.turnNumber;
  }

  @override
  Future<List<ExperientialMemory>> getMicroSummariesInRange({
    required String sessionId,
    required int fromTurn,
    required int toTurn,
  }) async {
    final rows = await (_database.select(_database.experientialMemoriesTable)
          ..where(
            (t) =>
                t.sessionId.equals(sessionId) &
                t.memoryLevel.equals('micro') &
                t.isArchived.equals(false) &
                t.turnNumber.isBetweenValues(fromTurn, toTurn),
          )
          ..orderBy([
            (t) => OrderingTerm(expression: t.turnNumber),
          ]))
        .get();
    return rows.map(_memoryFromTyped).toList();
  }

  @override
  Future<List<ExperientialMemory>> getMemoriesWithoutEmbedding(
    String sessionId, {
    int limit = 500,
    int? minImportance,
    int? expectedDimensions,
  }) async {
    final query = _database.select(_database.experientialMemoriesTable)
      ..where((t) {
        // expectedDimensions 非空时并入「有向量但维度不符」的陈旧行
        //（维度列为 NULL 亦视为不符——未知维度不能当作匹配，重建即自愈）。
        var condition =
            t.sessionId.equals(sessionId) & t.isArchived.equals(false);
        if (expectedDimensions == null) {
          condition = condition & t.hasEmbedding.equals(false);
        } else {
          condition = condition &
              (t.hasEmbedding.equals(false) |
                  _staleCondition(t, expectedDimensions));
        }
        return condition;
      })
      ..orderBy([
        (t) => OrderingTerm(expression: t.turnNumber),
      ])
      ..limit(limit);
    // 2026-07-22 新增：按 importance 阈值筛选，对齐持久化时的两级向量化策略。
    // 持久化时 importance < microVectorizeThreshold(默认4) 的记忆有意不建
    // embedding，重建时也不应补齐这些记忆。
    if (minImportance != null) {
      query.where((t) => t.importance.isBiggerOrEqualValue(minImportance));
    }
    final rows = await query.get();
    return rows.map(_memoryFromTyped).toList();
  }

  /// 陈旧行条件：有向量且维度与基准不一致（含维度 NULL 的历史行）
  Expression<bool> _staleCondition(
    $ExperientialMemoriesTableTable t,
    int expectedDimensions,
  ) {
    return t.hasEmbedding.equals(true) &
        (t.embeddingDimensions.isNull() |
            t.embeddingDimensions.isNotIn([expectedDimensions]));
  }

  @override
  Future<int?> getLatestEmbeddingDimensions(String sessionId) async {
    final rows = await (_database.select(_database.experientialMemoriesTable)
          ..where(
            (t) =>
                t.sessionId.equals(sessionId) &
                t.embeddingDimensions.isNotNull(),
          )
          ..orderBy([
            (t) =>
                OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
            (t) => OrderingTerm(expression: t.id, mode: OrderingMode.desc),
          ])
          ..limit(1))
        .get();
    if (rows.isEmpty) return null;
    return rows.first.embeddingDimensions;
  }

  // ==================== 私有辅助 ====================

  /// drift 行 → ExperientialMemory 实体
  ExperientialMemory _memoryFromTyped(ExperientialMemoriesTableData row) {
    return ExperientialMemory(
      memoryId: row.memoryId,
      sessionId: row.sessionId,
      summary: row.summary,
      importance: row.importance,
      tags: _decodeTags(row.tags),
      turnNumber: row.turnNumber,
      // 5W1E 字段映射（drift 列名 when_text/where_text/... → 实体字段 when/where/...）
      when: row.whenText,
      where: row.whereText,
      who: row.whoText,
      what: row.whatText,
      significance: row.significance,
      extra: row.extra,
      narrativeTime: row.narrativeTime,
      narrativePeriod: row.narrativePeriod,
      isArchived: row.isArchived,
      isSummary: row.isSummary,
      hasEmbedding: row.hasEmbedding,
      memoryLevel: MemoryLevel.fromString(row.memoryLevel),
      parentEventIds: _decodeStringList(row.parentEventIds),
      macroTriggerReason: MacroTriggerReason.fromString(row.macroTriggerReason),
      source: row.source,
      createdAt: row.createdAt,
    );
  }

  /// 解析 JSON 数组字符串 → List<String>（用于 parentEventIds 字段）
  List<String>? _decodeStringList(String? jsonStr) {
    if (jsonStr == null) return null;
    try {
      final list = jsonDecode(jsonStr) as List<dynamic>;
      return list.cast<String>();
    } catch (_) {
      return null;
    }
  }

  /// 解析 tags JSON 字符串 → List<String>
  List<String> _decodeTags(String tagsJson) {
    try {
      final list = jsonDecode(tagsJson) as List<dynamic>;
      return list.cast<String>();
    } catch (_) {
      return const [];
    }
  }

  /// Float32List → Uint8List（drift BLOB 存储，小端字节序）
  ///
  /// Dart Float32List 默认用宿主字节序（ARM64/x86 均为小端），
  /// 与设计文档"Float32List 小端字节序"一致。
  Uint8List _float32ToBytes(Float32List list) {
    return Uint8List.view(list.buffer, list.offsetInBytes, list.lengthInBytes);
  }

  /// Uint8List（drift BLOB 读取）→ Float32List
  Float32List _bytesToFloat32(Uint8List bytes) {
    if (bytes.lengthInBytes % 4 != 0) {
      throw FormatException(
        'Embedding BLOB length ${bytes.lengthInBytes} not multiple of 4',
      );
    }
    return Float32List.view(
      bytes.buffer,
      bytes.offsetInBytes,
      bytes.lengthInBytes ~/ 4,
    );
  }
}
