import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/agent/agent_cancellation.dart';
import 'package:lmstory/core/agent/agent_tool.dart';
import 'package:lmstory/core/vector/vector_engine.dart';
import 'package:lmstory/features/advanced/data/engineering_compaction_service.dart';
import 'package:lmstory/features/advanced/domain/entities/advanced_chat_state.dart'
    as advanced_state;
import 'package:lmstory/features/advanced/domain/entities/agent_round_draft.dart';
import 'package:lmstory/features/advanced/domain/services/agent_session_tools.dart';
import 'package:lmstory/features/advanced/domain/services/agent_story_reader.dart';
import 'package:lmstory/features/advanced/domain/services/search_story_text_tool.dart';
import 'package:lmstory/features/advanced/presentation/controllers/director_host.dart';
import 'package:lmstory/features/advanced/presentation/controllers/director_story_reader.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/chat/data/repositories/chat_repository_impl.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/entities/chat_mode.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/repositories/chat_repository.dart';
import 'package:lmstory/features/memory/data/repositories/experience_repository_impl.dart';
import 'package:lmstory/features/memory/domain/entities/event_summary.dart';
import 'package:lmstory/features/memory/domain/repositories/experience_repository.dart';
import 'package:lmstory/features/memory/domain/repositories/factual_repository.dart';
import 'package:lmstory/features/story_runtime/data/persistence_service_impl.dart';
import 'package:lmstory/features/story_runtime/domain/entities/round_artifacts.dart';
import 'package:lmstory/features/story_runtime/domain/services/persistence_service.dart';

/// 原文检索不受记忆索引门槛影响（MEM-11-19 处置）
///
/// search_story_text / read_story 的数据面是 artifacts + chat_messages 原文，
/// 与 experiential_memories 的 FTS/向量索引完全独立。本文件用内存 drift 库
/// 走真实持久化链路（persistRound/变体切换）验证五点：
/// 1. 低重要度细节可查（经历索引不含该细节仍命中原文）；
/// 2. memories_fts 清空后原文检索/回读不受影响；
/// 3. 旧会话（仅历史轮数据，无本轮 state）可查；
/// 4. 变体切换后指向当前正文（chat_messages.content 物化为当前变体）；
/// 5. 会话隔离（另一会话同关键词不返回）。
void main() {
  late AppDatabase db;
  late ChatRepository chatRepo;
  late ExperienceRepositoryImpl expRepo;
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

  /// 落库一轮真实产物（消息 + artifacts + 记忆 + FTS 全链路）
  Future<String> seedRound({
    required String userText,
    required String narrative,
    String? summaryText,
    int turn = 1,
    String title = '测试会话',
  }) async {
    final session =
        await chatRepo.createSession(title: title, mode: 'advanced');
    final sessionId = session.sessionId;
    final now = DateTime(2026);
    await service.persistRound(
      userMessage: ChatMessage(
        messageId: 'u$turn-$sessionId',
        sessionId: sessionId,
        role: 'user',
        content: userText,
        createdAt: now,
      ),
      assistantMessage: ChatMessage(
        messageId: 'a$turn-$sessionId',
        sessionId: sessionId,
        role: 'assistant',
        content: narrative,
        createdAt: now,
      ),
      eventSummary: EventSummary(
        summary: summaryText ?? '第 $turn 轮事件',
        importance: 3,
        tags: const [],
        turnNumber: turn,
      ),
      embedding: null,
      artifacts: StoryRoundArtifacts(
        sessionId: sessionId,
        turnNumber: turn,
        generatedText: narrative,
        createdAt: now,
      ),
    );
    return sessionId;
  }

  /// 以某会话视角组装 DB 直连的 story reader + 检索工具
  ///（DirectorStoryReader 同产线装配：artifacts + chat_messages 双源）
  ({SearchStoryTextTool textTool, ReadStoryTool readTool}) toolsFor(
    String sessionId,
    AgentRoundDraft draft,
  ) {
    final reader = DirectorStoryReader(
      _DbHost(sessionId: sessionId, persistence: service, chatRepo: chatRepo),
    );
    final deps = AgentToolDeps(
      sessionId: sessionId,
      draft: draft,
      factualRepository: _EmptyFactualRepository(),
      experienceRepository: _EmptyExperienceRepository(),
      storyReader: reader,
      latestMacros: () async => [],
      userInteraction: _NoopUserPort(),
      commitRound: (d) async => 'committed',
    );
    return (
      textTool: SearchStoryTextTool(reader: reader, draft: draft),
      readTool: ReadStoryTool(deps),
    );
  }

  AgentToolInvocation invocationFor(AgentTool tool) => AgentToolInvocation(
        callId: 'd3',
        toolName: tool.name,
        stepIndex: 0,
        cancellation: AgentCancellationToken(),
      );

  test('1. 低重要度细节可查：经历索引无该细节，原文检索仍命中', () async {
    final sessionId = await seedRound(
      userText: '问问老人怀表的来历',
      narrative: '老人从怀里掏出银色怀表链，在油灯下慢慢擦拭。',
    );
    // 同轮插入 importance=1 的经历记忆且不建 FTS 行（低重要度按策略不入索引）
    await expRepo.appendExperience(
      sessionId: sessionId,
      summary: '老人展示了怀表',
      importance: 1,
      tags: const [],
      turnNumber: 1,
      indexForRetrieval: false,
    );
    // 前置证明：该记忆确实缺 memories_fts 行（索引缺口真实存在）
    final unindexed =
        await expRepo.getUnindexedExperiences(sessionId, limit: 10);
    expect(unindexed, isNotEmpty);
    expect(unindexed.every((m) => m.importance == 1), isTrue);

    final draft = AgentRoundDraft(turnNumber: 2);
    final tools = toolsFor(sessionId, draft);
    final result = await tools.textTool.invoke(
      invocationFor(tools.textTool),
      {'query': '银色怀表链'},
    );

    expect(result.isError, isFalse);
    expect(result.metadata?['total'], 1);
    expect(result.output, contains('[第1轮]'));
    expect(result.output, contains('银色怀表链'));
  });

  test('2. memories_fts 清空（索引损坏形态）后 search_story_text / read_story 仍正常',
      () async {
    // 关键词取 ≥3 字长词（青苔甬道）：短词（<3 字）会走主表 LIKE
    // 兜底通道，无法证明 FTS 通道确实失明
    const keyword = '青苔甬道';
    final sessionId = await seedRound(
      userText: '进入遗迹',
      narrative: '石门后是一条青苔甬道，寒气森然。',
      // 记忆摘要含关键词：FTS 清空前关键词通道可命中（对照组前提）
      summaryText: '主角踏入青苔甬道',
    );
    // 索引清空前 FTS 可检索（前置：索引本来有效）
    final before = await expRepo.searchExperiences(
      sessionId: sessionId,
      query: keyword,
      queryVector: null,
      topK: 5,
      fts5Weight: 0.5,
      vectorWeight: 0.5,
      keyEventThreshold: 4,
      keyEventBoost: 1.5,
      normalizationEpsilon: 0.01,
    );
    expect(before, isNotEmpty);

    // 清空关键词索引（模拟索引损坏/丢失形态）
    await db.customStatement('DELETE FROM memories_fts');
    final after = await expRepo.searchExperiences(
      sessionId: sessionId,
      query: keyword,
      queryVector: null,
      topK: 5,
      fts5Weight: 0.5,
      vectorWeight: 0.5,
      keyEventThreshold: 4,
      keyEventBoost: 1.5,
      normalizationEpsilon: 0.01,
    );
    expect(after, isEmpty, reason: '前置证明：FTS 通道确已失明');

    final draft = AgentRoundDraft(turnNumber: 2);
    final tools = toolsFor(sessionId, draft);
    final search = await tools.textTool.invoke(
      invocationFor(tools.textTool),
      {'query': keyword},
    );
    final read = await tools.readTool.invoke(
      invocationFor(tools.readTool),
      {'turn': 1},
    );

    expect(search.isError, isFalse, reason: '原文检索不依赖 memories_fts');
    expect(search.metadata?['total'], 1);
    expect(search.output, contains(keyword));
    expect(read.isError, isFalse);
    expect(read.output, contains(keyword));
  });

  test('3. 旧会话（仅历史轮数据，无本轮 state）可查', () async {
    final sessionId = await seedRound(
      userText: '第一轮',
      narrative: '旧会话的第一段正文写着青铜罗盘。',
    );
    // 会话重开形态：只有 DB 历史轮，draft 为新轮（无任何本轮产物）
    final draft = AgentRoundDraft(turnNumber: 2);
    final tools = toolsFor(sessionId, draft);

    final search = await tools.textTool.invoke(
      invocationFor(tools.textTool),
      {'query': '青铜罗盘'},
    );
    final read = await tools.readTool.invoke(
      invocationFor(tools.readTool),
      {'turn': 1},
    );

    expect(search.metadata?['total'], 1);
    expect(search.output, contains('[第1轮]'));
    expect(read.metadata?['total'], 1);
    expect(read.output, contains('青铜罗盘'));
  });

  test('4. 变体切换后指向当前正文（chat_messages.content 物化为当前变体）', () async {
    final sessionId = await seedRound(
      userText: '推进剧情',
      narrative: '初版正文：银色怀表链在灯下闪光。',
    );
    // 快照旧版为 variant 0 → 删旧 assistant → 落新版（variant 1 成为当前）
    await service.snapshotMessageVariant(
      sessionId: sessionId,
      turnNumber: 1,
      content: '初版正文：银色怀表链在灯下闪光。',
      sourceInput: '推进剧情',
      process: StoryRoundArtifacts(
        sessionId: sessionId,
        turnNumber: 1,
        createdAt: DateTime(2026),
        replyText: '初版正文：银色怀表链在灯下闪光。',
      ),
    );
    await chatRepo.deleteMessage('a1-$sessionId');
    await service.persistRegeneratedRound(
      assistantMessage: ChatMessage(
        messageId: 'a1b-$sessionId',
        sessionId: sessionId,
        role: 'assistant',
        content: '重写正文：青铜钥匙插进了锁孔。',
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
        replyText: '重写正文：青铜钥匙插进了锁孔。',
      ),
      recordVariant: true,
      variantSourceInput: '推进剧情',
    );

    // 当前 = variant 1（青铜钥匙）：新词可查、旧词不可查
    var draft = AgentRoundDraft(turnNumber: 2);
    var tools = toolsFor(sessionId, draft);
    final hitNew = await tools.textTool.invoke(
      invocationFor(tools.textTool),
      {'query': '青铜钥匙'},
    );
    final missOld = await tools.textTool.invoke(
      invocationFor(tools.textTool),
      {'query': '银色怀表链'},
    );
    expect(hitNew.metadata?['total'], 1, reason: '当前变体为新版');
    expect(missOld.metadata?['total'], 0, reason: '旧变体已不是当前正文');

    // 切回 variant 0：content 物化为旧版，检索与回读都指向旧版
    final switched = await service.switchMessageVariant(
      sessionId: sessionId,
      turnNumber: 1,
      variantIndex: 0,
      assistantMessageId: 'a1b-$sessionId',
    );
    expect(switched, isTrue);

    draft = AgentRoundDraft(turnNumber: 2);
    tools = toolsFor(sessionId, draft);
    final hitOld = await tools.textTool.invoke(
      invocationFor(tools.textTool),
      {'query': '银色怀表链'},
    );
    final read = await tools.readTool.invoke(
      invocationFor(tools.readTool),
      {'turn': 1},
    );
    expect(hitOld.metadata?['total'], 1, reason: '切回后指向当前（旧版）正文');
    expect(read.output, contains('银色怀表链'));
    expect(read.output, isNot(contains('青铜钥匙')));
  });

  test('5. 会话隔离：另一会话同关键词不返回', () async {
    final sessionA = await seedRound(
      userText: '甲会话',
      narrative: '甲会话的正文提到星图残页。',
      title: '会话A',
    );
    final sessionB = await seedRound(
      userText: '乙会话',
      narrative: '乙会话的正文也提到星图残页。',
      title: '会话B',
    );
    expect(sessionA, isNot(sessionB));

    // 以会话 A 的视角检索：只能看到 A 的轮次
    final tools = toolsFor(sessionA, AgentRoundDraft(turnNumber: 2));
    final result = await tools.textTool.invoke(
      invocationFor(tools.textTool),
      {'query': '星图残页'},
    );

    expect(result.metadata?['total'], 1);
    expect(result.output, contains('甲会话'));
    expect(result.output, isNot(contains('乙会话')));
  });
}

/// DB 直连的最小 DirectorHost（story reader 只消费三个成员）
class _DbHost implements DirectorHost {
  _DbHost({
    required this.sessionId,
    required this.persistence,
    required this.chatRepo,
  });

  final String sessionId;
  final StoryPersistenceService persistence;
  final ChatRepository chatRepo;

  @override
  advanced_state.AdvancedChatState get storyState =>
      advanced_state.AdvancedChatState.initial(
        ChatSession(
          sessionId: sessionId,
          title: '测试会话',
          mode: ChatMode.advanced,
          createdAt: DateTime(2026),
          lastActiveAt: DateTime(2026),
          messageCount: 0,
        ),
      );

  @override
  set storyState(advanced_state.AdvancedChatState value) {
    // reader 只读 state；写入不被触达
  }

  @override
  Future<List<ChatMessage>> loadSessionMessages(String sessionId) =>
      chatRepo.getMessages(sessionId);

  @override
  Future<Map<int, StoryRoundArtifacts>> loadSessionArtifacts(
    String sessionId,
  ) =>
      persistence.loadArtifactsBySession(sessionId);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();

  @override
  EngineeringCompactionService? get engineeringCompactionService => null;
}

class _EmptyFactualRepository implements FactualRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _EmptyExperienceRepository implements ExperienceRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _NoopUserPort implements AgentUserInteractionPort {
  @override
  Future<String?> askUser({
    required String question,
    List<String>? options,
  }) async =>
      null;
}
