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
import 'package:lmstory/features/memory/domain/entities/facts_delta.dart';
import 'package:lmstory/features/memory/domain/repositories/experience_repository.dart';
import 'package:lmstory/features/memory/domain/services/fact_applier.dart';
import 'package:lmstory/features/settings/data/repositories/backup_repository_impl.dart';
import 'package:lmstory/features/settings/domain/entities/data_management_models.dart';
import 'package:lmstory/features/story_runtime/data/persistence_service_impl.dart';
import 'package:lmstory/features/story_runtime/domain/entities/round_artifacts.dart';
import 'package:lmstory/features/story_runtime/domain/services/persistence_service.dart';

/// 变体切换与记忆层一致性（正文=事实真源）
///
/// 覆盖：切换后经历/事实/锚随所选正文交换；来回切换不重复不丢；旧变体
/// 无派生快照时不虚构；只读基线不受交换影响；FTS 行随恢复重建。
void main() {
  late AppDatabase db;
  late ChatRepository chatRepo;
  late ExperienceRepository expRepo;
  late FactApplier factApplier;
  late StoryPersistenceService service;
  late String sessionId;
  late String assistantId;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    chatRepo = ChatRepositoryImpl(database: db);
    expRepo = ExperienceRepositoryImpl(
      database: db,
      vectorEngine: const VectorEngine(),
    );
    factApplier = FactApplier(
      repository: FactualRepositoryImpl(database: db),
    );
    service = StoryPersistenceServiceImpl(
      database: db,
      chatRepository: chatRepo,
      experienceRepository: expRepo,
      factApplier: factApplier,
    );
    final session = await chatRepo.createSession(title: '测试', mode: 'advanced');
    sessionId = session.sessionId;
  });

  tearDown(() async => db.close());

  StoryRoundArtifacts artifactsFor({
    required String reply,
    String? anchorArc,
    EventSummary? eventSummary,
  }) =>
      StoryRoundArtifacts(
        sessionId: sessionId,
        turnNumber: 1,
        createdAt: DateTime(2026),
        replyText: reply,
        eventSummary: eventSummary,
        storyAnchor: anchorArc == null
            ? null
            : StoryAnchor(
                updatedTurn: 1,
                arc: anchorArc,
              ),
      );

  Future<void> persistVariantRound({
    required String messageId,
    required String content,
    required String summary,
    required String description,
    String? anchorArc,
    String userInput = '推进剧情',
    bool regenerate = false,
    bool hasVerifiedSourceTurn = false,
  }) async {
    final message = ChatMessage(
      messageId: messageId,
      sessionId: sessionId,
      role: 'assistant',
      content: content,
      createdAt: DateTime(2026),
    );
    final deltas = [
      FactsDelta(
        action: FactAction.createEntity,
        entityType: 'character',
        primaryName: '陈默',
        attrKey: 'description',
        value: description,
        confidence: 5,
        importance: 4,
      ),
    ];
    final event = EventSummary(
      summary: summary,
      importance: 3,
      tags: const [],
      turnNumber: 1,
    );
    final artifacts =
        artifactsFor(reply: content, anchorArc: anchorArc, eventSummary: event);
    if (regenerate) {
      await service.persistRegeneratedRound(
        assistantMessage: message,
        eventSummary: event,
        embedding: null,
        hasVerifiedSourceTurn: hasVerifiedSourceTurn,
        artifacts: artifacts,
        factsDeltas: deltas,
        factualConfig: const FactualConfig(),
        recordVariant: true,
        variantSourceInput: userInput,
      );
    } else {
      await service.persistRound(
        variantSourceInput: userInput,
        userMessage: ChatMessage(
          messageId: 'u1',
          sessionId: sessionId,
          role: 'user',
          content: userInput,
          createdAt: DateTime(2026),
        ),
        assistantMessage: message,
        eventSummary: event,
        embedding: null,
        hasVerifiedSourceTurn: hasVerifiedSourceTurn,
        artifacts: artifacts,
        factsDeltas: deltas,
        factualConfig: const FactualConfig(),
      );
    }
  }

  Future<String?> currentDescription() async {
    final rows = await db
        .customSelect(
          'SELECT fa.value FROM factual_attributes fa '
          'JOIN factual_entities fe ON fa.entity_id = fe.entity_id '
          "WHERE fe.primary_name = '陈默' AND fa.attr_key = 'background' "
          "AND fa.source = 'auto'",
        )
        .get();
    return rows.isEmpty ? null : rows.first.readNullable<String>('value');
  }

  Future<List<String>> turnSummaries() async {
    final rows = await db.customSelect(
      'SELECT summary FROM experiential_memories '
      'WHERE session_id = ? AND turn_number = 1',
      variables: [Variable.withString(sessionId)],
    ).get();
    return rows.map((r) => r.readNullable<String>('summary') ?? '').toList();
  }

  Future<void> deleteTurnOne() async {
    await service.deleteRoundAndDownstream(
      sessionId: sessionId,
      fromTurnNumber: 1,
      messageIdsToDelete: const [],
      keepVariantsAtFromTurn: true,
    );
  }

  test('互斥事实双版本：切换后事实/经历/锚随所选正文，来回不重复不丢', () async {
    // 第一版：陈默存活
    await persistVariantRound(
      messageId: 'a1',
      content: '陈默活着的版本。',
      summary: '第一版：陈默存活',
      description: '陈默：存活，担任向导',
      anchorArc: '寻找古城',
    );
    // 重生成：旧版快照 → 删除 → 第二版：陈默战死
    await service.snapshotMessageVariant(
      sessionId: sessionId,
      turnNumber: 1,
      content: '陈默活着的版本。',
      sourceInput: '推进剧情',
      process: artifactsFor(reply: '陈默活着的版本。', anchorArc: '寻找古城'),
    );
    await deleteTurnOne();
    await chatRepo.deleteMessage('a1');
    await persistVariantRound(
      messageId: 'a2',
      content: '陈默战死的版本。',
      summary: '第二版：陈默战死',
      description: '陈默：已战死',
      anchorArc: '为友复仇',
      regenerate: true,
    );
    assistantId = 'a2';
    expect(await currentDescription(), '陈默：已战死');
    expect(await turnSummaries(), ['第二版：陈默战死']);

    // 切回第一版：事实/经历/锚全部指向存活时间线
    var switched = await service.switchMessageVariant(
      sessionId: sessionId,
      turnNumber: 1,
      variantIndex: 0,
      assistantMessageId: assistantId,
      factualConfig: const FactualConfig(),
    );
    expect(switched, isTrue);
    expect(await currentDescription(), '陈默：存活，担任向导');
    expect(await turnSummaries(), ['第一版：陈默存活']);
    final contentRow = await db.customSelect(
      'SELECT content FROM chat_messages WHERE message_id = ?',
      variables: [Variable.withString(assistantId)],
    ).get();
    expect(contentRow.first.readNullable<String>('content'), '陈默活着的版本。');
    final anchorJson = await db.customSelect(
      'SELECT story_anchor FROM chat_sessions WHERE session_id = ?',
      variables: [Variable.withString(sessionId)],
    ).get();
    expect(
      anchorJson.first.readNullable<String>('story_anchor'),
      contains('寻找古城'),
    );

    // 切回第二版：同样完整交换，无重复行
    switched = await service.switchMessageVariant(
      sessionId: sessionId,
      turnNumber: 1,
      variantIndex: 1,
      assistantMessageId: assistantId,
      factualConfig: const FactualConfig(),
    );
    expect(switched, isTrue);
    expect(await currentDescription(), '陈默：已战死');
    expect(await turnSummaries(), ['第二版：陈默战死']);
    expect(await currentDescription(), isNot(contains('存活')));

    // 实体行不重复
    final entityRows = await db.customSelect(
      'SELECT COUNT(*) AS c FROM factual_entities '
      'WHERE session_id = ? AND primary_name = ?',
      variables: [Variable.withString(sessionId), Variable.withString('陈默')],
    ).get();
    expect(entityRows.first.read<int>('c'), 1);
  });

  test('已核对的单轮出处随当前变体和存档往返，改写正文后撤销', () async {
    await persistVariantRound(
      messageId: 'a1',
      content: '师姐收起铜令牌。',
      summary: '师姐收起令牌',
      description: '持有令牌',
      hasVerifiedSourceTurn: true,
    );
    final first = (await expRepo.getAllExperiences(sessionId)).single;
    expect(first.hasVerifiedSourceTurn, isTrue);
    await service.snapshotMessageVariant(
      sessionId: sessionId,
      turnNumber: 1,
      content: '师姐收起铜令牌。',
      sourceInput: '推进剧情',
      process: artifactsFor(reply: '师姐收起铜令牌。'),
    );
    await deleteTurnOne();
    expect(await expRepo.getExperienceById(first.memoryId), isNull);
    await chatRepo.deleteMessage('a1');
    await persistVariantRound(
      messageId: 'a2',
      content: '师姐交出铜令牌。',
      summary: '师姐交出令牌',
      description: '交出令牌',
      regenerate: true,
      hasVerifiedSourceTurn: true,
    );
    final second = (await expRepo.getAllExperiences(sessionId)).single;
    expect(second.hasVerifiedSourceTurn, isTrue);
    expect(second.memoryId, isNot(first.memoryId));

    // 让两条变体持有不同的出处状态，才能发现切换或导入时串线。
    await service.updateAssistantContentAndCurrentVariant(
      sessionId: sessionId,
      turnNumber: 1,
      assistantMessageId: 'a2',
      newContent: '师姐把铜令牌熔了。',
    );
    expect(
      (await expRepo.getExperienceById(second.memoryId))?.hasVerifiedSourceTurn,
      isFalse,
    );
    final backup = BackupRepositoryImpl(database: db);
    final data = await backup.exportSessionData(sessionId);
    await backup.deleteSessionData(sessionId);
    expect(await expRepo.getAllExperiences(sessionId), isEmpty);
    await backup.importSessionData(data, mode: ImportMode.overwrite);
    Future<void> select(int index) async {
      expect(
        await service.switchMessageVariant(
          sessionId: sessionId,
          turnNumber: 1,
          variantIndex: index,
          assistantMessageId: 'a2',
          factualConfig: const FactualConfig(),
        ),
        isTrue,
      );
    }

    await select(1);
    expect(
      (await expRepo.getAllExperiences(sessionId)).single.hasVerifiedSourceTurn,
      isFalse,
    );
    await select(0);
    final restored = (await expRepo.getAllExperiences(sessionId)).single;
    expect(restored.memoryId, first.memoryId);
    expect(restored.hasVerifiedSourceTurn, isTrue);
    await select(1);
    final edited = (await expRepo.getAllExperiences(sessionId)).single;
    expect(edited.memoryId, second.memoryId);
    expect(edited.hasVerifiedSourceTurn, isFalse);
    await service.updateUserContentAndInvalidateSourceTurn(
      sessionId: sessionId,
      turnNumber: 1,
      userMessageId: 'u1',
      newContent: '把令牌留在原地',
    );
    await select(0);
    expect(
      (await expRepo.getAllExperiences(sessionId)).single.hasVerifiedSourceTurn,
      isFalse,
    );
  });

  test('连续选择两份旧稿时按当前用户消息核对出处', () async {
    await persistVariantRound(
      messageId: 'a1',
      content: '取钥匙。',
      summary: '取钥匙',
      description: '启程',
      hasVerifiedSourceTurn: true,
    );
    await service.snapshotMessageVariant(
      sessionId: sessionId,
      turnNumber: 1,
      content: '取钥匙。',
      sourceInput: '推进剧情',
    );
    await deleteTurnOne();
    await chatRepo.deleteMessage('a1');
    await persistVariantRound(
      messageId: 'a2',
      content: '钥匙遗失。',
      summary: '失去钥匙',
      description: '寻找钥匙',
      regenerate: true,
      hasVerifiedSourceTurn: true,
    );
    // 编辑重发保留两份旧稿，更换当前轮的用户输入。
    await deleteTurnOne();
    await chatRepo.deleteMessage('u1');
    await chatRepo.deleteMessage('a2');
    await persistVariantRound(
      messageId: 'a3',
      userInput: '留在家里',
      content: '把钥匙挂好。',
      summary: '挂好钥匙',
      description: '在家',
      hasVerifiedSourceTurn: true,
    );
    for (final index in [0, 1]) {
      expect(
        await service.switchMessageVariant(
          sessionId: sessionId,
          turnNumber: 1,
          variantIndex: index,
          assistantMessageId: 'a3',
          factualConfig: const FactualConfig(),
        ),
        isTrue,
      );
      final active = (await expRepo.getAllExperiences(sessionId)).single;
      expect(active.summary, index == 0 ? '取钥匙' : '失去钥匙');
      expect(active.hasVerifiedSourceTurn, isFalse);
    }
  });

  test('有出处的活跃记忆可随存档和会话副本保留，旧存档默认未知', () async {
    await persistVariantRound(
      messageId: 'a1',
      content: '铜令牌被放在桌上。',
      summary: '桌上出现铜令牌',
      description: '令牌在桌上',
      hasVerifiedSourceTurn: true,
    );
    final backup = BackupRepositoryImpl(database: db);
    final data = await backup.exportSessionData(sessionId);
    await backup.importSessionData(data, mode: ImportMode.overwrite);
    final original = (await expRepo.getAllExperiences(sessionId)).single;
    expect(original.hasVerifiedSourceTurn, isTrue);

    await expRepo.updateExperience(
      sessionId: sessionId,
      memoryId: original.memoryId,
      summary: original.summary,
      importance: 5,
    );
    expect(
      (await expRepo.getExperienceById(original.memoryId))
          ?.hasVerifiedSourceTurn,
      isTrue,
    );

    final copy = await chatRepo.copySession(sessionId);
    final copied = (await expRepo.getAllExperiences(copy.sessionId)).single;
    expect(copied.memoryId, isNot(original.memoryId));
    expect(copied.hasVerifiedSourceTurn, isTrue);
    await expRepo.updateExperience(
      sessionId: copy.sessionId,
      memoryId: copied.memoryId,
      summary: '手工改成另一件往事',
    );
    expect(
      (await expRepo.getExperienceById(copied.memoryId))?.hasVerifiedSourceTurn,
      isFalse,
    );
    expect(
      (await expRepo.getExperienceById(original.memoryId))
          ?.hasVerifiedSourceTurn,
      isTrue,
    );

    ((data['experientialMemories'] as List<dynamic>).single
            as Map<String, dynamic>)
        .remove('has_verified_source_turn');
    await backup.importSessionData(data, mode: ImportMode.overwrite);
    expect(
      (await expRepo.getAllExperiences(sessionId)).single.hasVerifiedSourceTurn,
      isFalse,
    );
  });

  test('旧变体无派生快照：移除当前派生，不虚构记忆', () async {
    await persistVariantRound(
      messageId: 'a1',
      content: '第一版正文。',
      summary: '第一版摘要',
      description: '状态甲',
    );
    await service.snapshotMessageVariant(
      sessionId: sessionId,
      turnNumber: 1,
      content: '第一版正文。',
      sourceInput: '推进剧情',
      process: artifactsFor(reply: '第一版正文。'),
    );
    await deleteTurnOne();
    await chatRepo.deleteMessage('a1');
    await persistVariantRound(
      messageId: 'a2',
      content: '第二版正文。',
      summary: '第二版摘要',
      description: '状态乙',
      regenerate: true,
    );

    // 模拟本能力之前的旧变体行：抹掉派生快照列
    await db.customStatement(
      'UPDATE message_variants SET facts_deltas = NULL, '
      'experiential_snapshot = NULL, event_summary = NULL, '
      'facts_changes = NULL '
      'WHERE session_id = ? AND turn_number = 1 AND variant_index = 0',
      [sessionId],
    );

    final switched = await service.switchMessageVariant(
      sessionId: sessionId,
      turnNumber: 1,
      variantIndex: 0,
      assistantMessageId: 'a2',
      factualConfig: const FactualConfig(),
    );
    expect(switched, isTrue);
    // 正文已切换
    final contentRow = await db.customSelect(
      'SELECT content FROM chat_messages WHERE message_id = ?',
      variables: [Variable.withString('a2')],
    ).get();
    expect(contentRow.first.readNullable<String>('content'), '第一版正文。');
    // 当前派生（属废弃时间线）被移除，且不虚构旧版派生
    expect(await turnSummaries(), isEmpty);
    expect(
      await currentDescription(),
      isNull,
      reason: '轮效果已回滚，不凭旧记忆猜写选中版本内容',
    );
    // 被切走变体（第二版）的快照此时已回写，可再切回
    final switchedBack = await service.switchMessageVariant(
      sessionId: sessionId,
      turnNumber: 1,
      variantIndex: 1,
      assistantMessageId: 'a2',
      factualConfig: const FactualConfig(),
    );
    expect(switchedBack, isTrue);
    expect(await turnSummaries(), ['第二版摘要']);
    expect(await currentDescription(), '状态乙');
  });

  test('FTS 索引随恢复重建，来回切换不重复', () async {
    await persistVariantRound(
      messageId: 'a1',
      content: '第一版正文。',
      summary: '古碑遗迹探险',
      description: '状态甲',
    );
    await service.snapshotMessageVariant(
      sessionId: sessionId,
      turnNumber: 1,
      content: '第一版正文。',
      sourceInput: '推进剧情',
      process: artifactsFor(reply: '第一版正文。'),
    );
    await deleteTurnOne();
    await chatRepo.deleteMessage('a1');
    await persistVariantRound(
      messageId: 'a2',
      content: '第二版正文。',
      summary: '雪山隘口遭遇',
      description: '状态乙',
      regenerate: true,
    );

    Future<int> ftsCount() async {
      final rows = await db.customSelect(
        'SELECT COUNT(*) AS c FROM memories_fts WHERE session_id = ?',
        variables: [Variable.withString(sessionId)],
      ).get();
      return rows.first.read<int>('c');
    }

    expect(await ftsCount(), 1);
    await service.switchMessageVariant(
      sessionId: sessionId,
      turnNumber: 1,
      variantIndex: 0,
      assistantMessageId: 'a2',
      factualConfig: const FactualConfig(),
    );
    expect(await ftsCount(), 1, reason: '恢复行重建 FTS，无重复');
    await service.switchMessageVariant(
      sessionId: sessionId,
      turnNumber: 1,
      variantIndex: 1,
      assistantMessageId: 'a2',
      factualConfig: const FactualConfig(),
    );
    expect(await ftsCount(), 1);

    final ftsRows = await db.customSelect(
      'SELECT summary FROM memories_fts WHERE session_id = ?',
      variables: [Variable.withString(sessionId)],
    ).get();
    expect(ftsRows.single.readNullable<String>('summary'), '雪山隘口遭遇');
  });

  test('服务层守卫：存在后续轮时拒绝切换（next_turn 单一事实源）', () async {
    await persistVariantRound(
      messageId: 'a1',
      content: '第一版正文。',
      summary: '摘要甲',
      description: '状态甲',
    );
    // 造后续轮：直接推进 next_turn 指针（等价于下游轮已持久化）
    await db.customStatement(
      'UPDATE chat_sessions SET next_turn = 3 WHERE session_id = ?',
      [sessionId],
    );
    final switched = await service.switchMessageVariant(
      sessionId: sessionId,
      turnNumber: 1,
      variantIndex: 0,
      assistantMessageId: 'a1',
      factualConfig: const FactualConfig(),
    );
    expect(switched, isFalse, reason: '后续轮派生无法交换，服务层拒绝');
    expect(await turnSummaries(), ['摘要甲'], reason: '记忆层不被触碰');
  });

  test('只读基线在切换重放中保留', () async {
    // 世界书基线实体 + 只读 description
    await db.customStatement(
      'INSERT INTO factual_entities '
      '(entity_id, session_id, type, primary_name, aliases, importance, '
      'is_archived, source, created_turn, created_at) VALUES '
      "('ent_wb', ?, 'lore', '古碑遗迹', '[]', 5, 0, 'worldbook', 0, "
      "'2026-01-01T00:00:00')",
      [sessionId],
    );
    await db.customStatement(
      'INSERT INTO factual_attributes '
      '(attribute_id, entity_id, session_id, attr_key, value, value_type, '
      'importance, source, created_at) VALUES '
      "('attr_wb', 'ent_wb', ?, 'description', '上古封印之地', 'single', 4, "
      "'worldbook', '2026-01-01T00:00:00')",
      [sessionId],
    );

    await persistVariantRound(
      messageId: 'a1',
      content: '第一版正文。',
      summary: '摘要甲',
      description: '状态甲',
    );
    await service.snapshotMessageVariant(
      sessionId: sessionId,
      turnNumber: 1,
      content: '第一版正文。',
      sourceInput: '推进剧情',
      process: artifactsFor(reply: '第一版正文。'),
    );
    await deleteTurnOne();
    await chatRepo.deleteMessage('a1');
    await persistVariantRound(
      messageId: 'a2',
      content: '第二版正文。',
      summary: '摘要乙',
      description: '状态乙',
      regenerate: true,
    );
    await service.switchMessageVariant(
      sessionId: sessionId,
      turnNumber: 1,
      variantIndex: 0,
      assistantMessageId: 'a2',
      factualConfig: const FactualConfig(),
    );

    final baseline = await db.customSelect(
      'SELECT value FROM factual_attributes WHERE attribute_id = ?',
      variables: [Variable.withString('attr_wb')],
    ).get();
    expect(baseline.single.readNullable<String>('value'), '上古封印之地');
  });
}
