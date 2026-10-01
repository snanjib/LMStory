/// Core 层向量检索结果（不含 Domain 业务实体）
///
/// 由 VectorEngine.batchSearch 返回。`candidateId` 对应调用方传入的
/// 候选 ID（在 v0.2 中级模式中为 experiential_memories 主键 id）。
/// `cosineScore` 为原始余弦相似度 ∈ [-1, 1]，归一化到 [0,1] 由
/// Repository 层完成（DOC-09A-1 §3.5：`vectorScore = (similarity+1)/2`）。
class VectorSearchResult {
  const VectorSearchResult({
    required this.candidateId,
    required this.cosineScore,
  });

  /// 候选向量 ID（由调用方传入，VectorEngine 不解释其语义）
  final int candidateId;

  /// 余弦相似度 ∈ [-1, 1]（1=完全相似，0=正交，-1=完全相反）
  final double cosineScore;

  @override
  String toString() =>
      'VectorSearchResult(candidateId: $candidateId, cosineScore: $cosineScore)';
}
