import 'dart:async';
import 'dart:typed_data';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/vector/vector_engine.dart';
import 'package:lmstory/core/vector/vector_search_result.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/memory/data/repositories/experience_repository_impl.dart';
import 'package:lmstory/features/memory/domain/entities/scored_memory.dart';
import 'package:lmstory/features/memory/domain/services/memory_retrieval_exception.dart';

void main() {
  late AppDatabase db;
  late ExperienceRepositoryImpl repo;
  late _CandidateReadProbe probe;

  setUp(() {
    probe = _CandidateReadProbe();
    db = AppDatabase.forTesting(NativeDatabase.memory().interceptWith(probe));
    repo = ExperienceRepositoryImpl(
      database: db,
      vectorEngine: const VectorEngine(),
    );
  });
  tearDown(() => db.close());

  Future<void> insert({
    required String id,
    required Uint8List? embedding,
    String summary = '',
    int? dimensions,
    String sessionId = 'story',
    bool archived = false,
  }) async {
    await db.into(db.experientialMemoriesTable).insert(
          ExperientialMemoriesTableCompanion.insert(
            memoryId: id,
            sessionId: sessionId,
            turnNumber: 1,
            summary: summary,
            hasEmbedding: const Value(true),
            isArchived: Value(archived),
            embedding: Value(embedding),
            embeddingDimensions: Value(dimensions),
          ),
        );
  }

  Future<List<ScoredMemory>> single(Float32List vector) {
    return repo.searchExperiences(
      sessionId: 'story',
      query: '',
      queryVector: vector,
      topK: 8,
      fts5Weight: 0.5,
      vectorWeight: 0.5,
      keyEventThreshold: 4,
      keyEventBoost: 1.5,
      normalizationEpsilon: 0.01,
    );
  }

  Future<List<ScoredMemory>> multi(
    List<Float32List> vectors, {
    List<String> fts5 = const [],
  }) {
    return repo.searchExperiencesMultiChannel(
      sessionId: 'story',
      fts5Queries: fts5,
      vectorQueries: [
        for (final vector in vectors)
          (query: 'synthetic query', vector: vector),
      ],
      topK: 8,
      fts5Weight: 0.5,
      vectorWeight: 0.5,
      keyEventThreshold: 4,
      keyEventBoost: 1.5,
      normalizationEpsilon: 0.01,
    );
  }

  test('real BLOB dimensions determine eligibility and preserve ranked ties',
      () async {
    await insert(id: 'z-first', embedding: _blob([1, 0]), dimensions: 99);
    await insert(id: 'a-second', embedding: _blob([1, 0]));
    await insert(
      id: 'old-model',
      summary: 'lunar gateway',
      embedding: _blob([0, 1, 0]),
      dimensions: 2,
    );
    await repo.insertFtsIndex(
      memoryId: 'old-model',
      sessionId: 'story',
      summary: 'lunar gateway',
    );
    await insert(id: 'nonfinite', embedding: _blob([double.nan, 0]));
    await insert(id: 'opposite', embedding: _blob([-1, 0]));
    await insert(
      id: 'wrong-size',
      embedding: _blob([1, 0, 0, 0]),
      dimensions: 2,
    );
    await insert(id: 'missing-blob', embedding: null, dimensions: 2);
    final invalid = Uint8List.fromList([1]);
    await insert(id: 'archived', embedding: invalid, archived: true);
    await insert(id: 'other-story', embedding: invalid, sessionId: 'another');

    final current = Float32List.fromList([1, 0]);
    final old = Float32List.fromList([0, 1, 0]);
    expect(_scores(await single(current)), [
      ('z-first', 0, 1, 0.5),
      ('a-second', 0, 1, 0.5),
      ('nonfinite', 0, 0.5, 0.25),
      ('opposite', 0, 0, 0),
    ]);
    final mixed = await multi([current, old, current], fts5: ['lunar gateway']);
    expect(_scores(mixed), [
      ('old-model', 1, 1, 1),
      ('z-first', 0, 1, 0.5),
      ('a-second', 0, 1, 0.5),
      ('nonfinite', 0, 0.5, 0.25),
    ]);
    expect(await multi([Float32List(5), Float32List(6)]), isEmpty);
    expect(await multi([]), isEmpty);
  });

  test('invalid BLOB length fails vector channels and keeps matching FTS',
      () async {
    await insert(
      id: 'match',
      embedding: _blob([1, 0]),
      summary: 'lunar gateway',
    );
    await repo.insertFtsIndex(
      memoryId: 'match',
      sessionId: 'story',
      summary: 'lunar gateway',
    );
    await insert(
      id: 'broken',
      embedding: Uint8List.fromList([1, 2, 3]),
      dimensions: 99,
    );
    final query = Float32List.fromList([1, 0]);
    final vectors = [
      query,
      Float32List.fromList([1, 0, 0]),
    ];
    expect(await single(query), isEmpty);
    expect(_scores(await multi(vectors, fts5: ['lunar gateway'])), [
      ('match', 1, 0, 0.5),
    ]);
    await expectLater(
      multi(vectors),
      throwsA(
        isA<MemoryRetrievalUnavailableException>()
            .having((error) => error.sessionId, 'sessionId', 'story')
            .having((error) => error.attemptedChannels, 'attemptedChannels', 2),
      ),
    );
  });

  test('a scoring failure leaves other vector channels usable', () async {
    repo = ExperienceRepositoryImpl(
      database: db,
      vectorEngine: const _FailThreeDimensions(),
    );
    await insert(id: 'working', embedding: _blob([1, 0]));
    await insert(id: 'fails-to-score', embedding: _blob([1, 0, 0]));
    final results = await multi([
      Float32List.fromList([1, 0, 0]),
      Float32List.fromList([1, 0]),
    ]);
    expect(_scores(results), [('working', 0, 1, 0.5)]);
  });

  test('vector channels share the candidate read across an interleaved write',
      () async {
    final vectors = [
      Float32List.fromList([1, 0]),
      Float32List.fromList([1, 0, 0]),
    ];
    await insert(id: 'old-2d', embedding: _blob([0, 1]));
    await insert(id: 'old-3d', embedding: _blob([0, 1, 0]));
    final gate = probe.gate = Completer<void>();
    final inFlight = multi(vectors);
    try {
      await probe.readReturned.future.timeout(const Duration(seconds: 5));
      await insert(id: 'new-2d', embedding: _blob([1, 0]));
      await insert(id: 'new-3d', embedding: _blob([1, 0, 0]));
    } finally {
      gate.complete();
    }
    const original = [('old-2d', 0.0, 0.5, 0.25), ('old-3d', 0.0, 0.5, 0.25)];
    expect(_scores(await inFlight), original);
    expect(probe.candidateReads, 1);
    expect(_scores(await multi(vectors)), [
      ('new-2d', 0, 1, 0.5),
      ('new-3d', 0, 1, 0.5),
      ...original,
    ]);

    await repo.updateEmbedding('new-2d', Float32List.fromList([-1, 0]));
    await repo.deleteExperienceById('new-3d', sessionId: 'story');
    expect(_scores(await multi(vectors)), original);
    expect(probe.candidateReads, 3);
  });
}

Uint8List _blob(List<double> values) =>
    Uint8List.sublistView(Float32List.fromList(values));

List<(String, double, double, double)> _scores(List<ScoredMemory> memories) => [
      for (final item in memories)
        (
          item.memory.memoryId,
          item.fts5Score,
          item.vectorScore,
          item.finalScore
        ),
    ];

class _CandidateReadProbe extends QueryInterceptor {
  final readReturned = Completer<void>();
  Completer<void>? gate;
  int candidateReads = 0;

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    if (!statement.contains('has_embedding') ||
        !statement.contains('experiential_memories')) {
      return executor.runSelect(statement, args);
    }

    final first = ++candidateReads == 1;
    final boundary = gate;
    // A second candidate statement would see the writes made at the gate.
    if (!first && boundary != null) {
      await boundary.future;
    }
    final rows = await executor.runSelect(statement, args);
    if (first && boundary != null) {
      readReturned.complete();
      await boundary.future;
    }
    return rows;
  }
}

class _FailThreeDimensions extends VectorEngine {
  const _FailThreeDimensions();

  @override
  Future<List<VectorSearchResult>> batchSearch({
    required Float32List queryVector,
    required List<Float32List> candidates,
    required List<int> candidateIds,
  }) {
    if (queryVector.length == 3) throw StateError('Synthetic scoring failure');
    return super.batchSearch(
      queryVector: queryVector,
      candidates: candidates,
      candidateIds: candidateIds,
    );
  }
}
