import 'package:lmstory/features/memory/domain/entities/experiential_memory.dart';
import 'package:lmstory/features/memory/domain/repositories/experience_repository.dart';

/// 会话记忆索引健康度
///
/// 只统计**应索引却缺索引**的缺口，不把"按策略有意不索引"的低重要性
/// 记忆算成异常：
/// - 关键词索引：importance ≥ importanceStorageThreshold 的记忆必须有
///   `memories_fts` 行（低重要性行由主表子串通道兜底，不算缺口）；
/// - 向量：importance ≥ microVectorizeThreshold 的记忆应有 embedding；
///   追加：有向量但维度与基准（最近一次写入的维度）
///   不一致的行计为陈旧——换嵌入模型后检索静默跳过它们，必须可观测。
class MemoryIndexHealth {
  const MemoryIndexHealth({
    required this.activeMemories,
    required this.unindexedIndexableMemories,
    required this.memoriesWithoutEmbedding,
    this.staleEmbeddingMemories = 0,
    this.expectedEmbeddingDimensions,
  });

  /// 活跃经历记忆总数
  final int activeMemories;

  /// 应建关键词索引却缺行的记忆数
  final int unindexedIndexableMemories;

  /// 应向量化却缺向量的记忆数
  final int memoriesWithoutEmbedding;

  /// 有向量但维度与 [expectedEmbeddingDimensions] 不一致的记忆数
  ///
  /// 换嵌入模型后的陈旧向量——检索侧静默跳过，需要重建才能恢复语义召回。
  final int staleEmbeddingMemories;

  /// 陈旧判定基准（本会话最近一次写入的维度）；null = 会话尚无任何带
  /// 维度的向量（此时无从判定陈旧，staleEmbeddingMemories 恒为 0）
  final int? expectedEmbeddingDimensions;

  /// 关键词索引是否完整（向量缺口不阻塞生成，仅提示）
  bool get keywordIndexHealthy => unindexedIndexableMemories == 0;

  bool get isHealthy =>
      keywordIndexHealthy &&
      memoriesWithoutEmbedding == 0 &&
      staleEmbeddingMemories == 0;
}

/// 记忆索引体检与关键词索引补齐（无新增表/列）
///
/// 补齐只处理"应索引却缺行"的记忆——不把低重要性记忆拉进 FTS，
/// 保留「低重要性记忆由主表子串通道兜底 + 批量提炼消费」的既有语义。
class MemoryIndexHealthService {
  const MemoryIndexHealthService({
    required this.experienceRepository,
  });

  final ExperienceRepository experienceRepository;

  /// 单次体检/补齐的扫描上限（会话级记忆量级，足够覆盖）
  static const int scanLimit = 1000;

  /// 体检（不写库）
  Future<MemoryIndexHealth> inspect(
    String sessionId, {
    required int importanceStorageThreshold,
    required int microVectorizeThreshold,
  }) async {
    final memories = await experienceRepository.getAllExperiences(
      sessionId,
      includeArchived: false,
    );
    final unindexed = await experienceRepository.getUnindexedExperiences(
      sessionId,
      limit: scanLimit,
    );
    // 以最近写入维度为基准取「缺向量 ∪ 维度不符」并集，
    // 再按 hasEmbedding 拆分为「未向量化」与「与新模型不匹配」两口径。
    final expectedDimensions =
        await experienceRepository.getLatestEmbeddingDimensions(sessionId);
    final pendingEmbedding =
        await experienceRepository.getMemoriesWithoutEmbedding(
      sessionId,
      minImportance: microVectorizeThreshold,
      limit: scanLimit,
      expectedDimensions: expectedDimensions,
    );
    return MemoryIndexHealth(
      activeMemories: memories.length,
      unindexedIndexableMemories: unindexed
          .where((m) => m.importance >= importanceStorageThreshold)
          .length,
      memoriesWithoutEmbedding:
          pendingEmbedding.where((m) => !m.hasEmbedding).length,
      staleEmbeddingMemories:
          pendingEmbedding.where((m) => m.hasEmbedding).length,
      expectedEmbeddingDimensions: expectedDimensions,
    );
  }

  /// 补齐关键词索引，返回实际补齐条数。
  ///
  /// 只补 importance ≥ [importanceStorageThreshold] 的记忆；失败逐条抛出
  /// 由调用方呈现（不静默吞掉——补齐失败要能被用户看见）。
  Future<int> repairKeywordIndex(
    String sessionId, {
    required int importanceStorageThreshold,
  }) async {
    final unindexed = await experienceRepository.getUnindexedExperiences(
      sessionId,
      limit: scanLimit,
    );
    var repaired = 0;
    for (final memory in unindexed) {
      if (memory.importance < importanceStorageThreshold) continue;
      await _insertIndex(memory);
      repaired++;
    }
    return repaired;
  }

  Future<void> _insertIndex(ExperientialMemory memory) {
    return experienceRepository.insertFtsIndex(
      memoryId: memory.memoryId,
      sessionId: memory.sessionId,
      summary: memory.summary,
      when: memory.when,
      where: memory.where,
      who: memory.who,
      what: memory.what,
      significance: memory.significance,
      extra: memory.extra,
    );
  }
}
