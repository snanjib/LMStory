import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/vector/vector_engine.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/chat/data/repositories/chat_repository_impl.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/entities/story_anchor.dart';
import 'package:lmstory/features/chat/domain/repositories/chat_repository.dart';
import 'package:lmstory/features/memory/data/repositories/experience_repository_impl.dart';
import 'package:lmstory/features/memory/domain/entities/event_summary.dart';
import 'package:lmstory/features/memory/domain/repositories/experience_repository.dart';
import 'package:lmstory/features/story_runtime/data/persistence_service_impl.dart';
import 'package:lmstory/features/story_runtime/domain/entities/round_artifacts.dart';
import 'package:lmstory/features/story_runtime/domain/services/persistence_service.dart';

/// 稿件变体持久化语义测试
///
/// 变体按 (session, turn, index) 键快照；指针在 artifacts 行；
/// chat_messages.content 物化为当前变体（上下文组装读 content 即读指针）。
void main() {
  late AppDatabase db;
  late ChatRepository chatRepo;
  late ExperienceRepository expRepo;
  late StoryPersistenceService service;

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

  Future<String> seedRound({required String content}) async {
    final session = await chatRepo.createSession(title: '测试', mode: 'advanced');
    final sessionId = session.sessionId;
    await chatRepo.addMessage(
      ChatMessage(
        messageId: 'u1',
        sessionId: sessionId,
        role: 'user',
        content: '推进剧情',
        createdAt: DateTime(2026),
      ),
    );
    await chatRepo.addMessage(
      ChatMessage(
        messageId: 'a1',
        sessionId: sessionId,
        role: 'assistant',
        content: content,
        createdAt: DateTime(2026),
      ),
    );
    return sessionId;
  }

  test('快照旧版 → 重生成 persist 记新版并移指针 → 两版本可切换', () async {
    final sessionId = await seedRound(content: '第一版正文。');
    final artifacts = await service.persistRound(
      userMessage: ChatMessage(
        messageId: 'u1x',
        sessionId: sessionId,
        role: 'user',
        content: '推进剧情',
        createdAt: DateTime(2026),
      ),
      assistantMessage: ChatMessage(
        messageId: 'a1x',
        sessionId: sessionId,
        role: 'assistant',
        content: '第一版正文。',
        createdAt: DateTime(2026),
      ),
      eventSummary: const EventSummary(
        summary: '第一轮',
        importance: 3,
        tags: [],
        turnNumber: 1,
      ),
      embedding: null,
      artifacts: StoryRoundArtifacts(
        sessionId: sessionId,
        turnNumber: 1,
        createdAt: DateTime(2026),
        replyText: '第一版正文。',
      ),
    );
    expect(artifacts.memory.memoryId, isNotEmpty);

    // ① 重生成删除阶段前：旧版快照为 variant 0
    final oldIndex = await service.snapshotMessageVariant(
      sessionId: sessionId,
      turnNumber: 1,
      content: '第一版正文。',
      sourceInput: '推进剧情',
      process: StoryRoundArtifacts(
        sessionId: sessionId,
        turnNumber: 1,
        createdAt: DateTime(2026),
        replyText: '第一版正文。',
      ),
    );
    expect(oldIndex, 0, reason: '该轮首个变体 = 最初版本');

    // ② 删除旧 assistant 行（重生成流程语义）后 persist 新版（记变体+指针）
    await chatRepo.deleteMessage('a1x');
    await service.persistRegeneratedRound(
      assistantMessage: ChatMessage(
        messageId: 'a2x',
        sessionId: sessionId,
        role: 'assistant',
        content: '第二版正文。',
        createdAt: DateTime(2026),
      ),
      eventSummary: const EventSummary(
        summary: '第一轮（重生成）',
        importance: 3,
        tags: [],
        turnNumber: 1,
      ),
      embedding: null,
      artifacts: StoryRoundArtifacts(
        sessionId: sessionId,
        turnNumber: 1,
        createdAt: DateTime(2026),
        replyText: '第二版正文。',
      ),
      recordVariant: true,
      variantSourceInput: '推进剧情',
    );

    final variants = await service.loadMessageVariants(sessionId);
    expect(variants[1], hasLength(2));
    expect(variants[1]![0].content, '第一版正文。');
    expect(variants[1]![1].content, '第二版正文。');
    final artifactsMap = await service.loadArtifactsBySession(sessionId);
    expect(artifactsMap[1]!.currentVariantIndex, 1, reason: '指针指向新版');

    // ③ 切回 variant 0：消息 content 物化为旧版 + 指针回 0
    final switched = await service.switchMessageVariant(
      sessionId: sessionId,
      turnNumber: 1,
      variantIndex: 0,
      assistantMessageId: 'a2x',
    );
    expect(switched, isTrue);
    final messages = await chatRepo.getMessages(sessionId);
    final assistant = messages.firstWhere((m) => m.messageId == 'a2x');
    expect(assistant.content, '第一版正文。', reason: 'content 物化为所选变体');
    final artifactsMap2 = await service.loadArtifactsBySession(sessionId);
    expect(artifactsMap2[1]!.currentVariantIndex, 0);
    expect(artifactsMap2[1]!.replyText, '第一版正文。');
  });

  test('切换变体同步 chat_sessions.story_anchor', () async {
    final sessionId = await seedRound(content: 'v0');
    const anchorA = StoryAnchor(updatedTurn: 1, arc: '弧线A');
    const anchorB = StoryAnchor(updatedTurn: 1, arc: '弧线B');

    // 第 1 轮落库（锚 A）→ 旧版快照为 variant 0（锚 A）→ 重生成新版
    //（锚 B，session 锚随 persist 写为 B）
    await service.persistRound(
      userMessage: ChatMessage(
        messageId: 'u9',
        sessionId: sessionId,
        role: 'user',
        content: '推进',
        createdAt: DateTime(2026),
      ),
      assistantMessage: ChatMessage(
        messageId: 'a9',
        sessionId: sessionId,
        role: 'assistant',
        content: 'v0',
        createdAt: DateTime(2026),
      ),
      eventSummary: const EventSummary(
        summary: '第一轮',
        importance: 3,
        tags: [],
        turnNumber: 1,
      ),
      embedding: null,
      artifacts: StoryRoundArtifacts(
        sessionId: sessionId,
        turnNumber: 1,
        createdAt: DateTime(2026),
        replyText: 'v0',
        storyAnchor: anchorA,
      ),
    );
    await service.snapshotMessageVariant(
      sessionId: sessionId,
      turnNumber: 1,
      content: 'v0',
      sourceInput: '推进',
      process: StoryRoundArtifacts(
        sessionId: sessionId,
        turnNumber: 1,
        createdAt: DateTime(2026),
        replyText: 'v0',
        storyAnchor: anchorA,
      ),
    );
    await chatRepo.deleteMessage('a9');
    await service.persistRegeneratedRound(
      assistantMessage: ChatMessage(
        messageId: 'a9b',
        sessionId: sessionId,
        role: 'assistant',
        content: 'v1',
        createdAt: DateTime(2026),
      ),
      eventSummary: const EventSummary(
        summary: '第一轮（重生成）',
        importance: 3,
        tags: [],
        turnNumber: 1,
      ),
      embedding: null,
      artifacts: StoryRoundArtifacts(
        sessionId: sessionId,
        turnNumber: 1,
        createdAt: DateTime(2026),
        replyText: 'v1',
        storyAnchor: anchorB,
      ),
      recordVariant: true,
      variantSourceInput: '推进',
    );
    expect(
      (await chatRepo.getSession(sessionId)).storyAnchor?.arc,
      '弧线B',
      reason: '前置：重生成 persist 把会话锚写为新版锚',
    );

    // 切回 variant 0（锚 A）——会话当前锚必须随正文版本回拨为 A，
    // 否则下一轮 coreBlocks/伏笔清点/Recap 用的仍是新重生成轮的锚
    await service.switchMessageVariant(
      sessionId: sessionId,
      turnNumber: 1,
      variantIndex: 0,
      assistantMessageId: 'a9b',
    );
    expect(
      (await chatRepo.getSession(sessionId)).storyAnchor?.arc,
      '弧线A',
      reason: '切回旧变体后会话锚应同步为变体锚',
    );

    // 切到无锚变体（NULL）→ 按 05aaa3fb 语义回退存活轮最近锚；
    // 本例 turn<1 无存活锚 → 会话锚置 NULL
    final nullAnchorIndex = await service.snapshotMessageVariant(
      sessionId: sessionId,
      turnNumber: 1,
      content: 'v2-noanchor',
      sourceInput: '推进',
      process: StoryRoundArtifacts(
        sessionId: sessionId,
        turnNumber: 1,
        createdAt: DateTime(2026),
        replyText: 'v2-noanchor',
      ),
    );
    await service.switchMessageVariant(
      sessionId: sessionId,
      turnNumber: 1,
      variantIndex: nullAnchorIndex,
      assistantMessageId: 'a9b',
    );
    expect(
      (await chatRepo.getSession(sessionId)).storyAnchor,
      isNull,
      reason: 'NULL 锚变体且无存活前轮锚时会话锚置 NULL',
    );
  });

  test('删除非当前变体生效；不存在的变体切换返回 false', () async {
    final sessionId = await seedRound(content: 'v0');
    await service.snapshotMessageVariant(
      sessionId: sessionId,
      turnNumber: 1,
      content: 'v0',
    );
    await service.snapshotMessageVariant(
      sessionId: sessionId,
      turnNumber: 1,
      content: 'v1',
    );

    await service.deleteMessageVariant(
      sessionId: sessionId,
      turnNumber: 1,
      variantIndex: 1,
    );
    final variants = await service.loadMessageVariants(sessionId);
    expect(variants[1], hasLength(1));
    expect(variants[1]!.single.content, 'v0');

    final switched = await service.switchMessageVariant(
      sessionId: sessionId,
      turnNumber: 1,
      variantIndex: 9,
      assistantMessageId: 'a1',
    );
    expect(switched, isFalse, reason: '变体不存在幂等返回 false');
  });

  test('deleteRoundAndDownstream 连带删除该轮变体（删轮=物理删全部版本）', () async {
    final sessionId = await seedRound(content: 'v0');
    await service.snapshotMessageVariant(
      sessionId: sessionId,
      turnNumber: 1,
      content: 'v0',
    );
    await service.snapshotMessageVariant(
      sessionId: sessionId,
      turnNumber: 1,
      content: 'v1',
    );

    await service.deleteRoundAndDownstream(
      sessionId: sessionId,
      fromTurnNumber: 1,
      messageIdsToDelete: const ['u1', 'a1'],
    );
    final variants = await service.loadMessageVariants(sessionId);
    expect(variants[1], isNull, reason: '删轮后变体随之物理删除');
  });

  test('编辑助手消息 → message 行与当前变体行同改，切换器往返不回退', () async {
    final sessionId = await seedRound(content: '第一版正文。');
    await service.persistRound(
      userMessage: ChatMessage(
        messageId: 'u1x',
        sessionId: sessionId,
        role: 'user',
        content: '推进剧情',
        createdAt: DateTime(2026),
      ),
      assistantMessage: ChatMessage(
        messageId: 'a1x',
        sessionId: sessionId,
        role: 'assistant',
        content: '第一版正文。',
        createdAt: DateTime(2026),
      ),
      eventSummary: const EventSummary(
        summary: '第一轮',
        importance: 3,
        tags: [],
        turnNumber: 1,
      ),
      embedding: null,
      artifacts: StoryRoundArtifacts(
        sessionId: sessionId,
        turnNumber: 1,
        createdAt: DateTime(2026),
        replyText: '第一版正文。',
      ),
    );
    await service.snapshotMessageVariant(
      sessionId: sessionId,
      turnNumber: 1,
      content: '第一版正文。',
      sourceInput: '推进剧情',
      process: StoryRoundArtifacts(
        sessionId: sessionId,
        turnNumber: 1,
        createdAt: DateTime(2026),
        replyText: '第一版正文。',
      ),
    );
    await chatRepo.deleteMessage('a1x');
    await service.persistRegeneratedRound(
      assistantMessage: ChatMessage(
        messageId: 'a2x',
        sessionId: sessionId,
        role: 'assistant',
        content: '第二版正文。',
        createdAt: DateTime(2026),
      ),
      eventSummary: const EventSummary(
        summary: '第一轮（重生成）',
        importance: 3,
        tags: [],
        turnNumber: 1,
      ),
      embedding: null,
      artifacts: StoryRoundArtifacts(
        sessionId: sessionId,
        turnNumber: 1,
        createdAt: DateTime(2026),
        replyText: '第二版正文。',
      ),
      recordVariant: true,
      variantSourceInput: '推进剧情',
    );
    // 指针指向第二版（variant 1）

    final saved = await service.updateAssistantContentAndCurrentVariant(
      sessionId: sessionId,
      turnNumber: 1,
      assistantMessageId: 'a2x',
      newContent: '用户改写的正文。',
    );
    expect(saved, isTrue);

    // message 行 = 新内容（所见=所存）
    var messages = await chatRepo.getMessages(sessionId);
    expect(
      messages.firstWhere((m) => m.messageId == 'a2x').content,
      '用户改写的正文。',
    );
    // 当前指针变体行同步；非当前变体（旧版）不动
    final variants = await service.loadMessageVariants(sessionId);
    expect(variants[1]![0].content, '第一版正文。');
    expect(variants[1]![1].content, '用户改写的正文。');

    // 切换器往返：切到旧版再切回，编辑不被回退
    expect(
      await service.switchMessageVariant(
        sessionId: sessionId,
        turnNumber: 1,
        variantIndex: 0,
        assistantMessageId: 'a2x',
      ),
      isTrue,
    );
    expect(
      await service.switchMessageVariant(
        sessionId: sessionId,
        turnNumber: 1,
        variantIndex: 1,
        assistantMessageId: 'a2x',
      ),
      isTrue,
    );
    messages = await chatRepo.getMessages(sessionId);
    expect(
      messages.firstWhere((m) => m.messageId == 'a2x').content,
      '用户改写的正文。',
      reason: '往返后用户编辑仍在（当前变体行已同步）',
    );
  });

  test('无变体轮编辑助手消息：仅改 message 行，等价旧路径', () async {
    final sessionId = await seedRound(content: '只有一版。');
    await service.persistRound(
      userMessage: ChatMessage(
        messageId: 'u2x',
        sessionId: sessionId,
        role: 'user',
        content: '推进',
        createdAt: DateTime(2026),
      ),
      assistantMessage: ChatMessage(
        messageId: 'a3x',
        sessionId: sessionId,
        role: 'assistant',
        content: '只有一版。',
        createdAt: DateTime(2026),
      ),
      eventSummary: const EventSummary(
        summary: '第一轮',
        importance: 3,
        tags: [],
        turnNumber: 1,
      ),
      embedding: null,
      artifacts: StoryRoundArtifacts(
        sessionId: sessionId,
        turnNumber: 1,
        createdAt: DateTime(2026),
        replyText: '只有一版。',
      ),
    );

    final saved = await service.updateAssistantContentAndCurrentVariant(
      sessionId: sessionId,
      turnNumber: 1,
      assistantMessageId: 'a3x',
      newContent: '编辑后的一版。',
    );
    expect(saved, isTrue);
    final messages = await chatRepo.getMessages(sessionId);
    expect(
      messages.firstWhere((m) => m.messageId == 'a3x').content,
      '编辑后的一版。',
    );
    expect(
      await service.loadMessageVariants(sessionId),
      isEmpty,
      reason: '无变体轮不产生变体行',
    );
  });
}
