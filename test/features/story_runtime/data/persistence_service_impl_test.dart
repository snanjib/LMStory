import 'dart:typed_data';

// ignore_for_file: avoid_redundant_argument_values
import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/core/vector/vector_engine.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/chat/data/repositories/chat_repository_impl.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/entities/story_anchor.dart';
import 'package:lmstory/features/chat/domain/repositories/chat_repository.dart';
import 'package:lmstory/features/memory/data/repositories/experience_repository_impl.dart';
import 'package:lmstory/features/memory/data/repositories/factual_repository_impl.dart';
import 'package:lmstory/features/memory/domain/entities/event_summary.dart';
import 'package:lmstory/features/memory/domain/entities/experiential_memory.dart';
import 'package:lmstory/features/memory/domain/entities/facts_delta.dart';
import 'package:lmstory/features/memory/domain/entities/scored_memory.dart';
import 'package:lmstory/features/memory/domain/repositories/experience_repository.dart';
import 'package:lmstory/features/memory/domain/services/fact_applier.dart';
import 'package:lmstory/features/story_runtime/data/persistence_service_impl.dart';
import 'package:lmstory/features/story_runtime/domain/entities/message_variant_record.dart';
import 'package:lmstory/features/story_runtime/domain/entities/round_artifacts.dart';
import 'package:lmstory/features/story_runtime/domain/services/persistence_service.dart';

import '../../../helpers/fake_factual_repository.dart';

/// StoryPersistenceServiceImpl 单元测试（计划 §6.1）
///
/// 使用内存 drift 数据库验证 5 步原子持久化、embedding 降级、事务回滚、
/// FTS 索引同步、会话元数据更新。
void main() {
  late AppDatabase db;
  late ChatRepository chatRepo;
  late ExperienceRepository expRepo;
  late StoryPersistenceServiceImpl service;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    chatRepo = ChatRepositoryImpl(database: db);
    expRepo = ExperienceRepositoryImpl(
      database: db,
      vectorEngine: const VectorEngine(),
    );
    service = StoryPersistenceServiceImpl(
      database: db,
      chatRepository: chatRepo,
      experienceRepository: expRepo,
    );
  });

  tearDown(() async => db.close());

  Future<List<ExperientialMemory>> seedConsolidationSources(
    String sessionId,
  ) async {
    for (var turn = 1; turn <= 2; turn++) {
      await expRepo.appendExperience(
        sessionId: sessionId,
        summary: 'Source $turn',
        importance: 2,
        tags: const ['original'],
        turnNumber: turn,
        indexForRetrieval: false,
      );
    }
    return expRepo.getUnindexedExperiences(sessionId, limit: 2);
  }

  /// 构造测试用会话 + 用户消息 + 助手消息 + 事件摘要
  Future<
      ({
        String sessionId,
        ChatMessage userMsg,
        ChatMessage assistantMsg,
        EventSummary summary
      })> setupRound() async {
    final session = await chatRepo.createSession(
      title: '测试会话',
      mode: 'intermediate',
    );
    final sessionId = session.sessionId;
    final now = DateTime(2026);
    final userMsg = ChatMessage(
      messageId: 'u1',
      sessionId: sessionId,
      role: 'user',
      content: '勇者前往后山',
      createdAt: now,
    );
    final assistantMsg = ChatMessage(
      messageId: 'a1',
      sessionId: sessionId,
      role: 'assistant',
      content: '勇者穿过密林，发现了一座古碑。',
      createdAt: now,
    );
    const summary = EventSummary(
      summary: '勇者发现古碑',
      importance: 3,
      tags: ['探索', '古碑'],
      turnNumber: 1,
    );
    return (
      sessionId: sessionId,
      userMsg: userMsg,
      assistantMsg: assistantMsg,
      summary: summary,
    );
  }

  /// 17b/17c/17d 助手（声明在 main 内 groups 之前）：写入第 [turn] 轮
  /// （消息+记忆+带锚 artifacts）。artifacts.storyAnchor 为「该轮结束时
  /// 的当前锚」（persistRound 8.5 步同事务写 chat_sessions.story_anchor，
  /// null = 该轮未动锚且此前无锚）。第 1 轮复用 setupRound 已备好的
  /// u1/a1/summary（避免主键冲突）。
  Future<void> persistRoundWithAnchor(
    ({
      String sessionId,
      ChatMessage userMsg,
      ChatMessage assistantMsg,
      EventSummary summary,
    }) r,
    int turn,
    StoryAnchor? anchor,
  ) async {
    final userMsg = turn == 1
        ? r.userMsg
        : ChatMessage(
            messageId: 'u$turn',
            sessionId: r.sessionId,
            role: 'user',
            content: '第 $turn 轮',
            createdAt: DateTime(2026),
          );
    final assistantMsg = turn == 1
        ? r.assistantMsg
        : ChatMessage(
            messageId: 'a$turn',
            sessionId: r.sessionId,
            role: 'assistant',
            content: '第 $turn 轮回复',
            createdAt: DateTime(2026),
          );
    final summary = turn == 1
        ? r.summary
        : EventSummary(
            summary: '第 $turn 轮事件',
            importance: 2,
            tags: const ['探索'],
            turnNumber: turn,
          );
    await service.persistRound(
      userMessage: userMsg,
      assistantMessage: assistantMsg,
      eventSummary: summary,
      embedding: null,
      artifacts: StoryRoundArtifacts(
        sessionId: r.sessionId,
        turnNumber: turn,
        generatedText: '第 $turn 轮草稿',
        extractedKeywords: ['kw$turn'],
        storyAnchor: anchor,
        createdAt: DateTime(2026),
      ),
    );
  }

  group('persistRound', () {
    test('单条事实在写流水时失败，人物和初始属性一并撤销，其余事实正常保存', () async {
      final round = await setupRound();
      final facts = FactualRepositoryImpl(database: db);
      final serviceWithFacts = StoryPersistenceServiceImpl(
        database: db,
        chatRepository: chatRepo,
        experienceRepository: expRepo,
        factApplier: FactApplier(repository: facts),
      );
      await db.customStatement(
        'CREATE TEMP TRIGGER abort_middle_history BEFORE INSERT ON factual_memory_history '
        "WHEN NEW.new_value = '药师' BEGIN SELECT RAISE(ABORT, 'injected failure'); END",
      );
      await serviceWithFacts.persistRound(
        userMessage: round.userMsg,
        assistantMessage: round.assistantMsg,
        eventSummary: round.summary,
        embedding: null,
        artifacts: StoryRoundArtifacts(
          sessionId: round.sessionId,
          turnNumber: 1,
          createdAt: DateTime(2026),
        ),
        factsDeltas: [
          for (final name in ['向导', '药师', '掌柜'])
            FactsDelta(
              action: FactAction.createEntity,
              entityType: 'character',
              primaryName: name,
              attrKey: 'background',
              value: '随队出发',
              confidence: 5,
            ),
        ],
        factualConfig: const FactualConfig(),
      );
      for (final name in ['向导', '掌柜']) {
        final entity = (await facts.findByName(round.sessionId, [name])).single;
        expect((await facts.getHistory(entity.entityId)).single.newValue, name);
        expect(
          (await facts.getAttributesByKey(entity.entityId, 'background'))
              .single
              .value,
          '随队出发',
        );
      }
      expect(await facts.findByName(round.sessionId, ['药师']), isEmpty);
      final attributes = await db.customSelect(
        'SELECT * FROM factual_attributes WHERE session_id = ?',
        variables: [Variable.withString(round.sessionId)],
      ).get();
      expect(attributes, hasLength(2));
      expect(
        (await chatRepo.getMessages(round.sessionId)).last.content,
        round.assistantMsg.content,
      );
      expect(
        (await expRepo.getRecentExperiences(round.sessionId, limit: 5))
            .single
            .summary,
        round.summary.summary,
      );
    });

    test('1. 成功：5 步全部写入（消息+记忆+FTS+会话元数据）', () async {
      final r = await setupRound();

      final memory = (await service.persistRound(
        userMessage: r.userMsg,
        assistantMessage: r.assistantMsg,
        eventSummary: r.summary,
        embedding: null,
        artifacts: null,
      ))
          .memory;

      // 1-2. chat_messages 两条
      final messages = await chatRepo.getMessages(r.sessionId);
      expect(messages.length, 2);
      expect(messages[0].role, 'user');
      expect(messages[1].role, 'assistant');

      // 3. experiential_memories 一条
      expect(memory.memoryId, isNotEmpty);
      expect(memory.summary, '勇者发现古碑');
      expect(memory.importance, 3);
      expect(memory.tags, ['探索', '古碑']);
      expect(memory.turnNumber, 1);
      expect(memory.hasEmbedding, isFalse);

      // 5. FTS 索引可检索
      final scored = await expRepo.searchExperiences(
        sessionId: r.sessionId,
        query: '勇者发现',
        queryVector: null,
        topK: 5,
        fts5Weight: 0.5,
        vectorWeight: 0.5,
        keyEventThreshold: 4,
        keyEventBoost: 1.5,
        normalizationEpsilon: 0.01,
      );
      expect(scored.length, 1);
      expect(scored.first.memory.memoryId, memory.memoryId);

      // 6. session messageCount +2
      final session = await chatRepo.getSession(r.sessionId);
      expect(session.messageCount, 2);
    });

    test('1b. 编辑重发变体收口：该轮已有变体行时新内容记为变体并移指针', () async {
      final r = await setupRound();

      StoryRoundArtifacts artifactsFor(int turn, String text) =>
          StoryRoundArtifacts(
            sessionId: r.sessionId,
            turnNumber: turn,
            generatedText: text,
            replyText: text,
            createdAt: DateTime(2026),
          );

      // 普通发送轮：变体表为空 → persistRound 不记录变体
      await service.persistRound(
        userMessage: r.userMsg,
        assistantMessage: r.assistantMsg,
        eventSummary: r.summary,
        embedding: null,
        artifacts: artifactsFor(1, '旧版正文'),
      );
      var variants = await service.loadMessageVariants(r.sessionId);
      expect(
        variants[1] ?? const <MessageVariantRecord>[],
        isEmpty,
        reason: '普通发送轮不产生变体行',
      );

      // 编辑重发：旧版先快照为变体（controller 删除阶段行为）
      await service.snapshotMessageVariant(
        sessionId: r.sessionId,
        turnNumber: 1,
        content: '旧版正文',
        sourceInput: '旧指令',
      );

      // 新一轮 persistRound（同轮号）：新内容自动记为变体并移指针
      await service.persistRound(
        userMessage: r.userMsg.copyWith(messageId: 'u2', content: '改写后的指令'),
        assistantMessage: r.assistantMsg.copyWith(
          messageId: 'a2',
          content: '新版正文',
        ),
        eventSummary: r.summary,
        embedding: null,
        artifacts: artifactsFor(1, '新版正文'),
        variantSourceInput: '改写后的指令',
      );

      variants = await service.loadMessageVariants(r.sessionId);
      final turnVariants = variants[1] ?? const <MessageVariantRecord>[];
      expect(turnVariants.length, 2, reason: '旧版快照 + 新版');
      expect(turnVariants.last.content, '新版正文');
      expect(turnVariants.last.sourceInput, '改写后的指令');

      // 指针指向最新变体（切换器渲染条件：变体 >1 且指针非 null）
      final row = await db.customSelect(
        'SELECT current_variant_index FROM intermediate_round_artifacts '
        'WHERE session_id = ? AND turn_number = ?',
        variables: [
          Variable.withString(r.sessionId),
          Variable.withInt(1),
        ],
      ).get();
      expect(row.first.readNullable<int>('current_variant_index'), 1);
    });

    test('2. embedding 非空：has_embedding=true，向量可读', () async {
      final r = await setupRound();
      final embedding = Float32List.fromList([0.1, 0.2, 0.3, 0.4]);

      final memory = (await service.persistRound(
        userMessage: r.userMsg,
        assistantMessage: r.assistantMsg,
        eventSummary: r.summary,
        embedding: embedding,
        artifacts: null,
      ))
          .memory;

      expect(memory.hasEmbedding, isFalse); // appendExperience 先写 false

      // Vector 检索能命中（embedding 已通过 updateEmbedding 写入）
      final queryVec = Float32List.fromList([0.1, 0.2, 0.3, 0.4]);
      final scored = await expRepo.searchExperiences(
        sessionId: r.sessionId,
        query: '完全不相关',
        queryVector: queryVec,
        topK: 5,
        fts5Weight: 0,
        vectorWeight: 1,
        keyEventThreshold: 4,
        keyEventBoost: 1.5,
        normalizationEpsilon: 0.01,
      );
      expect(scored.length, 1);
      expect(scored.first.vectorScore, greaterThan(0));
    });

    test('3. embedding=null 降级：has_embedding=false，事务仍提交', () async {
      final r = await setupRound();

      final memory = (await service.persistRound(
        userMessage: r.userMsg,
        assistantMessage: r.assistantMsg,
        eventSummary: r.summary,
        embedding: null,
        artifacts: null,
      ))
          .memory;

      expect(memory.hasEmbedding, isFalse);
      // 事务仍提交：消息已写入
      final messages = await chatRepo.getMessages(r.sessionId);
      expect(messages.length, 2);
    });

    test('4. 事务回滚：appendExperience 抛异常 -> chat_messages 无残留', () async {
      final r = await setupRound();

      // 注入会抛异常的 fake ExperienceRepository
      final failingService = StoryPersistenceServiceImpl(
        database: db,
        chatRepository: chatRepo,
        experienceRepository: _FailingExperienceRepository(),
      );

      expect(
        () => failingService.persistRound(
          userMessage: r.userMsg,
          assistantMessage: r.assistantMsg,
          eventSummary: r.summary,
          embedding: null,
          artifacts: null,
        ),
        throwsA(isA<Exception>()),
      );

      // 等待异常后验证回滚
      await Future<void>.delayed(Duration.zero);
      final messages = await chatRepo.getMessages(r.sessionId);
      expect(messages, isEmpty); // 事务回滚，无残留
    });

    test('5. FTS 索引同步：persistRound 后 searchExperiences 命中', () async {
      final r = await setupRound();

      await service.persistRound(
        userMessage: r.userMsg,
        assistantMessage: r.assistantMsg,
        eventSummary: r.summary,
        embedding: null,
        artifacts: null,
      );

      // 用事件摘要中的关键词检索（trigram 要求 ≥3 字符）
      final scored = await expRepo.searchExperiences(
        sessionId: r.sessionId,
        query: '发现古碑',
        queryVector: null,
        topK: 5,
        fts5Weight: 0.5,
        vectorWeight: 0.5,
        keyEventThreshold: 4,
        keyEventBoost: 1.5,
        normalizationEpsilon: 0.01,
      );
      expect(scored.length, 1);
      expect(scored.first.memory.summary, '勇者发现古碑');
    });

    test('6. updateSessionMessageCount：同一会话累加 +2', () async {
      final r = await setupRound();

      final before = await chatRepo.getSession(r.sessionId);
      expect(before.messageCount, 0);

      // 第一轮：messageCount 0 -> 2
      await service.persistRound(
        userMessage: r.userMsg,
        assistantMessage: r.assistantMsg,
        eventSummary: r.summary,
        embedding: null,
        artifacts: null,
      );

      final after1 = await chatRepo.getSession(r.sessionId);
      expect(after1.messageCount, 2);

      // 第二轮（同一会话）：messageCount 2 -> 4
      final now = DateTime(2026);
      final userMsg2 = ChatMessage(
        messageId: 'u2',
        sessionId: r.sessionId,
        role: 'user',
        content: '继续探索',
        createdAt: now,
      );
      final assistantMsg2 = ChatMessage(
        messageId: 'a2',
        sessionId: r.sessionId,
        role: 'assistant',
        content: '勇者继续前行。',
        createdAt: now,
      );
      const summary2 = EventSummary(
        summary: '勇者继续探索',
        importance: 2,
        tags: ['探索'],
        turnNumber: 2,
      );
      await service.persistRound(
        userMessage: userMsg2,
        assistantMessage: assistantMsg2,
        eventSummary: summary2,
        embedding: null,
        artifacts: null,
      );

      final after2 = await chatRepo.getSession(r.sessionId);
      expect(after2.messageCount, 4);
    });
  });

  group('persistRegeneratedRound', () {
    test('7. 成功：写 assistant+记忆+FTS，session count +1', () async {
      final r = await setupRound();
      // 先写入 user 消息（模拟重生场景：user_N 已存在）
      await chatRepo.addMessage(r.userMsg);
      await chatRepo.updateSessionMessageCount(r.sessionId, 1);

      final newAssistant = ChatMessage(
        messageId: 'a_regen',
        sessionId: r.sessionId,
        role: 'assistant',
        content: '勇者重新审视古碑，发现新线索。',
        createdAt: DateTime(2026),
      );

      final memory = (await service.persistRegeneratedRound(
        assistantMessage: newAssistant,
        eventSummary: r.summary,
        embedding: null,
        artifacts: null,
      ))
          .memory;

      // chat_messages: u1 + a_regen = 2 条
      final messages = await chatRepo.getMessages(r.sessionId);
      expect(messages.length, 2);
      expect(messages[0].role, 'user');
      expect(messages[1].messageId, 'a_regen');

      // 记忆 1 条
      expect(memory.memoryId, isNotEmpty);
      expect(memory.turnNumber, 1);

      // FTS 可检索
      final scored = await expRepo.searchExperiences(
        sessionId: r.sessionId,
        query: '勇者发现',
        queryVector: null,
        topK: 5,
        fts5Weight: 0.5,
        vectorWeight: 0.5,
        keyEventThreshold: 4,
        keyEventBoost: 1.5,
        normalizationEpsilon: 0.01,
      );
      expect(scored.length, 1);

      // session messageCount = 2（u1 + a_regen）
      final session = await chatRepo.getSession(r.sessionId);
      expect(session.messageCount, 2);
    });

    test('8. embedding=null 降级：has_embedding=false，事务仍提交', () async {
      final r = await setupRound();
      await chatRepo.addMessage(r.userMsg);
      await chatRepo.updateSessionMessageCount(r.sessionId, 1);

      final memory = (await service.persistRegeneratedRound(
        assistantMessage: r.assistantMsg,
        eventSummary: r.summary,
        embedding: null,
        artifacts: null,
      ))
          .memory;

      expect(memory.hasEmbedding, isFalse);
      final messages = await chatRepo.getMessages(r.sessionId);
      expect(messages.length, 2);
    });

    test('9. 事务回滚：appendExperience 抛异常 -> chat_messages 无残留', () async {
      final r = await setupRound();
      await chatRepo.addMessage(r.userMsg);
      await chatRepo.updateSessionMessageCount(r.sessionId, 1);

      final failingService = StoryPersistenceServiceImpl(
        database: db,
        chatRepository: chatRepo,
        experienceRepository: _FailingExperienceRepository(),
      );

      expect(
        () => failingService.persistRegeneratedRound(
          assistantMessage: r.assistantMsg,
          eventSummary: r.summary,
          embedding: null,
          artifacts: null,
        ),
        throwsA(isA<Exception>()),
      );

      await Future<void>.delayed(Duration.zero);
      // 事务回滚：assistant 消息未写入（只有之前的 user 消息）
      final messages = await chatRepo.getMessages(r.sessionId);
      expect(messages.length, 1);
      expect(messages[0].role, 'user');
    });
  });

  group('persistConsolidatedMemories', () {
    const records = [
      ConsolidatedMemoryRecord(
        summary: 'Unwanted synthesis',
        tags: [],
        importance: 4,
        turnNumber: 2,
      ),
    ];

    test('源经历的标签改变后丢弃整批提炼', () async {
      final r = await setupRound();
      final sources = await seedConsolidationSources(r.sessionId);
      final firstId = sources.first.memoryId;
      await expRepo.updateExperience(
        memoryId: firstId,
        sessionId: r.sessionId,
        tags: const ['revised'],
      );

      final persisted = await service.persistConsolidatedMemories(
        sessionId: r.sessionId,
        records: records,
        originalMemories: sources,
      );

      final remaining = await expRepo.getAllExperiences(r.sessionId);
      final indexed = await db.customSelect(
        'SELECT summary FROM memories_fts WHERE session_id = ?',
        variables: [Variable.withString(r.sessionId)],
      ).get();
      expect(
        [
          remaining.map((memory) => memory.summary).toList(),
          indexed.map((row) => row.read<String>('summary')).toList(),
        ],
        [
          unorderedEquals(['Source 1', 'Source 2']),
          isEmpty,
        ],
      );
      expect(
        remaining.singleWhere((memory) => memory.memoryId == firstId).tags,
        ['revised'],
      );
      expect(persisted, isFalse);
    });

    test('源经历已被索引时保留源经历和已有全文索引', () async {
      final r = await setupRound();
      final sources = await seedConsolidationSources(r.sessionId);
      final source = sources.first;
      await expRepo.insertFtsIndex(
        memoryId: source.memoryId,
        sessionId: r.sessionId,
        summary: source.summary,
      );

      final persisted = await service.persistConsolidatedMemories(
        sessionId: r.sessionId,
        records: records,
        originalMemories: sources,
      );

      expect(persisted, isFalse);
      final remaining = await expRepo.getAllExperiences(r.sessionId);
      expect(
        remaining.map((memory) => memory.memoryId),
        unorderedEquals(sources.map((memory) => memory.memoryId)),
      );
      final indexed = await db.customSelect(
        'SELECT memory_id FROM memories_fts WHERE session_id = ?',
        variables: [Variable.withString(r.sessionId)],
      ).get();
      expect(indexed.single.read<String>('memory_id'), source.memoryId);
    });
  });

  group('deleteRoundAndDownstream', () {
    test('10. 成功：删消息+记忆+FTS+session count 正确', () async {
      final r = await setupRound();
      // 写入 2 轮
      await service.persistRound(
        userMessage: r.userMsg,
        assistantMessage: r.assistantMsg,
        eventSummary: r.summary,
        embedding: null,
        artifacts: null,
      );
      final userMsg2 = ChatMessage(
        messageId: 'u2',
        sessionId: r.sessionId,
        role: 'user',
        content: '继续探索',
        createdAt: DateTime(2026),
      );
      final assistantMsg2 = ChatMessage(
        messageId: 'a2',
        sessionId: r.sessionId,
        role: 'assistant',
        content: '勇者继续前行。',
        createdAt: DateTime(2026),
      );
      const summary2 = EventSummary(
        summary: '勇者继续探索',
        importance: 2,
        tags: ['探索'],
        turnNumber: 2,
      );
      await service.persistRound(
        userMessage: userMsg2,
        assistantMessage: assistantMsg2,
        eventSummary: summary2,
        embedding: null,
        artifacts: null,
      );

      // 删除第 2 轮及下游（这里只有第 2 轮）
      await service.deleteRoundAndDownstream(
        sessionId: r.sessionId,
        fromTurnNumber: 2,
        messageIdsToDelete: ['u2', 'a2'],
      );

      // chat_messages: 剩 u1, a1 = 2 条
      final messages = await chatRepo.getMessages(r.sessionId);
      expect(messages.length, 2);
      expect(messages[0].messageId, 'u1');
      expect(messages[1].messageId, 'a1');

      // 记忆：剩 turn 1
      final recent = await expRepo.getRecentExperiences(r.sessionId, limit: 10);
      expect(recent.length, 1);
      expect(recent.first.turnNumber, 1);

      // FTS turn 2 搜不到
      final fts2 = await expRepo.searchExperiences(
        sessionId: r.sessionId,
        query: '勇者继续',
        queryVector: null,
        topK: 5,
        fts5Weight: 0.5,
        vectorWeight: 0.5,
        keyEventThreshold: 4,
        keyEventBoost: 1.5,
        normalizationEpsilon: 0.01,
      );
      expect(fts2, isEmpty);

      // session messageCount = 2
      final session = await chatRepo.getSession(r.sessionId);
      expect(session.messageCount, 2);
    });

    test('11. 空 messageIdsToDelete 不报错', () async {
      final r = await setupRound();
      await service.persistRound(
        userMessage: r.userMsg,
        assistantMessage: r.assistantMsg,
        eventSummary: r.summary,
        embedding: null,
        artifacts: null,
      );

      // fromTurnNumber 超过最大轮次 + 空 messageIdsToDelete
      await service.deleteRoundAndDownstream(
        sessionId: r.sessionId,
        fromTurnNumber: 99,
        messageIdsToDelete: const [],
      );

      // 数据不变
      final messages = await chatRepo.getMessages(r.sessionId);
      expect(messages.length, 2);
      final session = await chatRepo.getSession(r.sessionId);
      expect(session.messageCount, 2);
    });

    test('12. 事务回滚：deleteExperienceByTurns 抛异常 -> 消息和记忆未删', () async {
      final r = await setupRound();
      await service.persistRound(
        userMessage: r.userMsg,
        assistantMessage: r.assistantMsg,
        eventSummary: r.summary,
        embedding: null,
        artifacts: null,
      );

      final failingService = StoryPersistenceServiceImpl(
        database: db,
        chatRepository: chatRepo,
        experienceRepository: _FailingExperienceRepository(),
      );

      expect(
        () => failingService.deleteRoundAndDownstream(
          sessionId: r.sessionId,
          fromTurnNumber: 1,
          messageIdsToDelete: ['u1', 'a1'],
        ),
        throwsA(isA<Exception>()),
      );

      await Future<void>.delayed(Duration.zero);
      // 事务回滚：消息和记忆都未删
      final messages = await chatRepo.getMessages(r.sessionId);
      expect(messages.length, 2);
      final recent = await expRepo.getRecentExperiences(r.sessionId, limit: 10);
      expect(recent.length, 1);
    });

    test('12. 事实层启用时 deleteRoundAndDownstream 调用 deleteFactsByTurns', () async {
      final r = await setupRound();
      // 写入 1 轮
      await service.persistRound(
        userMessage: r.userMsg,
        assistantMessage: r.assistantMsg,
        eventSummary: r.summary,
        embedding: null,
        artifacts: null,
      );

      // 用带 FactApplier 的 service 删除
      final fakeRepo = FakeFactualRepository();
      final applier = FactApplier(repository: fakeRepo);
      final serviceWithFacts = StoryPersistenceServiceImpl(
        database: db,
        chatRepository: chatRepo,
        experienceRepository: expRepo,
        factApplier: applier,
      );

      await serviceWithFacts.deleteRoundAndDownstream(
        sessionId: r.sessionId,
        fromTurnNumber: 1,
        messageIdsToDelete: ['u1', 'a1'],
      );

      expect(fakeRepo.deletedFactsByTurnsCalls, hasLength(1));
      expect(fakeRepo.deletedFactsByTurnsCalls.first.sessionId, r.sessionId);
      expect(fakeRepo.deletedFactsByTurnsCalls.first.fromTurn, 1);
    });

    test('12b. 事实层禁用时 deleteRoundAndDownstream 不调用 deleteFactsByTurns',
        () async {
      final r = await setupRound();
      await service.persistRound(
        userMessage: r.userMsg,
        assistantMessage: r.assistantMsg,
        eventSummary: r.summary,
        embedding: null,
        artifacts: null,
      );

      // service 无 factApplier（默认 null）
      await service.deleteRoundAndDownstream(
        sessionId: r.sessionId,
        fromTurnNumber: 1,
        messageIdsToDelete: ['u1', 'a1'],
      );

      // 不抛异常即通过--_factApplier 为 null 时安全跳过
      final messages = await chatRepo.getMessages(r.sessionId);
      expect(messages, isEmpty);
    });
  });

  ///  新增：中间产物（artifacts）持久化测试
  ///
  /// 验证 persistRound/persistRegeneratedRound 在事务中追加 INSERT、
  /// loadArtifactsBySession 批量加载、deleteRoundAndDownstream 同步删除。
  /// 修复"草稿和检索过程在消息生成完后消失"问题（DOC-09A-1 §1.5）。
  group('artifacts persistence (P2.7)', () {
    test('13. persistRound 后 loadArtifactsBySession 返回 1 条记录，字段完整匹配', () async {
      final r = await setupRound();

      final createdAt = DateTime(2026, 7, 4, 12, 30, 45);
      final artifacts = StoryRoundArtifacts(
        sessionId: r.sessionId,
        turnNumber: 1,
        generatedText: '勇者穿过密林，发现一座古碑。',
        extractedKeywords: const ['密林', '古碑', '探索'],
        retrievedMemories: [
          ExperientialMemory(
            memoryId: 'm1',
            sessionId: r.sessionId,
            summary: '之前的探索经历',
            importance: 2,
            tags: const ['探索'],
            turnNumber: 0,
            createdAt: DateTime(2025, 12, 31),
          ),
        ],
        reviewExecuted: true,
        createdAt: createdAt,
      );

      await service.persistRound(
        userMessage: r.userMsg,
        assistantMessage: r.assistantMsg,
        eventSummary: r.summary,
        embedding: null,
        artifacts: artifacts,
      );

      final loaded = await service.loadArtifactsBySession(r.sessionId);
      expect(loaded.length, 1);
      expect(loaded.containsKey(1), isTrue);

      final a = loaded[1]!;
      expect(a.sessionId, r.sessionId);
      expect(a.turnNumber, 1);
      expect(a.generatedText, '勇者穿过密林，发现一座古碑。');
      expect(a.extractedKeywords, ['密林', '古碑', '探索']);
      expect(a.retrievedMemories.length, 1);
      expect(a.retrievedMemories.first.memoryId, 'm1');
      expect(a.retrievedMemories.first.summary, '之前的探索经历');
      expect(a.retrievedMemories.first.importance, 2);
      expect(a.retrievedMemories.first.tags, ['探索']);
      expect(a.retrievedMemories.first.turnNumber, 0);
      expect(a.reviewExecuted, isTrue);
      // createdAt 经 int 往返，毫秒精度
      expect(
        a.createdAt.millisecondsSinceEpoch,
        createdAt.millisecondsSinceEpoch,
      );
    });

    test('14. persistRound artifacts=null -> 不写 artifacts 表', () async {
      final r = await setupRound();

      await service.persistRound(
        userMessage: r.userMsg,
        assistantMessage: r.assistantMsg,
        eventSummary: r.summary,
        embedding: null,
        artifacts: null,
      );

      final loaded = await service.loadArtifactsBySession(r.sessionId);
      expect(loaded, isEmpty);
    });

    test('15. persistRegeneratedRound 后 loadArtifactsBySession 返回 1 条记录',
        () async {
      final r = await setupRound();
      // 先写入 user 消息（模拟重生场景）
      await chatRepo.addMessage(r.userMsg);
      await chatRepo.updateSessionMessageCount(r.sessionId, 1);

      final newAssistant = ChatMessage(
        messageId: 'a_regen',
        sessionId: r.sessionId,
        role: 'assistant',
        content: '勇者重新审视古碑，发现新线索。',
        createdAt: DateTime(2026),
      );

      final artifacts = StoryRoundArtifacts(
        sessionId: r.sessionId,
        turnNumber: 1,
        generatedText: '勇者重新审视古碑。',
        extractedKeywords: const ['古碑', '线索'],
        createdAt: DateTime(2026),
      );

      await service.persistRegeneratedRound(
        assistantMessage: newAssistant,
        eventSummary: r.summary,
        embedding: null,
        artifacts: artifacts,
      );

      final loaded = await service.loadArtifactsBySession(r.sessionId);
      expect(loaded.length, 1);
      expect(loaded[1]!.generatedText, '勇者重新审视古碑。');
      expect(loaded[1]!.extractedKeywords, ['古碑', '线索']);
      expect(loaded[1]!.retrievedMemories, isEmpty);
    });

    test(
        '16. deleteRoundAndDownstream 后 artifacts 同步删除（turn >= fromTurnNumber）',
        () async {
      final r = await setupRound();

      // 写入 2 轮，每轮都附 artifacts
      final artifacts1 = StoryRoundArtifacts(
        sessionId: r.sessionId,
        turnNumber: 1,
        generatedText: '第 1 轮草稿',
        extractedKeywords: const ['关键词1'],
        createdAt: DateTime(2026),
      );
      await service.persistRound(
        userMessage: r.userMsg,
        assistantMessage: r.assistantMsg,
        eventSummary: r.summary,
        embedding: null,
        artifacts: artifacts1,
      );

      final userMsg2 = ChatMessage(
        messageId: 'u2',
        sessionId: r.sessionId,
        role: 'user',
        content: '继续探索',
        createdAt: DateTime(2026),
      );
      final assistantMsg2 = ChatMessage(
        messageId: 'a2',
        sessionId: r.sessionId,
        role: 'assistant',
        content: '勇者继续前行。',
        createdAt: DateTime(2026),
      );
      const summary2 = EventSummary(
        summary: '勇者继续探索',
        importance: 2,
        tags: ['探索'],
        turnNumber: 2,
      );
      final artifacts2 = StoryRoundArtifacts(
        sessionId: r.sessionId,
        turnNumber: 2,
        generatedText: '第 2 轮草稿',
        extractedKeywords: const ['关键词2'],
        createdAt: DateTime(2026),
      );
      await service.persistRound(
        userMessage: userMsg2,
        assistantMessage: assistantMsg2,
        eventSummary: summary2,
        embedding: null,
        artifacts: artifacts2,
      );

      // 删除第 2 轮及下游
      await service.deleteRoundAndDownstream(
        sessionId: r.sessionId,
        fromTurnNumber: 2,
        messageIdsToDelete: ['u2', 'a2'],
      );

      // artifacts 表：turn 2 已删，turn 1 保留
      final loaded = await service.loadArtifactsBySession(r.sessionId);
      expect(loaded.length, 1);
      expect(loaded.containsKey(1), isTrue);
      expect(loaded.containsKey(2), isFalse);
      expect(loaded[1]!.generatedText, '第 1 轮草稿');
    });

    test(
        '17. deleteRoundAndDownstream fromTurnNumber=N 仅删 turn >= N，turn < N 保留',
        () async {
      final r = await setupRound();

      // 写入 3 轮 artifacts
      for (var i = 1; i <= 3; i++) {
        final userMsg = ChatMessage(
          messageId: 'u$i',
          sessionId: r.sessionId,
          role: 'user',
          content: '第 $i 轮',
          createdAt: DateTime(2026),
        );
        final assistantMsg = ChatMessage(
          messageId: 'a$i',
          sessionId: r.sessionId,
          role: 'assistant',
          content: '第 $i 轮回复',
          createdAt: DateTime(2026),
        );
        final summary = EventSummary(
          summary: '第 $i 轮事件',
          importance: 2,
          tags: const ['探索'],
          turnNumber: i,
        );
        final artifacts = StoryRoundArtifacts(
          sessionId: r.sessionId,
          turnNumber: i,
          generatedText: '第 $i 轮草稿',
          extractedKeywords: ['kw$i'],
          createdAt: DateTime(2026),
        );
        await service.persistRound(
          userMessage: userMsg,
          assistantMessage: assistantMsg,
          eventSummary: summary,
          embedding: null,
          artifacts: artifacts,
        );
      }

      // 删除 turn >= 2
      await service.deleteRoundAndDownstream(
        sessionId: r.sessionId,
        fromTurnNumber: 2,
        messageIdsToDelete: const ['u2', 'a2', 'u3', 'a3'],
      );

      final loaded = await service.loadArtifactsBySession(r.sessionId);
      expect(loaded.length, 1);
      expect(loaded.containsKey(1), isTrue);
      expect(loaded.containsKey(2), isFalse);
      expect(loaded.containsKey(3), isFalse);
      expect(loaded[1]!.generatedText, '第 1 轮草稿');
    });

    test('17b. 剧情锚回拨：删 turn>=N 后锚回到 N-1 轮轮末锚（对称回滚）', () async {
      final r = await setupRound();

      const anchor1 = StoryAnchor(
        updatedTurn: 1,
        arc: '古碑之谜',
        foreshadows: [AnchorForeshadow(text: '碑文残缺的一角')],
      );
      const anchor2 = StoryAnchor(
        updatedTurn: 2,
        arc: '下山之路',
        foreshadows: [AnchorForeshadow(text: '碑文残缺的一角')],
      );
      await persistRoundWithAnchor(r, 1, anchor1);
      await persistRoundWithAnchor(r, 2, anchor2);

      // 删前：会话锚 = 第 2 轮轮末锚
      expect((await chatRepo.getSession(r.sessionId)).storyAnchor?.arc, '下山之路');

      final restored = await service.deleteRoundAndDownstream(
        sessionId: r.sessionId,
        fromTurnNumber: 2,
        messageIdsToDelete: const ['u2', 'a2'],
      );

      // 返回值 + DB 均回到第 1 轮轮末锚（同事务内回拨）
      expect(restored?.arc, '古碑之谜');
      expect(restored?.updatedTurn, 1);
      expect(
        (await chatRepo.getSession(r.sessionId)).storyAnchor?.arc,
        '古碑之谜',
      );
    });

    test('17c. 剧情锚回拨：第一轮即删 → 回到未设锚（NULL，不读已删轮）', () async {
      final r = await setupRound();

      await persistRoundWithAnchor(
        r,
        1,
        const StoryAnchor(
          updatedTurn: 1,
          arc: '被删稿的弧线',
          foreshadows: [AnchorForeshadow(text: '不该复活的人物')],
        ),
      );
      expect(
        (await chatRepo.getSession(r.sessionId)).storyAnchor?.arc,
        '被删稿的弧线',
      );

      final restored = await service.deleteRoundAndDownstream(
        sessionId: r.sessionId,
        fromTurnNumber: 1,
        messageIdsToDelete: const ['u1', 'a1'],
      );

      // 第一轮前无任何存活 artifacts → null（未设锚），DB 同步置 NULL
      expect(restored, isNull);
      expect((await chatRepo.getSession(r.sessionId)).storyAnchor, isNull);
    });

    test('17d. 剧情锚回拨：存活 artifacts 均无锚 → 保持未设锚', () async {
      final r = await setupRound();
      await persistRoundWithAnchor(r, 1, null);
      await persistRoundWithAnchor(r, 2, null);

      final restored = await service.deleteRoundAndDownstream(
        sessionId: r.sessionId,
        fromTurnNumber: 2,
        messageIdsToDelete: const ['u2', 'a2'],
      );

      expect(restored, isNull);
      expect((await chatRepo.getSession(r.sessionId)).storyAnchor, isNull);
    });
  });

  ///  新增：importance 门槛与条件 FTS5 索引测试
  ///
  /// 验证 indexForRetrieval=false 时：
  /// - 记忆仍写入 experiential_memories（保留原始记录供后续批量提炼）
  /// - 不建立 FTS5 索引（searchExperiences 搜不到）
  /// - 消息正常写入 chat_messages（不受影响）
  /// - 会话元数据正常更新（不受影响）
  ///
  /// 设计文档：DOC-09A-1 §3.7（修订）、DOC-09C §1（持久化时序）。
  group('B4-4 indexForRetrieval (importance threshold)', () {
    test('18. persistRound indexForRetrieval=false：记忆写入但 FTS5 不可检索', () async {
      final r = await setupRound();

      final memory = (await service.persistRound(
        userMessage: r.userMsg,
        assistantMessage: r.assistantMsg,
        eventSummary: r.summary,
        embedding: null,
        artifacts: null,
        indexForRetrieval: false,
      ))
          .memory;

      // 记忆仍写入 experiential_memories
      expect(memory.memoryId, isNotEmpty);
      expect(memory.summary, '勇者发现古碑');
      expect(memory.importance, 3);

      // 消息正常写入
      final messages = await chatRepo.getMessages(r.sessionId);
      expect(messages.length, 2);

      // FTS5 不可检索（未建索引）
      final scored = await expRepo.searchExperiences(
        sessionId: r.sessionId,
        query: '发现古碑',
        queryVector: null,
        topK: 5,
        fts5Weight: 0.5,
        vectorWeight: 0.5,
        keyEventThreshold: 4,
        keyEventBoost: 1.5,
        normalizationEpsilon: 0.01,
      );
      expect(scored, isEmpty);

      // getRecentExperiences 仍可读到（记忆确实存在，只是不可检索）
      final recent = await expRepo.getRecentExperiences(r.sessionId, limit: 10);
      expect(recent.length, 1);
      expect(recent.first.memoryId, memory.memoryId);

      // 会话元数据正常更新
      final session = await chatRepo.getSession(r.sessionId);
      expect(session.messageCount, 2);
    });

    test('19. persistRegeneratedRound indexForRetrieval=false：记忆写入但 FTS5 不可检索',
        () async {
      final r = await setupRound();
      // 先写入 user 消息（模拟重生场景）
      await chatRepo.addMessage(r.userMsg);
      await chatRepo.updateSessionMessageCount(r.sessionId, 1);

      final newAssistant = ChatMessage(
        messageId: 'a_regen_low',
        sessionId: r.sessionId,
        role: 'assistant',
        content: '勇者低头不语。',
        createdAt: DateTime(2026),
      );

      final memory = (await service.persistRegeneratedRound(
        assistantMessage: newAssistant,
        eventSummary: r.summary,
        embedding: null,
        artifacts: null,
        indexForRetrieval: false,
      ))
          .memory;

      // 记忆仍写入
      expect(memory.memoryId, isNotEmpty);

      // FTS5 不可检索
      final scored = await expRepo.searchExperiences(
        sessionId: r.sessionId,
        query: '勇者发现',
        queryVector: null,
        topK: 5,
        fts5Weight: 0.5,
        vectorWeight: 0.5,
        keyEventThreshold: 4,
        keyEventBoost: 1.5,
        normalizationEpsilon: 0.01,
      );
      expect(scored, isEmpty);

      // getRecentExperiences 仍可读到
      final recent = await expRepo.getRecentExperiences(r.sessionId, limit: 10);
      expect(recent.length, 1);
    });

    test('20. indexForRetrieval=false 不影响同会话其他高 importance 记忆的检索', () async {
      final r = await setupRound();

      // 第 1 轮：低 importance，不建索引
      await service.persistRound(
        userMessage: r.userMsg,
        assistantMessage: r.assistantMsg,
        eventSummary: r.summary,
        embedding: null,
        artifacts: null,
        indexForRetrieval: false,
      );

      // 第 2 轮：高 importance，建索引
      final userMsg2 = ChatMessage(
        messageId: 'u2',
        sessionId: r.sessionId,
        role: 'user',
        content: '勇者与巨龙战斗',
        createdAt: DateTime(2026),
      );
      final assistantMsg2 = ChatMessage(
        messageId: 'a2',
        sessionId: r.sessionId,
        role: 'assistant',
        content: '勇者挥剑斩龙。',
        createdAt: DateTime(2026),
      );
      const summary2 = EventSummary(
        summary: '勇者斩杀巨龙',
        importance: 5,
        tags: ['战斗', '巨龙'],
        turnNumber: 2,
      );
      await service.persistRound(
        userMessage: userMsg2,
        assistantMessage: assistantMsg2,
        eventSummary: summary2,
        embedding: null,
        artifacts: null,
      );

      // 搜索"勇者斩"（trigram 要求 ≥3 字符）：只命中第 2 轮（第 1 轮未建索引）
      final scored = await expRepo.searchExperiences(
        sessionId: r.sessionId,
        query: '勇者斩',
        queryVector: null,
        topK: 5,
        fts5Weight: 0.5,
        vectorWeight: 0.5,
        keyEventThreshold: 4,
        keyEventBoost: 1.5,
        normalizationEpsilon: 0.01,
      );
      expect(scored.length, 1);
      expect(scored.first.memory.summary, '勇者斩杀巨龙');

      // getRecentExperiences 能读到两条（都在 experiential_memories 中）
      final recent = await expRepo.getRecentExperiences(r.sessionId, limit: 10);
      expect(recent.length, 2);
    });
  });

  group('persistManualCompaction（上下文用量指示 T9）', () {
    test('单事务：摘要消息+压缩点+宏摘要，会话消息数 +1', () async {
      final session = await chatRepo.createSession(
        title: '手动压缩会话',
        mode: 'advanced',
      );
      final sessionId = session.sessionId;
      final now = DateTime(2026);
      await chatRepo.addMessage(
        ChatMessage(
          messageId: 'u1',
          sessionId: sessionId,
          role: 'user',
          content: '第一轮输入',
          createdAt: now,
        ),
      );
      await chatRepo.addMessage(
        ChatMessage(
          messageId: 'a1',
          sessionId: sessionId,
          role: 'assistant',
          content: '第一轮回复',
          createdAt: now,
        ),
      );
      final before = await chatRepo.getMessageCount(sessionId);

      await service.persistManualCompaction(
        compaction: CompactionPersistenceData(
          summaryMessage: ChatMessage(
            messageId: 'sum-1',
            sessionId: sessionId,
            role: 'system',
            content: '新压缩摘要',
            isSummary: true,
            createdAt: now,
          ),
          boundaryMessageId: 'a1',
          turnNumber: 1,
          segmentMacroSummary: '分段宏摘要',
        ),
      );

      // 1. 摘要消息 → chat_messages
      final messages = await chatRepo.getMessages(sessionId);
      expect(
        messages.where((m) => m.messageId == 'sum-1').length,
        1,
      );
      // 2. 压缩点映射
      final points = await chatRepo.getCompactionPoints(sessionId);
      expect(points, isNotEmpty);
      expect(points.first['boundaryMessageId'], 'a1');
      expect(points.first['summaryMessageId'], 'sum-1');
      // 3. 会话消息数（绝对值设置）= 旧值 + 摘要消息
      final after = await chatRepo.getMessageCount(sessionId);
      expect(after, before + 1);
    });
  });

  group('undoCompaction（2026-09-04 撤销压缩）', () {
    /// 建会话（2 轮消息）→ 压缩一次（摘要 sum-N，宏摘要 turn=N）
    Future<String> setupCompactedSession({
      required String summaryId,
      required int turnNumber,
      String? segmentMacroSummary,
    }) async {
      final session = await chatRepo.createSession(
        title: '撤销压缩会话',
        mode: 'intermediate',
      );
      final sessionId = session.sessionId;
      final now = DateTime(2026);
      for (final (role, id, content) in const [
        ('user', 'u1', '第一轮输入'),
        ('assistant', 'a1', '第一轮回复'),
        ('user', 'u2', '第二轮输入'),
        ('assistant', 'a2', '第二轮回复'),
      ]) {
        await chatRepo.addMessage(
          ChatMessage(
            messageId: id,
            sessionId: sessionId,
            role: role,
            content: content,
            createdAt: now,
          ),
        );
      }
      await service.persistManualCompaction(
        compaction: CompactionPersistenceData(
          summaryMessage: ChatMessage(
            messageId: summaryId,
            sessionId: sessionId,
            role: 'system',
            content: '压缩摘要内容',
            isSummary: true,
            createdAt: now,
          ),
          boundaryMessageId: 'a1',
          turnNumber: turnNumber,
          segmentMacroSummary: segmentMacroSummary,
        ),
      );
      return sessionId;
    }

    Future<int> ftsRowCount(String sessionId) async {
      final rows = await db.customSelect(
        'SELECT COUNT(*) AS c FROM memories_fts WHERE session_id = ?',
        variables: [Variable.withString(sessionId)],
      ).get();
      return rows.first.read<int>('c');
    }

    Future<int> compactionMacroCount(String sessionId) async {
      final rows = await db.customSelect(
        'SELECT COUNT(*) AS c FROM experiential_memories '
        "WHERE session_id = ? AND memory_level = 'macro' "
        "AND macro_trigger_reason = 'compaction'",
        variables: [Variable.withString(sessionId)],
      ).get();
      return rows.first.read<int>('c');
    }

    test('回剥：删压缩点+摘要行+宏记忆与FTS，旧消息原样保留，可再撤销时幂等', () async {
      final sessionId = await setupCompactedSession(
        summaryId: 'sum-1',
        turnNumber: 1,
        segmentMacroSummary: '分段宏摘要',
      );

      // 撤销前：压缩点 1 个、摘要行在、宏记忆在
      expect(
        await chatRepo.getCompactionPoints(sessionId).then((p) => p.length),
        1,
      );
      expect(
        (await chatRepo.getMessages(sessionId))
            .where((m) => m.messageId == 'sum-1'),
        isNotEmpty,
      );
      expect(await compactionMacroCount(sessionId), 1);
      expect(await ftsRowCount(sessionId), greaterThanOrEqualTo(1));

      expect(await service.undoCompaction(sessionId: sessionId), isTrue);

      // 撤销后：压缩点清空、摘要行删除、宏记忆与 FTS 同步清理
      expect(await chatRepo.getCompactionPoints(sessionId), isEmpty);
      final messages = await chatRepo.getMessages(sessionId);
      expect(messages.where((m) => m.messageId == 'sum-1'), isEmpty);
      // 旧对话原样保留（压缩从不删旧消息，撤销后自然全量可见）
      expect(
        messages.map((m) => m.messageId),
        containsAll(['u1', 'a1', 'u2', 'a2']),
      );
      expect(await compactionMacroCount(sessionId), 0);
      expect(await ftsRowCount(sessionId), 0);

      // 再次撤销：无压缩点，幂等返回 false
      expect(await service.undoCompaction(sessionId: sessionId), isFalse);
    });

    test('多次压缩逐次回剥：撤销最新后上一压缩点重新生效', () async {
      final session = await chatRepo.createSession(
        title: '双重压缩会话',
        mode: 'intermediate',
      );
      final sessionId = session.sessionId;
      final now = DateTime(2026);
      for (final (role, id) in const [
        ('user', 'u1'),
        ('assistant', 'a1'),
        ('user', 'u2'),
        ('assistant', 'a2'),
      ]) {
        await chatRepo.addMessage(
          ChatMessage(
            messageId: id,
            sessionId: sessionId,
            role: role,
            content: '$role 内容',
            createdAt: now,
          ),
        );
      }
      // 第一次压缩（boundary a1）
      await service.persistManualCompaction(
        compaction: CompactionPersistenceData(
          summaryMessage: ChatMessage(
            messageId: 'sum-1',
            sessionId: sessionId,
            role: 'system',
            content: '第一次摘要',
            isSummary: true,
            createdAt: now,
          ),
          boundaryMessageId: 'a1',
          turnNumber: 1,
          segmentMacroSummary: '宏摘要一',
        ),
      );
      // 第二次压缩（boundary a2，摘要 sum-2 由新消息而非旧摘要替代）
      await service.persistManualCompaction(
        compaction: CompactionPersistenceData(
          summaryMessage: ChatMessage(
            messageId: 'sum-2',
            sessionId: sessionId,
            role: 'system',
            content: '第二次摘要',
            isSummary: true,
            createdAt: now,
          ),
          boundaryMessageId: 'a2',
          turnNumber: 2,
          segmentMacroSummary: '宏摘要二',
        ),
      );
      expect(
        await chatRepo.getCompactionPoints(sessionId).then((p) => p.length),
        2,
      );

      // 撤销最新：只删 sum-2 相关，sum-1 压缩点重新生效
      expect(await service.undoCompaction(sessionId: sessionId), isTrue);
      final points = await chatRepo.getCompactionPoints(sessionId);
      expect(points.length, 1);
      expect(points.single['summaryMessageId'], 'sum-1');
      final messages = await chatRepo.getMessages(sessionId);
      expect(messages.map((m) => m.messageId), contains('sum-1'));
      expect(messages.map((m) => m.messageId), isNot(contains('sum-2')));
      // 只回剥最新一条宏摘要（turn=2），上一条保留
      expect(await compactionMacroCount(sessionId), 1);

      // 再撤一次回到无压缩状态
      expect(await service.undoCompaction(sessionId: sessionId), isTrue);
      expect(await chatRepo.getCompactionPoints(sessionId), isEmpty);
      expect(await compactionMacroCount(sessionId), 0);
    });
  });

  group('B1 turn 单一事实源：next_turn 计数器', () {
    Future<int?> nextTurnOf(String sessionId) async {
      final rows = await db.customSelect(
        'SELECT next_turn FROM chat_sessions WHERE session_id = ?',
        variables: [Variable.withString(sessionId)],
      ).get();
      if (rows.isEmpty) return null;
      return rows.first.readNullable<int>('next_turn');
    }

    test('persistRound：next_turn 物化为 eventSummary.turnNumber + 1', () async {
      final r = await setupRound();
      expect(
        await nextTurnOf(r.sessionId),
        isNull,
        reason: '存量会话物化前 next_turn 为 NULL',
      );

      await service.persistRound(
        userMessage: r.userMsg,
        assistantMessage: r.assistantMsg,
        eventSummary: r.summary, // turnNumber: 1
        embedding: null,
        artifacts: null,
      );

      expect(await nextTurnOf(r.sessionId), 2);
    });

    test('persistRegeneratedRound：next_turn 递增同口径', () async {
      final r = await setupRound();
      await service.persistRound(
        userMessage: r.userMsg,
        assistantMessage: r.assistantMsg,
        eventSummary: r.summary,
        embedding: null,
        artifacts: null,
      );

      const regenSummary = EventSummary(
        summary: '重生成后的记忆',
        importance: 3,
        tags: [],
        turnNumber: 1,
      );
      await service.persistRegeneratedRound(
        assistantMessage: ChatMessage(
          messageId: 'a1-regen',
          sessionId: r.sessionId,
          role: 'assistant',
          content: '重写后的回复',
          createdAt: DateTime(2026),
        ),
        eventSummary: regenSummary,
        embedding: null,
        artifacts: null,
      );

      expect(
        await nextTurnOf(r.sessionId),
        2,
        reason: '重生成覆盖同一轮，next_turn 回到 N+1',
      );
    });

    test('deleteRoundAndDownstream：next_turn 回拨为被删起始轮号', () async {
      final r = await setupRound();
      await service.persistRound(
        userMessage: r.userMsg,
        assistantMessage: r.assistantMsg,
        eventSummary: r.summary,
        embedding: null,
        artifacts: null,
      );
      expect(await nextTurnOf(r.sessionId), 2);

      await service.deleteRoundAndDownstream(
        sessionId: r.sessionId,
        fromTurnNumber: 1,
        messageIdsToDelete: const ['u1', 'a1'],
      );

      expect(await nextTurnOf(r.sessionId), 1, reason: '删除第 1 轮后下一次写入复用轮号 1');
    });

    test('persistManualCompaction：不动 next_turn', () async {
      final session = await chatRepo.createSession(
        title: '手动压缩会话',
        mode: 'advanced',
      );
      final sessionId = session.sessionId;
      final now = DateTime(2026);
      await chatRepo.addMessage(
        ChatMessage(
          messageId: 'u1',
          sessionId: sessionId,
          role: 'user',
          content: '第一轮输入',
          createdAt: now,
        ),
      );
      await service.persistManualCompaction(
        compaction: CompactionPersistenceData(
          summaryMessage: ChatMessage(
            messageId: 'sum-1',
            sessionId: sessionId,
            role: 'system',
            content: '摘要',
            isSummary: true,
            createdAt: now,
          ),
          boundaryMessageId: 'u1',
          turnNumber: 1,
        ),
      );

      expect(await nextTurnOf(sessionId), isNull, reason: '压缩不产生新轮次，计数器保持未物化');
    });
  });

  /// 宏摘要向量化（记忆补齐三批，2026-09-09）
  ///
  /// 四条压缩落库路径的宏记忆向量接线（_persistCompactionInTransaction
  /// 同事务 updateEmbedding）+ 降级不阻断 + 重建徽标不变量。
  /// 接口注释承诺：宏摘要始终建 FTS5 索引 + 向量化（此前只建 FTS）。
  group('宏摘要向量化', () {
    /// 假嵌入服务返回的定长向量（8 维）
    Float32List fakeMacroVector() =>
        Float32List.fromList([0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8]);

    /// 压缩宏记忆唯一行（memory_level=macro, trigger=compaction）
    Future<
        ({
          String memoryId,
          bool hasEmbedding,
          Uint8List? embedding,
          int? embeddingDimensions,
        })> macroMemoryRow(String sessionId) async {
      final rows = await db.customSelect(
        'SELECT memory_id, has_embedding, embedding, embedding_dimensions '
        'FROM experiential_memories WHERE session_id = ? '
        "AND memory_level = 'macro' AND macro_trigger_reason = 'compaction'",
        variables: [Variable.withString(sessionId)],
      ).get();
      expect(rows.length, 1, reason: '每次压缩恰好落一条宏记忆');
      final r = rows.single;
      return (
        memoryId: r.read<String>('memory_id'),
        hasEmbedding: r.read<bool>('has_embedding'),
        embedding: r.readNullable<Uint8List>('embedding'),
        embeddingDimensions: r.readNullable<int>('embedding_dimensions'),
      );
    }

    /// 宏记忆的 FTS 行数（memories_fts.memory_type 恒为 'experiential'，
    /// 不区分层级——按 memory_id 精确断言）
    Future<int> macroFtsCount(String memoryId) async {
      final rows = await db.customSelect(
        'SELECT COUNT(*) AS c FROM memories_fts WHERE memory_id = ?',
        variables: [Variable.withString(memoryId)],
      ).get();
      return rows.first.read<int>('c');
    }

    CompactionPersistenceData compactionData(
      String sessionId, {
      Float32List? macroEmbedding,
    }) =>
        CompactionPersistenceData(
          summaryMessage: ChatMessage(
            messageId: 'sum-c',
            sessionId: sessionId,
            role: 'system',
            content: '前情摘要',
            isSummary: true,
            createdAt: DateTime(2026),
          ),
          boundaryMessageId: 'a1',
          turnNumber: 1,
          segmentMacroSummary: '分段宏摘要：勇者已发现古碑',
          macroEmbedding: macroEmbedding,
        );

    test('C1. persistRound 自动压缩：宏 has_embedding=true，维度=8，FTS 在，语义可检索',
        () async {
      final r = await setupRound();

      await service.persistRound(
        userMessage: r.userMsg,
        assistantMessage: r.assistantMsg,
        eventSummary: r.summary,
        embedding: null,
        artifacts: null,
        compaction:
            compactionData(r.sessionId, macroEmbedding: fakeMacroVector()),
      );

      final row = await macroMemoryRow(r.sessionId);
      expect(row.hasEmbedding, isTrue);
      expect(row.embedding!.length ~/ 4, 8, reason: 'BLOB 字节数/4 = 向量维度');
      expect(row.embeddingDimensions, 8, reason: '维度列随向量落库');
      expect(await macroFtsCount(row.memoryId), 1, reason: 'FTS 行必在');

      // 兑现承诺的核心断言：纯向量通道能语义命中宏记忆
      final scored = await expRepo.searchExperiences(
        sessionId: r.sessionId,
        query: '完全不相关',
        queryVector: fakeMacroVector(),
        topK: 5,
        fts5Weight: 0,
        vectorWeight: 1,
        keyEventThreshold: 4,
        keyEventBoost: 1.5,
        normalizationEpsilon: 0.01,
      );
      expect(scored.map((s) => s.memory.memoryId), contains(row.memoryId));
    });

    test('C2. persistRegeneratedRound 自动压缩：宏 has_embedding=true，维度=8，FTS 在',
        () async {
      final r = await setupRound();
      // 重生成场景：user 消息已存在
      await chatRepo.addMessage(r.userMsg);
      await chatRepo.updateSessionMessageCount(r.sessionId, 1);

      await service.persistRegeneratedRound(
        assistantMessage: r.assistantMsg,
        eventSummary: r.summary,
        embedding: null,
        artifacts: null,
        compaction:
            compactionData(r.sessionId, macroEmbedding: fakeMacroVector()),
      );

      final row = await macroMemoryRow(r.sessionId);
      expect(row.hasEmbedding, isTrue);
      expect(row.embedding!.length ~/ 4, 8);
      expect(row.embeddingDimensions, 8);
      expect(await macroFtsCount(row.memoryId), 1);
    });

    test('C3. persistManualCompaction：宏 has_embedding=true，维度=8，FTS 在',
        () async {
      final session = await chatRepo.createSession(
        title: '手动压缩会话',
        mode: 'intermediate',
      );
      await chatRepo.addMessage(
        ChatMessage(
          messageId: 'a1',
          sessionId: session.sessionId,
          role: 'assistant',
          content: '第一轮回复',
          createdAt: DateTime(2026),
        ),
      );

      await service.persistManualCompaction(
        compaction: compactionData(
          session.sessionId,
          macroEmbedding: fakeMacroVector(),
        ),
      );

      final row = await macroMemoryRow(session.sessionId);
      expect(row.hasEmbedding, isTrue);
      expect(row.embedding!.length ~/ 4, 8);
      expect(row.embeddingDimensions, 8);
      expect(await macroFtsCount(row.memoryId), 1);
    });

    test('提炼替换原经历并写入合并记忆的向量与全文索引', () async {
      final r = await setupRound();
      final sources = await seedConsolidationSources(r.sessionId);

      final persisted = await service.persistConsolidatedMemories(
        sessionId: r.sessionId,
        records: [
          ConsolidatedMemoryRecord(
            summary: '合并后的记忆',
            tags: const ['合并'],
            importance: 5,
            turnNumber: 2,
            embedding: fakeMacroVector(),
          ),
        ],
        originalMemories: sources,
      );

      expect(persisted, isTrue);
      final remaining = await expRepo.getAllExperiences(r.sessionId);
      final synthesized = remaining.single;
      expect(synthesized.summary, '合并后的记忆');
      expect(synthesized.turnNumber, 2);
      expect(await macroFtsCount(synthesized.memoryId), 1);
      final rows = await db.customSelect(
        'SELECT has_embedding, embedding, embedding_dimensions '
        'FROM experiential_memories WHERE session_id = ? '
        "AND summary = '合并后的记忆'",
        variables: [Variable.withString(r.sessionId)],
      ).get();
      expect(rows, hasLength(1));
      expect(rows.single.read<bool>('has_embedding'), isTrue);
      expect(rows.single.read<Uint8List>('embedding').length ~/ 4, 8);
      expect(rows.single.read<int>('embedding_dimensions'), 8);
    });

    test('C5. 宏向量 null 降级：宏记忆仍落库 has_embedding=false，FTS 兜底，事务照常提交', () async {
      final r = await setupRound();

      // 不抛异常即通过（控制器侧未配置/失败时传 null）
      await service.persistRound(
        userMessage: r.userMsg,
        assistantMessage: r.assistantMsg,
        eventSummary: r.summary,
        embedding: null,
        artifacts: null,
        compaction: compactionData(r.sessionId),
      );

      final row = await macroMemoryRow(r.sessionId);
      expect(row.hasEmbedding, isFalse);
      expect(row.embedding, isNull);
      expect(await macroFtsCount(row.memoryId), 1, reason: 'FTS 兜底始终在');
      // 轮次照常成功：摘要消息 + 本轮两条消息
      final messages = await chatRepo.getMessages(r.sessionId);
      expect(messages.length, 3);
      expect(
        messages.map((m) => m.messageId),
        containsAll(['sum-c', 'u1', 'a1']),
      );
    });

    test('C6. 重建徽标不变量：宏记忆不计入待补（importance 3 < microVectorizeThreshold 4）',
        () async {
      final session = await chatRepo.createSession(
        title: '徽标口径会话',
        mode: 'intermediate',
      );
      final sessionId = session.sessionId;
      // 高重要度无向量 micro：应计入重建徽标（正确行为）
      await service.persistRound(
        userMessage: ChatMessage(
          messageId: 'u1',
          sessionId: sessionId,
          role: 'user',
          content: '勇者与巨龙战斗',
          createdAt: DateTime(2026),
        ),
        assistantMessage: ChatMessage(
          messageId: 'a1',
          sessionId: sessionId,
          role: 'assistant',
          content: '勇者斩杀巨龙。',
          createdAt: DateTime(2026),
        ),
        eventSummary: const EventSummary(
          summary: '勇者斩杀巨龙',
          importance: 5,
          tags: [],
          turnNumber: 1,
        ),
        embedding: null,
        artifacts: null,
      );
      // 手动压缩，宏向量降级（模拟未配置嵌入）——宏 importance=3
      await service.persistManualCompaction(
        compaction: compactionData(sessionId),
      );
      expect((await macroMemoryRow(sessionId)).hasEmbedding, isFalse);

      // 徽标口径（rebuildEmbeddings 同参）：只含高重要度 micro，绝不含宏
      final pending = await expRepo.getMemoriesWithoutEmbedding(
        sessionId,
        minImportance: 4,
      );
      expect(pending.map((m) => m.summary), ['勇者斩杀巨龙']);

      //  双口径（expectedDimensions 并入陈旧行）同样不含宏：
      // importance 阈值过滤先于维度判定
      final pendingStale = await expRepo.getMemoriesWithoutEmbedding(
        sessionId,
        minImportance: 4,
        expectedDimensions: 8,
      );
      expect(
        pendingStale.map((m) => m.summary),
        isNot(contains('分段宏摘要：勇者已发现古碑')),
      );
    });
  });
}

/// 抛异常的 ExperienceRepository（用于事务回滚测试）
class _FailingExperienceRepository implements ExperienceRepository {
  @override
  Future<void> setExperienceArchived(
    String memoryId, {
    required String sessionId,
    required bool archived,
  }) async {}

  @override
  Future<List<ExperientialMemory>> searchExperiencesBySubstring(
    String sessionId,
    List<String> terms, {
    int limit = 5,
    bool includeArchived = false,
  }) async =>
      const [];

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
    bool hasVerifiedSourceTurn = false,
  }) async {
    throw Exception('Simulated append failure');
  }

  @override
  Future<void> deleteAllExperiences(String sessionId) async {}

  @override
  Future<List<ExperientialMemory>> getRecentExperiences(
    String sessionId, {
    required int limit,
    bool includeArchived = false,
  }) async =>
      const [];

  @override
  Future<List<ExperientialMemory>> getUnindexedExperiences(
    String sessionId, {
    required int limit,
  }) async =>
      const [];

  @override
  Future<void> deleteExperiencesByIds({
    required String sessionId,
    required List<String> memoryIds,
  }) async {}

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
  }) async {}

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
  }) async =>
      const [];

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
  }) async =>
      const [];

  @override
  Future<void> updateEmbedding(String memoryId, Float32List embedding) async {}

  @override
  Future<void> deleteExperienceByTurns({
    required String sessionId,
    required int fromTurnNumber,
  }) async {
    throw Exception('Simulated delete failure');
  }

  @override
  Future<bool> deleteLatestCompactionMacroMemory({
    required String sessionId,
  }) async =>
      false;

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
    throw Exception('Simulated macro append failure');
  }

  @override
  Future<int?> getLastMacroTurnNumber(String sessionId) async => null;

  @override
  Future<List<ExperientialMemory>> getMicroSummariesInRange({
    required String sessionId,
    required int fromTurn,
    required int toTurn,
  }) async =>
      const [];

  @override
  Future<List<ExperientialMemory>> getMemoriesWithoutEmbedding(
    String sessionId, {
    int limit = 500,
    int? minImportance,
    int? expectedDimensions,
  }) async =>
      const [];

  @override
  Future<int?> getLatestEmbeddingDimensions(String sessionId) async => null;

  // ─── 记忆查看器 CRUD（2026-07-22 新增）───────────────────────────────

  @override
  Future<List<ExperientialMemory>> getAllExperiences(
    String sessionId, {
    bool includeArchived = true,
  }) async =>
      const [];

  @override
  Future<ExperientialMemory?> getExperienceById(String memoryId) async => null;

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
  }) async {}

  @override
  Future<void> deleteExperienceById(
    String memoryId, {
    String? sessionId,
  }) async {}
}
