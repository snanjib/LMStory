import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/vector/vector_engine.dart';
import 'package:lmstory/core/vector/vector_search_result.dart';

void main() {
  const engine = VectorEngine();

  group('cosineSimilarity', () {
    test('完全相同向量返回 1.0', () {
      final a = Float32List.fromList([1.0, 2.0, 3.0]);
      final b = Float32List.fromList([1.0, 2.0, 3.0]);
      expect(engine.cosineSimilarity(a, b), closeTo(1.0, 1e-6));
    });

    test('完全相反向量返回 -1.0', () {
      final a = Float32List.fromList([1.0, 0.0]);
      final b = Float32List.fromList([-1.0, 0.0]);
      expect(engine.cosineSimilarity(a, b), closeTo(-1.0, 1e-6));
    });

    test('正交向量返回 0.0', () {
      final a = Float32List.fromList([1.0, 0.0]);
      final b = Float32List.fromList([0.0, 1.0]);
      expect(engine.cosineSimilarity(a, b), closeTo(0.0, 1e-6));
    });

    test('零向量返回 0.0（避免除零）', () {
      final a = Float32List.fromList([0.0, 0.0, 0.0]);
      final b = Float32List.fromList([1.0, 2.0, 3.0]);
      expect(engine.cosineSimilarity(a, b), 0.0);
    });

    test('维度不一致抛 ArgumentError', () {
      final a = Float32List.fromList([1.0, 2.0]);
      final b = Float32List.fromList([1.0, 2.0, 3.0]);
      expect(() => engine.cosineSimilarity(a, b), throwsArgumentError);
    });

    test('空向量抛 ArgumentError', () {
      final a = Float32List(0);
      final b = Float32List(0);
      expect(() => engine.cosineSimilarity(a, b), throwsArgumentError);
    });

    test('近似向量返回 (0,1) 之间', () {
      final a = Float32List.fromList([1.0, 1.0]);
      final b = Float32List.fromList([1.0, 0.5]);
      final score = engine.cosineSimilarity(a, b);
      expect(score, greaterThan(0));
      expect(score, lessThan(1));
    });
  });

  group('batchSearch', () {
    test('空候选列表返回空列表', () async {
      final result = await engine.batchSearch(
        queryVector: Float32List.fromList([1.0, 0.0]),
        candidates: const [],
        candidateIds: const [],
      );
      expect(result, isEmpty);
    });

    test('按 cosineScore 降序排列', () async {
      final query = Float32List.fromList([1.0, 0.0]);
      final candidates = [
        Float32List.fromList([0.0, 1.0]), // 正交，score=0
        Float32List.fromList([1.0, 0.0]), // 同向，score=1
        Float32List.fromList([-1.0, 0.0]), // 反向，score=-1
      ];
      final result = await engine.batchSearch(
        queryVector: query,
        candidates: candidates,
        candidateIds: const [10, 20, 30],
      );
      expect(result.length, 3);
      expect(result[0].candidateId, 20); // score=1
      expect(result[1].candidateId, 10); // score=0
      expect(result[2].candidateId, 30); // score=-1
      expect(result[0].cosineScore, closeTo(1.0, 1e-6));
      expect(result[2].cosineScore, closeTo(-1.0, 1e-6));
    });

    test('candidateIds 与 candidates 长度不一致抛 ArgumentError', () async {
      expect(
        () => engine.batchSearch(
          queryVector: Float32List.fromList([1.0]),
          candidates: [
            Float32List.fromList([1.0]),
          ],
          candidateIds: const [1, 2],
        ),
        throwsArgumentError,
      );
    });

    test('候选维度与查询维度不一致抛 ArgumentError', () async {
      expect(
        () => engine.batchSearch(
          queryVector: Float32List.fromList([1.0, 2.0]),
          candidates: [
            Float32List.fromList([1.0]),
          ],
          candidateIds: const [1],
        ),
        throwsArgumentError,
      );
    });

    test('返回 VectorSearchResult 类型正确', () async {
      final result = await engine.batchSearch(
        queryVector: Float32List.fromList([1.0, 0.0]),
        candidates: [
          Float32List.fromList([1.0, 0.0]),
        ],
        candidateIds: const [42],
      );
      expect(result.first, isA<VectorSearchResult>());
      expect(result.first.candidateId, 42);
    });
  });
}
