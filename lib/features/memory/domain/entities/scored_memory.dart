import 'package:lmstory/features/memory/domain/entities/experiential_memory.dart';
import 'package:meta/meta.dart';

/// 带分数的检索结果（DOC-05 §4.2）
///
/// 中级模式两路检索中 temporalScore 固定为 0（无 temporal 通道）。
/// v0.3 Advanced 模式才启用 temporal 通道。
@immutable
class ScoredMemory {
  const ScoredMemory({
    required this.memory,
    required this.fts5Score,
    required this.vectorScore,
    required this.temporalScore,
    required this.finalScore,
  });

  final ExperientialMemory memory;

  /// FTS5 通道归一化分数 [0, 1]
  final double fts5Score;

  /// Vector 通道归一化分数 [0, 1]
  final double vectorScore;

  /// Temporal 通道分数（中级模式恒 0）
  final double temporalScore;

  /// 最终合并分数（含关键事件加权 + 归一化）
  final double finalScore;
}
