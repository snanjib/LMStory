import 'dart:convert';

import 'package:drift/drift.dart' show QueryRow, Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/core/utils/token_counter.dart';
import 'package:lmstory/core/vector/vector_engine.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/chat/data/repositories/chat_repository_impl.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/intermediate/domain/services/intermediate_context_builder.dart';
import 'package:lmstory/features/memory/data/repositories/experience_repository_impl.dart';
import 'package:lmstory/features/memory/domain/entities/event_summary.dart';
import 'package:lmstory/features/memory/domain/entities/scored_memory.dart';
import 'package:lmstory/features/story_runtime/data/persistence_service_impl.dart';
import 'package:lmstory/features/story_runtime/domain/entities/round_artifacts.dart';
import 'package:lmstory/features/story_runtime/domain/services/persistence_service.dart';

void main() {
  const userInput = '追查铜令牌';
  late AppDatabase db;
  late ChatRepositoryImpl chatRepository;
  late ExperienceRepositoryImpl experienceRepository;
  late StoryPersistenceServiceImpl persistence;
  late String sessionId;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    chatRepository = ChatRepositoryImpl(database: db);
    experienceRepository = ExperienceRepositoryImpl(
      database: db,
      vectorEngine: const VectorEngine(),
    );
    persistence = StoryPersistenceServiceImpl(
      database: db,
      chatRepository: chatRepository,
      experienceRepository: experienceRepository,
    );
    final session = await chatRepository.createSession(
      title: '测试故事',
      mode: 'intermediate',
    );
    sessionId = session.sessionId;
  });

  tearDown(() async => db.close());

  Future<PersistRoundResult> persistRound({
    required int turnNumber,
    required String assistantId,
    required String body,
    required String summary,
    bool regenerate = false,
  }) {
    final createdAt = DateTime.utc(2026, 1, turnNumber);
    final assistant = ChatMessage(
      messageId: assistantId,
      sessionId: sessionId,
      role: 'assistant',
      content: body,
      createdAt: createdAt.add(const Duration(seconds: 1)),
    );
    final event = EventSummary(
      summary: summary,
      importance: 3,
      tags: const [],
      turnNumber: turnNumber,
    );
    final artifacts = StoryRoundArtifacts(
      sessionId: sessionId,
      turnNumber: turnNumber,
      createdAt: createdAt,
      replyText: body,
      eventSummary: event,
    );
    if (regenerate) {
      return persistence.persistRegeneratedRound(
        assistantMessage: assistant,
        eventSummary: event,
        embedding: null,
        artifacts: artifacts,
        recordVariant: true,
        variantSourceInput: userInput,
        hasVerifiedSourceTurn: true,
      );
    }
    return persistence.persistRound(
      userMessage: ChatMessage(
        messageId: 'u$turnNumber',
        sessionId: sessionId,
        role: 'user',
        content: userInput,
        createdAt: createdAt,
      ),
      assistantMessage: assistant,
      eventSummary: event,
      embedding: null,
      artifacts: artifacts,
      variantSourceInput: userInput,
      hasVerifiedSourceTurn: true,
    );
  }

  Future<int> archiveForRegeneration({
    required int turnNumber,
    required String assistantId,
    required String body,
  }) async {
    final variantIndex = await persistence.snapshotMessageVariant(
      sessionId: sessionId,
      turnNumber: turnNumber,
      content: body,
      sourceInput: userInput,
    );
    await persistence.deleteRoundAndDownstream(
      sessionId: sessionId,
      fromTurnNumber: turnNumber,
      messageIdsToDelete: [assistantId],
      keepVariantsAtFromTurn: true,
    );
    return variantIndex;
  }

  Future<int> currentVariantIndex(int turnNumber) async {
    final artifacts = await persistence.loadArtifactsBySession(sessionId);
    return artifacts[turnNumber]?.currentVariantIndex ?? fail('缺少当前稿号');
  }

  Future<QueryRow> readVariant(int turnNumber, int variantIndex) =>
      db.customSelect(
        'SELECT * FROM message_variants '
        'WHERE session_id = ? AND turn_number = ? AND variant_index = ?',
        variables: [
          Variable.withString(sessionId),
          Variable.withInt(turnNumber),
          Variable.withInt(variantIndex),
        ],
      ).getSingle();

  Future<List<String>> assembleRetrievedMemories() async {
    const prompts = PromptsConfig();
    final retrieved = await experienceRepository.searchExperiencesBySubstring(
      sessionId,
      ['令牌'],
    );
    final scored = [
      for (final memory in retrieved)
        ScoredMemory(
          memory: memory,
          fts5Score: 0,
          vectorScore: 0,
          temporalScore: 0,
          finalScore: 0,
        ),
    ];
    final builder = IntermediateContextBuilder(
      tokenCounter: _CharacterTokenCounter(),
    );
    final generate = await builder.buildGeneratePromptAssembly(
      userInput: '继续调查',
      history: const [],
      sessionSystemPrompt: '角色设定',
      contextWindow: 100000,
      maxTokens: 100,
      prompts: prompts,
      retrievedMemories: scored,
      factBlock: '',
      currentTurnNumber: 3,
    );
    final review = await builder.buildReviewPromptAssembly(
      userInput: '继续调查',
      generated: '她走进房间。',
      retrievedMemories: scored,
      sessionSystemPrompt: '角色设定',
      contextWindow: 100000,
      maxTokens: 100,
      currentTurnNumber: 3,
      prompts: prompts,
    );
    return [
      for (final assembly in [generate, review])
        assembly.messages
            .where((message) => message['role'] == 'system')
            .map((message) => message['content'] ?? '')
            .singleWhere(
              (content) => content.startsWith(prompts.memoriesInjectionTitle),
            ),
    ];
  }

  test('仅保存修改再重生成，切回原稿号不会恢复旧摘要的出处', () async {
    const targetTurn = 2;
    const unrelatedSummary = '门上挂着令牌';
    const originalBody = '她收起了铜令牌。';
    const originalSummary = '她收起令牌';
    const regeneratedBody = '她交出了铜令牌。';
    const regeneratedSummary = '她交出令牌';
    const editedBody = '她熔毁了铜令牌。';

    await persistRound(
      turnNumber: 1,
      assistantId: 'prior',
      body: '他们看到一面令牌挂在门上。',
      summary: unrelatedSummary,
    );
    await persistRound(
      turnNumber: targetTurn,
      assistantId: 'original',
      body: originalBody,
      summary: originalSummary,
    );
    final originalIndex = await archiveForRegeneration(
      turnNumber: targetTurn,
      assistantId: 'original',
      body: originalBody,
    );
    final regenerated = await persistRound(
      turnNumber: targetTurn,
      assistantId: 'regenerated',
      body: regeneratedBody,
      summary: regeneratedSummary,
      regenerate: true,
    );
    final editedIndex = await currentVariantIndex(targetTurn);
    final variantBeforeEdit = await readVariant(targetTurn, editedIndex);
    expect(regenerated.memory.hasVerifiedSourceTurn, isTrue);

    expect(
      await persistence.updateAssistantContentAndCurrentVariant(
        sessionId: sessionId,
        turnNumber: targetTurn,
        assistantMessageId: 'regenerated',
        newContent: editedBody,
      ),
      isTrue,
    );
    final activeAfterEdit = await experienceRepository.getExperienceById(
      regenerated.memory.memoryId,
    );
    expect(activeAfterEdit?.summary, regeneratedSummary);
    expect(activeAfterEdit?.hasVerifiedSourceTurn, isFalse);
    final variantAfterEdit = await readVariant(targetTurn, editedIndex);

    await archiveForRegeneration(
      turnNumber: targetTurn,
      assistantId: 'regenerated',
      body: editedBody,
    );
    await persistRound(
      turnNumber: targetTurn,
      assistantId: 'latest',
      body: '她摔碎了铜令牌。',
      summary: '她摔碎令牌',
      regenerate: true,
    );

    Future<void> switchTo(int variantIndex) async {
      expect(
        await persistence.switchMessageVariant(
          sessionId: sessionId,
          turnNumber: targetTurn,
          variantIndex: variantIndex,
          assistantMessageId: 'latest',
        ),
        isTrue,
      );
    }

    await switchTo(editedIndex);
    final messages = await chatRepository.getMessages(sessionId);
    expect(
      messages.singleWhere((message) => message.messageId == 'latest').content,
      editedBody,
    );
    expect(
      messages.singleWhere((message) => message.messageId == 'u2').content,
      userInput,
    );
    final editedMemoryBlocks = await assembleRetrievedMemories();
    expect(
      editedMemoryBlocks.map((block) => block.contains('来源第2轮')),
      [false, false],
      reason: '生成和审查均不能标注已改写的稿件',
    );
    expect(editedMemoryBlocks, everyElement(contains('来源第1轮')));
    expect(editedMemoryBlocks, everyElement(contains(unrelatedSummary)));

    final oldSnapshot = jsonDecode(
      variantBeforeEdit.read<String>('experiential_snapshot'),
    ) as List<dynamic>;
    final oldSummary = oldSnapshot.single as Map<String, dynamic>;
    expect(oldSummary['summary'], regeneratedSummary);
    expect(oldSummary['has_verified_source_turn'], 1);
    oldSummary['has_verified_source_turn'] = 0;
    final savedSnapshot =
        variantAfterEdit.read<String>('experiential_snapshot');
    expect(jsonDecode(savedSnapshot), oldSnapshot);
    expect(variantAfterEdit.data, {
      ...variantBeforeEdit.data,
      'content': editedBody,
      'experiential_snapshot': savedSnapshot,
    });

    await switchTo(originalIndex);
    final originalMemoryBlocks = await assembleRetrievedMemories();
    expect(originalMemoryBlocks, everyElement(contains('来源第2轮')));
    expect(originalMemoryBlocks, everyElement(contains(originalSummary)));
  });

  test('无快照或快照结构损坏的旧稿仍可仅保存正文', () async {
    await persistRound(
      turnNumber: 1,
      assistantId: 'original',
      body: '她摸了摸令牌。',
      summary: '她摸了令牌',
    );
    await archiveForRegeneration(
      turnNumber: 1,
      assistantId: 'original',
      body: '她摸了摸令牌。',
    );
    await persistRound(
      turnNumber: 1,
      assistantId: 'regenerated',
      body: '她擦了擦令牌。',
      summary: '她擦了令牌',
      regenerate: true,
    );
    final variantIndex = await currentVariantIndex(1);
    const snapshots = [null, '{', '{"summary":"旧稿摘要"}'];
    for (final (index, snapshot) in snapshots.indexed) {
      await db.customStatement(
        'UPDATE message_variants SET experiential_snapshot = ? '
        'WHERE session_id = ? AND turn_number = ? AND variant_index = ?',
        [snapshot, sessionId, 1, variantIndex],
      );
      final editedBody = '修订正文 $index';
      expect(
        await persistence.updateAssistantContentAndCurrentVariant(
          sessionId: sessionId,
          turnNumber: 1,
          assistantMessageId: 'regenerated',
          newContent: editedBody,
        ),
        isTrue,
      );
      final saved = await readVariant(1, variantIndex);
      expect(saved.read<String>('content'), editedBody);
      expect(saved.readNullable<String>('experiential_snapshot'), snapshot);
    }
  });
}

class _CharacterTokenCounter extends TokenCounter {
  @override
  Future<int> countTokens(String text) async => text.length;

  @override
  Future<List<int>> countTokensForEach(List<String> texts) async =>
      texts.map((text) => text.length).toList();
}
