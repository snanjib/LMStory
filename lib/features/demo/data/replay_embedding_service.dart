import 'dart:typed_data';

import 'package:lmstory/features/demo/data/demo_network_guard.dart';
import 'package:lmstory/features/demo/domain/demo_pack.dart';
import 'package:lmstory/features/demo/domain/demo_pack_fingerprint.dart';
import 'package:lmstory/features/memory/domain/services/embedding_service.dart';

/// 演示回放嵌入失败（本地、不联网）
class DemoReplayEmbeddingMissException implements Exception {
  const DemoReplayEmbeddingMissException(this.inputPreview);

  final String inputPreview;

  @override
  String toString() => 'DemoReplayEmbeddingMissException(input: $inputPreview)';
}

/// 演示回放 EmbeddingService：按规范化输入哈希供给包内预置向量。
///
/// 纯查找、无消耗、天然幂等可重试、并发安全；未命中抛
/// [DemoReplayEmbeddingMissException] 并计入守卫（不联网、不编造向量）。
class DemoReplayEmbeddingService implements EmbeddingService {
  DemoReplayEmbeddingService({
    required this.pack,
    required DemoNetworkGuard guard,
  }) : _guard = guard;

  /// 当前绑定数据包；赋值即换绑（多仿真候选选择）：后续嵌入请求从新包
  /// 查找。零 embed 行的候选保持合法——未命中照旧本地失败（不联网、
  /// 不伪造）。
  DemoPack pack;
  final DemoNetworkGuard _guard;

  @override
  Future<Float32List> embed({
    required String text,
    required EmbeddingInputKind kind,
    required String model,
    required String baseUrl,
    required String? apiKey,
    Duration? timeout,
  }) async {
    final hash = hashEmbeddingInput(text);
    final hit = pack.embeddingFor(kind.name, hash);
    if (hit == null) {
      _guard.record(
        'embeddingUnmatched',
        'kind=${kind.name} input=${normalizeEmbeddingInput(text).substring(0, text.length.clamp(0, 48))}',
      );
      throw DemoReplayEmbeddingMissException(
        normalizeEmbeddingInput(text).substring(0, text.length.clamp(0, 24)),
      );
    }
    return Float32List.fromList(hit.values);
  }
}
