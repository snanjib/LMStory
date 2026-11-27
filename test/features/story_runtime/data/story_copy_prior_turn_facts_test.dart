import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/core/vector/vector_engine.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/chat/data/repositories/chat_repository_impl.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/memory/data/repositories/experience_repository_impl.dart';
import 'package:lmstory/features/memory/data/repositories/factual_repository_impl.dart';
import 'package:lmstory/features/memory/domain/entities/event_summary.dart';
import 'package:lmstory/features/memory/domain/entities/facts_delta.dart';
import 'package:lmstory/features/memory/domain/services/fact_applier.dart';
import 'package:lmstory/features/story_runtime/data/persistence_service_impl.dart';
import 'package:lmstory/features/story_runtime/domain/entities/round_artifacts.dart';

void main() {
  test('副本切回没有改卡的旧稿时恢复前轮已有的属性', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final chat = ChatRepositoryImpl(database: db);
    final facts = FactualRepositoryImpl(database: db);
    final experiences = ExperienceRepositoryImpl(
      database: db,
      vectorEngine: const VectorEngine(),
    );
    final service = StoryPersistenceServiceImpl(
      database: db,
      chatRepository: chat,
      experienceRepository: experiences,
      factApplier: FactApplier(repository: facts),
    );
    final source =
        (await chat.createSession(title: '山路见闻', mode: 'advanced')).sessionId;
    const config = FactualConfig();
    const firstBody = '陈默向商队介绍山路。';
    const oldBody = '陈默继续给商队引路。';
    const newBody = '陈默离开商队，接手了旅店。';
    const input = '说说陈默的去向。';

    ChatMessage message(String id, String role, String body, int second) =>
        ChatMessage(
          messageId: id,
          sessionId: source,
          role: role,
          content: body,
          createdAt: DateTime.utc(2026, 1, 1, 0, 0, second),
        );

    StoryRoundArtifacts artifacts(int turn, String body) => StoryRoundArtifacts(
          sessionId: source,
          turnNumber: turn,
          createdAt: DateTime.utc(2026),
          replyText: body,
        );

    EventSummary event(int turn, String body) => EventSummary(
          summary: body,
          importance: 3,
          tags: const [],
          turnNumber: turn,
        );

    await service.persistRound(
      userMessage: message('user-1', 'user', '认识陈默。', 1),
      assistantMessage: message('assistant-1', 'assistant', firstBody, 2),
      eventSummary: event(1, firstBody),
      embedding: null,
      artifacts: artifacts(1, firstBody),
      factsDeltas: const [
        FactsDelta(
          action: FactAction.createEntity,
          entityType: 'character',
          primaryName: '陈默',
          attrKey: 'background',
          value: '向导',
          confidence: 5,
        ),
      ],
      factualConfig: config,
    );
    final sourceEntity = (await facts.findByName(source, ['陈默'])).single;
    final initialHistory =
        (await facts.getHistory(sourceEntity.entityId)).single;
    expect(initialHistory.action, FactAction.createEntity);
    expect(initialHistory.attributeId, isNull);

    await service.persistRound(
      userMessage: message('user-2', 'user', input, 3),
      assistantMessage: message('assistant-2a', 'assistant', oldBody, 4),
      eventSummary: event(2, oldBody),
      embedding: null,
      artifacts: artifacts(2, oldBody),
    );
    await service.snapshotMessageVariant(
      sessionId: source,
      turnNumber: 2,
      content: oldBody,
      sourceInput: input,
      process: artifacts(2, oldBody),
    );
    await service.deleteRoundAndDownstream(
      sessionId: source,
      fromTurnNumber: 2,
      messageIdsToDelete: const ['assistant-2a'],
      keepVariantsAtFromTurn: true,
    );

    FactsDelta update(String key, String value) => FactsDelta(
          action: FactAction.updateAttr,
          entityId: sourceEntity.entityId,
          attrKey: key,
          value: value,
          confidence: 5,
        );

    await service.persistRegeneratedRound(
      assistantMessage: message('assistant-2b', 'assistant', newBody, 5),
      eventSummary: event(2, newBody),
      embedding: null,
      artifacts: artifacts(2, newBody),
      factsDeltas: [
        update('background', '商队译员'),
        update('background', '旅店掌柜'),
        update('personality', '开朗健谈'),
        update('personality', '谨慎寡言'),
      ],
      factualConfig: config,
      recordVariant: true,
      variantSourceInput: input,
    );
    final sourceCard =
        await facts.getAttributes(source, [sourceEntity.entityId]);
    final sourceHistory = await facts.getHistory(sourceEntity.entityId);
    expect(sourceHistory.where((entry) => entry.turnNumber == 2).length, 4);

    // SQLite may scan unordered reads in either direction when copying rows.
    await db.customStatement('PRAGMA reverse_unordered_selects = ON');
    final copy = (await chat.copySession(source)).sessionId;
    await db.customStatement('PRAGMA reverse_unordered_selects = OFF');
    final copyEntity = (await facts.findByName(copy, ['陈默'])).single;
    final copyMessage = (await chat.getMessages(copy))
        .singleWhere((message) => message.content == newBody);
    final copyBackground =
        (await facts.getAttributesByKey(copyEntity.entityId, 'background'))
            .single;
    expect(copyBackground.value, '旅店掌柜');

    for (final index in [0, 1, 0]) {
      expect(
        await service.switchMessageVariant(
          sessionId: copy,
          turnNumber: 2,
          variantIndex: index,
          assistantMessageId: copyMessage.messageId,
          factualConfig: config,
        ),
        isTrue,
      );
      final copiedMessages = await chat.getMessages(copy);
      expect(
        copiedMessages
            .singleWhere((m) => m.messageId == copyMessage.messageId)
            .content,
        index == 0 ? oldBody : newBody,
      );
      final backgrounds =
          await facts.getAttributesByKey(copyEntity.entityId, 'background');
      final expectedBackground = index == 0 ? '向导' : '旅店掌柜';
      expect(
        backgrounds.map((attribute) => attribute.value),
        [expectedBackground],
      );
      final background = backgrounds.single;
      expect(background.attributeId, copyBackground.attributeId);
      expect(background.updatedTurn, index == 0 ? isNull : 2);

      final personality =
          await facts.getAttributesByKey(copyEntity.entityId, 'personality');
      expect(
        personality.map((attribute) => attribute.value),
        index == 0 ? isEmpty : ['谨慎寡言'],
      );
      if (index == 0) {
        final history = (await facts.getHistory(copyEntity.entityId)).single;
        expect(history.turnNumber, 1);
        expect(history.action, FactAction.createEntity);
        expect(history.attributeId, isNull);
      }

      expect(
        (await facts.getAttributes(source, [sourceEntity.entityId]))
            .map((attribute) => attribute.toJson()),
        sourceCard.map((attribute) => attribute.toJson()),
      );
      expect(
        (await facts.getHistory(sourceEntity.entityId)).map(
          (entry) => (entry.attributeId, entry.oldValue, entry.newValue),
        ),
        sourceHistory.map(
          (entry) => (entry.attributeId, entry.oldValue, entry.newValue),
        ),
      );
    }
  });
}
