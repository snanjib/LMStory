import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/exceptions/app_exceptions.dart';
import 'package:lmstory/core/vector/vector_engine.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/memory/data/repositories/experience_repository_impl.dart';
import 'package:lmstory/features/memory/domain/entities/experiential_memory.dart';
import 'package:lmstory/features/memory/domain/services/memory_retrieval_exception.dart';

/// 经历层检索可达性
///
/// 覆盖用户报告的「翻阅前情对库中已有的记忆报未命中」：
/// - <3 rune 的中文短词（"老人"）在 trigram 下无法召回 → 短词 LIKE 通道；
/// - importance < 存储门槛的记忆没有 FTS 行 → 主表子串兜底；
/// - 索引维护收口到 appendExperience（手动新增也建索引）。
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

  Future<int> ftsRowCount() async {
    final row = await db
        .customSelect('SELECT COUNT(*) AS c FROM memories_fts')
        .getSingle();
    return row.read<int>('c');
  }

  test('appendExperience 默认同事务写 FTS 行（单一写入口，FE5）', () async {
    final memory = await repo.appendExperience(
      sessionId: 's1',
      summary: '苏明远推开荒庙的门',
      importance: 4,
      tags: const [],
      turnNumber: 1,
      who: '苏明远',
      what: '推开荒庙的门',
    );

    expect(await ftsRowCount(), 1);
    // 5W1E 字段也进索引（who/what 可被关键词召回）
    final hits = await repo.searchExperiencesBySubstring('s1', ['苏明远']);
    expect(hits.single.memoryId, memory.memoryId);
  });

  test('indexForRetrieval=false 时不建 FTS 行（低重要性记忆策略不变）', () async {
    await repo.appendExperience(
      sessionId: 's1',
      summary: '无关紧要的一瞥',
      importance: 1,
      tags: const [],
      turnNumber: 1,
      indexForRetrieval: false,
    );

    expect(await ftsRowCount(), 0);
  });

  test('appendMacroExperience 同事务写 FTS 行', () async {
    await repo.appendMacroExperience(
      sessionId: 's1',
      summary: '第一幕：荒庙现世',
      importance: 3,
      tags: const ['compaction'],
      turnNumber: 3,
      parentEventIds: const [],
      triggerReason: MacroTriggerReason.compaction,
    );

    expect(await ftsRowCount(), 1);
  });

  test('主表子串兜底：importance=1（无 FTS 行）的记忆仍可召回（FE2）', () async {
    await repo.appendExperience(
      sessionId: 's1',
      summary: '老人在旧书店里翻找古籍',
      importance: 1,
      tags: const [],
      turnNumber: 2,
      indexForRetrieval: false,
    );
    expect(await ftsRowCount(), 0, reason: '该记忆确实没有索引行');

    final hits = await repo.searchExperiencesBySubstring('s1', ['旧书店']);
    expect(hits.single.summary, contains('旧书店'));
  });

  test('双字关键词经多通道可召回（trigram 短词 LIKE 兜底，FE1）', () async {
    final memory = await repo.appendExperience(
      sessionId: 's1',
      summary: '老人在旧书店里翻找古籍',
      importance: 4,
      tags: const [],
      turnNumber: 2,
    );

    // 两字人名/地名此前在 FTS 通道零 token；现由短词 LIKE 通道补齐
    final hits = await repo.searchExperiencesMultiChannel(
      sessionId: 's1',
      fts5Queries: const ['老人'],
      vectorQueries: const [],
      topK: 5,
      fts5Weight: 0.5,
      vectorWeight: 0.5,
      keyEventThreshold: 4,
      keyEventBoost: 1.5,
      normalizationEpsilon: 0.01,
    );

    expect(hits.map((h) => h.memory.memoryId), contains(memory.memoryId));
  });

  test('多词/标点查询不再被粘连成假词（FE6）', () async {
    final memory = await repo.appendExperience(
      sessionId: 's1',
      summary: '林墨与剑冢的旧事',
      importance: 4,
      tags: const [],
      turnNumber: 2,
    );

    final hits = await repo.searchExperiencesMultiChannel(
      sessionId: 's1',
      fts5Queries: const ['林墨(主角)、剑冢'],
      vectorQueries: const [],
      topK: 5,
      fts5Weight: 0.5,
      vectorWeight: 0.5,
      keyEventThreshold: 4,
      keyEventBoost: 1.5,
      normalizationEpsilon: 0.01,
    );

    expect(hits.map((h) => h.memory.memoryId), contains(memory.memoryId));
  });

  test('子串兜底：会话隔离 + 归档默认排除', () async {
    await repo.appendExperience(
      sessionId: 's1',
      summary: '本会话的记忆',
      importance: 4,
      tags: const [],
      turnNumber: 1,
    );
    await repo.appendExperience(
      sessionId: 's2',
      summary: '别会话的旧书店',
      importance: 4,
      tags: const [],
      turnNumber: 1,
    );

    final hits = await repo.searchExperiencesBySubstring('s1', ['旧书店']);
    expect(hits, isEmpty);
    expect(
      (await repo.searchExperiencesBySubstring('s2', ['旧书店'])).single.summary,
      contains('旧书店'),
    );
  });

  test('LIKE 通配符按字面匹配（% 不是通配符）', () async {
    await repo.appendExperience(
      sessionId: 's1',
      summary: '100% 纯度',
      importance: 4,
      tags: const [],
      turnNumber: 1,
    );
    await repo.appendExperience(
      sessionId: 's1',
      summary: '无关的一瞥',
      importance: 4,
      tags: const [],
      turnNumber: 2,
    );

    // "%" 作为普通字符：只命中含字面 % 的那条，而不是全部
    final hits = await repo.searchExperiencesBySubstring('s1', ['%']);
    expect(hits, hasLength(1));
    expect(hits.single.summary, contains('100%'));
    expect(
      await repo.searchExperiencesBySubstring('s1', ['100%']),
      hasLength(1),
    );
  });

  test('FE10：updateExperience 按 session 谓词生效，FTS 行用主表 sessionId', () async {
    final memory = await repo.appendExperience(
      sessionId: 's1',
      summary: '旧摘要',
      importance: 4,
      tags: const [],
      turnNumber: 1,
    );

    // 错会话更新 → 拒绝（不越权改行）
    await expectLater(
      repo.updateExperience(
        memoryId: memory.memoryId,
        sessionId: 's2',
        summary: '越权改写',
      ),
      throwsA(isA<ModelNotFoundException>()),
    );

    await repo.updateExperience(
      memoryId: memory.memoryId,
      sessionId: 's1',
      summary: '新摘要',
    );

    final ftsRows = await db
        .customSelect('SELECT session_id, summary FROM memories_fts')
        .get();
    expect(ftsRows, hasLength(1));
    expect(ftsRows.single.read<String>('session_id'), 's1');
    expect(ftsRows.single.read<String>('summary'), '新摘要');
    expect(await repo.searchExperiencesBySubstring('s1', ['旧摘要']), isEmpty);
    expect(
      await repo.searchExperiencesBySubstring('s1', ['新摘要']),
      hasLength(1),
    );
  });

  test('全通道失败 → 抛 MemoryRetrievalUnavailableException（不伪装未命中，FE7）', () async {
    await repo.appendExperience(
      sessionId: 's1',
      summary: '存在但索引坏了',
      importance: 4,
      tags: const [],
      turnNumber: 1,
    );
    // 删掉 FTS 表模拟索引损坏：MATCH 会抛异常 → FTS 通道 failed
    await db.customStatement('DROP TABLE memories_fts');

    await expectLater(
      repo.searchExperiencesMultiChannel(
        sessionId: 's1',
        fts5Queries: const ['旧书店'],
        vectorQueries: const [],
        topK: 5,
        fts5Weight: 0.5,
        vectorWeight: 0.5,
        keyEventThreshold: 4,
        keyEventBoost: 1.5,
        normalizationEpsilon: 0.01,
      ),
      throwsA(isA<MemoryRetrievalUnavailableException>()),
    );
  });
}
