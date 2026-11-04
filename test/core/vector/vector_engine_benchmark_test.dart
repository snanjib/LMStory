import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/vector/vector_engine.dart';

void main() {
  const engine = VectorEngine();
  final random = Random(42); // 固定种子保证可复现

  // 生成指定维度随机向量（已归一化，避免零向量）
  Float32List genVector(int dim) {
    final v = Float32List(dim);
    double norm = 0;
    for (var i = 0; i < dim; i++) {
      v[i] = random.nextDouble() * 2 - 1;
      norm += v[i] * v[i];
    }
    norm = sqrt(norm);
    for (var i = 0; i < dim; i++) {
      v[i] = v[i] / norm;
    }
    return v;
  }

  test('性能基准：1536 维 × 1000 条 ≤ 50ms（Q-02）', () async {
    const dim = 1536;
    const count = 1000;
    final query = genVector(dim);
    final candidates = [for (var i = 0; i < count; i++) genVector(dim)];
    final ids = [for (var i = 0; i < count; i++) i];

    final stopwatch = Stopwatch()..start();
    final result = await engine.batchSearch(
      queryVector: query,
      candidates: candidates,
      candidateIds: ids,
    );
    stopwatch.stop();

    expect(result.length, count);
    // 排序正确性：第一条 score 最高
    for (var i = 1; i < result.length; i++) {
      expect(
        result[i - 1].cosineScore,
        greaterThanOrEqualTo(result[i].cosineScore),
      );
    }

    //  性能目标：≤50ms
    // 注意：debug mode 下 JIT 较慢，profile/release 才是真实性能
    // 此处用宽松上限（200ms）防 CI 误报；真机 profile 模式应 <50ms
    // ignore: avoid_print
    print('batchSearch $dim维×$count条耗时: '
        '${stopwatch.elapsedMilliseconds}ms');
    expect(
      stopwatch.elapsedMilliseconds,
      lessThan(200),
      reason: 'debug 模式宽松上限 200ms；profile/release 应 ≤50ms',
    );
  });

  test('cosineSimilarity 单次计算 <5ms', () {
    const dim = 1536;
    final a = genVector(dim);
    final b = genVector(dim);

    final stopwatch = Stopwatch()..start();
    engine.cosineSimilarity(a, b);
    stopwatch.stop();

    // ignore: avoid_print
    print('cosineSimilarity $dim维单次耗时: '
        '${stopwatch.elapsedMicroseconds}μs');
    expect(stopwatch.elapsedMilliseconds, lessThan(5));
  });
}
