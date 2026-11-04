import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:lmstory/core/vector/vector_search_result.dart';

/// 向量计算引擎（v0.2 中级模式向量检索主方案）
///
/// 纯 Dart 暴力检索：扫描全部候选向量计算余弦相似度，100% 召回率。
/// 性能：1536 维 × 1000 条 ≈ 5-15ms（ARM64 Isolate），满足  ≤50ms 目标。
///
/// 方案背景（后定案）：原计划用 sqlite-vec 扩展做 SQL KNN 检索，
/// 但 pub 包损坏废弃（src/ 缺失 sqlite-vec.c），改用纯 Dart 方案。
/// v0.3 升级路径：待 vec1（SQLite 官方向量扩展）出现 Dart 绑定后重新评估。
class VectorEngine {
  const VectorEngine();

  /// 计算两个向量的余弦相似度
  ///
  /// 返回值 ∈ [-1, 1]：1=完全相似，0=正交，-1=完全相反。
  /// 零向量（norm=0）返回 0（避免除零）。
  /// 维度不一致或长度为 0 抛 [ArgumentError]。
  double cosineSimilarity(Float32List a, Float32List b) {
    if (a.length != b.length) {
      throw ArgumentError(
        'Vector dimension mismatch: ${a.length} vs ${b.length}',
      );
    }
    if (a.isEmpty) {
      throw ArgumentError('Vectors must not be empty');
    }
    return _cosineSimilarityPure(a, b);
  }

  /// 批量向量相似度计算（v0.2 主方案）
  ///
  /// - [queryVector]：查询向量
  /// - [candidates]：候选向量列表（顺序与 [candidateIds] 一一对应）
  /// - [candidateIds]：候选 ID 列表（在 v0.2 中为 experiential_memories.id）
  ///
  /// 返回全部候选的 [VectorSearchResult]，按 `cosineScore` 降序排列。
  /// **不做 topK 截断**——调用方（Repository）需要 topK×2 候选做合并排序
  /// （DOC-09A-1 §3.4）。
  ///
  /// 空候选列表返回空列表。`candidates.length` 必须等于 `candidateIds.length`。
  ///
  /// 平台兼容：
  /// - 原生平台：在 Isolate 中执行，避免阻塞 UI
  /// - Web 平台：浏览器不支持 Isolate，直接在主线程计算
  ///   （v0.2 记忆数量通常 <1000，纯数学计算不会明显阻塞）
  Future<List<VectorSearchResult>> batchSearch({
    required Float32List queryVector,
    required List<Float32List> candidates,
    required List<int> candidateIds,
  }) async {
    if (candidates.isEmpty) {
      return const <VectorSearchResult>[];
    }
    if (candidates.length != candidateIds.length) {
      throw ArgumentError(
        'candidates.length (${candidates.length}) != '
        'candidateIds.length (${candidateIds.length})',
      );
    }

    // 预先校验维度一致（在主 Isolate 抛错，比在子 Isolate 抛更易诊断）
    for (var i = 0; i < candidates.length; i++) {
      if (candidates[i].length != queryVector.length) {
        throw ArgumentError(
          'Candidate $i dimension ${candidates[i].length} != '
          'query ${queryVector.length}',
        );
      }
    }

    // 原生平台用 Isolate 避免阻塞 UI；Web 平台不支持 Isolate，主线程直接算
    final List<_Scored> rawScores;
    if (kIsWeb) {
      rawScores = _computeAllScores(queryVector, candidates, candidateIds);
    } else {
      rawScores = await Isolate.run(() {
        return _computeAllScores(queryVector, candidates, candidateIds);
      });
    }

    return [
      for (final s in rawScores)
        VectorSearchResult(candidateId: s.id, cosineScore: s.score),
    ];
  }
}

/// Isolate 内部使用的中间结构（含 const 构造，可跨 Isolate 传递）
class _Scored {
  const _Scored(this.id, this.score);
  final int id;
  final double score;
}

/// 计算全部候选的相似度并排序（纯计算，可在 Isolate 或主线程执行）
List<_Scored> _computeAllScores(
  Float32List queryVector,
  List<Float32List> candidates,
  List<int> candidateIds,
) {
  final scores = <_Scored>[];
  for (var i = 0; i < candidates.length; i++) {
    final score = _cosineSimilarityPure(queryVector, candidates[i]);
    scores.add(_Scored(candidateIds[i], score));
  }
  scores.sort((a, b) => b.score.compareTo(a.score));
  return scores;
}

/// 纯计算函数（无 this 依赖，可在 Isolate 闭包内调用）
double _cosineSimilarityPure(Float32List a, Float32List b) {
  double dot = 0;
  double normA = 0;
  double normB = 0;
  for (var i = 0; i < a.length; i++) {
    final ai = a[i];
    final bi = b[i];
    dot += ai * bi;
    normA += ai * ai;
    normB += bi * bi;
  }
  // NaN/Inf 保护：embedding 数据损坏时避免污染排序结果
  if (dot.isNaN || dot.isInfinite) return 0;
  if (normA.isNaN || normA.isInfinite) return 0;
  if (normB.isNaN || normB.isInfinite) return 0;
  final denom = math.sqrt(normA) * math.sqrt(normB);
  if (denom == 0) return 0; // 零向量保护
  final similarity = dot / denom;
  // 最终结果再做一次保护，防止极小数值溢出
  if (similarity.isNaN || similarity.isInfinite) return 0;
  return similarity;
}
