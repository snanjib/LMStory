import 'dart:convert';

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
import 'package:lmstory/features/memory/domain/entities/factual_attribute.dart';
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
import 'package:lmstory/features/memory/domain/entities/factual_source.dart';
import 'package:lmstory/features/memory/domain/services/fact_applier.dart';
import 'package:lmstory/features/story_runtime/data/persistence_service_impl.dart';
import 'package:lmstory/features/story_runtime/domain/entities/round_artifacts.dart';
import 'package:lmstory/features/story_runtime/domain/services/persistence_service.dart';

void main() {
  const acceptedFactName = 'Copper Observatory';
  const acceptedFact = FactsDelta(
    action: FactAction.createEntity,
    entityType: 'location',
    primaryName: acceptedFactName,
    attrKey: 'description',
    value: 'bronze calibration fixture',
    confidence: 5,
  );
  const rejectedFactName = 'Silver Gate';
  const rejectedFactDescription = 'quartz latch fixture';
  const rejectedFact = FactsDelta(
    action: FactAction.createEntity,
    entityType: 'location',
    primaryName: rejectedFactName,
    attrKey: 'description',
    value: rejectedFactDescription,
    confidence: 5,
  );
  late AppDatabase db;
  late ChatRepositoryImpl chat;
  late ExperienceRepositoryImpl experiences;
  late FactualRepositoryImpl facts;
  late StoryPersistenceService service;
  late String sessionId;
  late List<String> rejectedHistoryEntityIds;

  setUp(() async {
    rejectedHistoryEntityIds = [];
    db = AppDatabase.forTesting(
      NativeDatabase.memory(
        setup: (sqlite) => sqlite.createFunction(
          functionName: 'record_rejected_history',
          directOnly: false,
          function: (args) {
            rejectedHistoryEntityIds.add(args.whereType<String>().single);
            return null;
          },
        ),
      ),
    );
    chat = ChatRepositoryImpl(database: db);
    experiences = ExperienceRepositoryImpl(
      database: db,
      vectorEngine: const VectorEngine(),
    );
    facts = FactualRepositoryImpl(database: db);
    service = StoryPersistenceServiceImpl(
      database: db,
      chatRepository: chat,
      experienceRepository: experiences,
      factApplier: FactApplier(repository: facts),
    );
    sessionId = (await chat.createSession(
      title: 'Synthetic story',
      mode: 'intermediate',
    ))
        .sessionId;
  });

  tearDown(() async => db.close());

  Future<void> rejectHistory({
    required String historyValue,
    required String writtenDescription,
  }) =>
      db.customStatement('''
        CREATE TRIGGER reject_history BEFORE INSERT ON factual_memory_history
        WHEN NEW.new_value = '$historyValue'
        BEGIN
          SELECT record_rejected_history(NEW.entity_id)
          WHERE EXISTS (
            SELECT 1 FROM factual_attributes
            WHERE entity_id = NEW.entity_id AND value = '$writtenDescription'
          );
          SELECT RAISE(ABORT, 'synthetic fact history failure');
        END
      ''');

  Future<PersistRoundResult> persistRound(
    int turn,
    List<FactsDelta> deltas, {
    bool regenerate = false,
    FactualConfig factualConfig = const FactualConfig(),
  }) async {
    final createdAt = DateTime(2026, 1, 1, 0, turn);
    final userMessage = ChatMessage(
      messageId: 'u$turn',
      sessionId: sessionId,
      role: 'user',
      content: 'Inspect the gate in round $turn.',
      createdAt: createdAt,
    );
    final assistantMessage = ChatMessage(
      messageId: 'a$turn',
      sessionId: sessionId,
      role: 'assistant',
      content: 'The gate opened in round $turn.',
      createdAt: createdAt.add(const Duration(seconds: 1)),
    );
    final eventSummary = EventSummary(
      summary: 'Gate inspected in round $turn',
      importance: 3,
      tags: const ['gate'],
      turnNumber: turn,
    );
    final artifacts = StoryRoundArtifacts(
      sessionId: sessionId,
      turnNumber: turn,
      createdAt: createdAt,
    );
    if (regenerate) {
      await chat.addMessage(userMessage);
      return service.persistRegeneratedRound(
        assistantMessage: assistantMessage,
        eventSummary: eventSummary,
        embedding: null,
        artifacts: artifacts,
        factsDeltas: deltas,
        factualConfig: factualConfig,
        recordVariant: true,
      );
    }
    return service.persistRound(
      userMessage: userMessage,
      assistantMessage: assistantMessage,
      eventSummary: eventSummary,
      embedding: null,
      artifacts: artifacts,
      factsDeltas: deltas,
      factualConfig: factualConfig,
    );
  }

  Future<void> expectAcceptedRound(int turn, PersistRoundResult result) async {
    final messages = await chat.getMessages(sessionId);
    expect(messages, hasLength(turn * 2));
    expect(messages[turn * 2 - 2].content, 'Inspect the gate in round $turn.');
    expect(messages.last.content, 'The gate opened in round $turn.');
    final savedExperience = await experiences.getExperienceById(
      result.memory.memoryId,
    );
    expect(savedExperience?.summary, 'Gate inspected in round $turn');
    expect(savedExperience?.turnNumber, turn);

    final accepted = (await facts.searchEntitiesByText(
      sessionId,
      [acceptedFact.value!],
    ))
        .single;
    expect(accepted.primaryName, acceptedFact.primaryName);
    final acceptedAttribute =
        (await facts.getAttributes(sessionId, [accepted.entityId])).single;
    expect(acceptedAttribute.value, acceptedFact.value);
    final acceptedHistory = (await facts.getHistory(accepted.entityId)).single;
    expect(acceptedHistory.action, FactAction.createEntity);
    expect(acceptedHistory.newValue, accepted.primaryName);
    expect(acceptedHistory.turnNumber, turn);

    final change = result.factsChanges.single;
    expect(change.entityId, accepted.entityId);
    expect(change.action, FactAction.createEntity);
    expect(change.newValue, accepted.primaryName);
    final saved = (await service.loadArtifactsBySession(sessionId))[turn];
    expect(saved?.factsChanges.map((change) => change.toJson()), [
      change.toJson(),
    ]);
  }

  test('a rejected create history rolls back the new entity and attribute',
      () async {
    await rejectHistory(
      historyValue: rejectedFactName,
      writtenDescription: rejectedFactDescription,
    );

    final result = await persistRound(1, [rejectedFact, acceptedFact]);

    await expectAcceptedRound(1, result);
    expect(result.factWriteFailureCount, 1);
    expect(rejectedHistoryEntityIds, hasLength(1));
    final rejectedId = rejectedHistoryEntityIds.single;
    expect(await facts.getHistory(rejectedId), isEmpty);
    expect(
      {
        'entity': (await facts.getEntityById(rejectedId))?.primaryName,
        'attributes': (await facts.getAttributes(sessionId, [rejectedId])).map(
          (attribute) => attribute.value,
        ),
        'search': (await facts.searchEntitiesByText(
          sessionId,
          ['Silver Gate', 'quartz latch fixture'],
        ))
            .map((entity) => entity.primaryName),
      },
      {'entity': isNull, 'attributes': isEmpty, 'search': isEmpty},
    );

    final nextRound = await persistRound(2, const []);
    expect(nextRound.factWriteFailureCount, 0);
  });

  test('a rejected update history restores the existing fact and FTS results',
      () async {
    const entityId = 'worldbook-fixture';
    const originalDescription = 'indigo tide marker';
    const rejectedDescription = 'vermilion flood marker';
    final createdAt = DateTime(2026);
    await facts.createEntity(
      FactualEntity(
        entityId: entityId,
        sessionId: sessionId,
        type: FactualEntityType.location,
        primaryName: 'Archive Quay',
        aliases: const [],
        source: FactualSource.worldbook,
        importance: 3,
        createdTurn: 0,
        createdAt: createdAt,
      ),
    );
    await facts.createAttribute(
      FactualAttribute(
        attributeId: 'worldbook-baseline-description',
        entityId: entityId,
        sessionId: sessionId,
        attrKey: 'description',
        value: 'basalt foundation marker',
        source: FactualSource.worldbook,
        importance: 4,
        createdAt: createdAt,
      ),
    );
    final firstRound = await persistRound(1, [
      const FactsDelta(
        action: FactAction.updateAttr,
        entityId: entityId,
        attrKey: 'description',
        value: originalDescription,
        reason: 'First visit observes the tide marker',
        confidence: 5,
      ),
    ]);
    expect(firstRound.factWriteFailureCount, 0);
    final originalAttributes = await facts.getAttributes(sessionId, [
      entityId,
    ]);
    final evolvedAttribute = originalAttributes.singleWhere(
      (attribute) => attribute.source == FactualSource.auto,
    );
    expect(evolvedAttribute.value, originalDescription);
    expect(
      (await facts.searchWorldFacts(sessionId, ['indigo']))
          .map((entity) => entity.entityId),
      [entityId],
    );
    await rejectHistory(
      historyValue: rejectedDescription,
      writtenDescription: rejectedDescription,
    );

    final result = await persistRound(2, [
      const FactsDelta(
        action: FactAction.updateAttr,
        entityId: entityId,
        attrKey: 'description',
        value: rejectedDescription,
        reason: 'Second visit observes a different marker',
        confidence: 5,
      ),
      acceptedFact,
    ]);

    await expectAcceptedRound(2, result);
    expect(result.factWriteFailureCount, 1);
    expect(rejectedHistoryEntityIds, [entityId]);
    final history = (await facts.getHistory(entityId)).single;
    expect(history.action, FactAction.updateAttr);
    expect(history.attributeId, evolvedAttribute.attributeId);
    expect(history.newValue, originalDescription);
    expect(history.turnNumber, 1);
    expect(
      {
        'attributes': (await facts.getAttributes(sessionId, [entityId])).map(
          (attribute) => attribute.toJson(),
        ),
        'original FTS': (await facts.searchWorldFacts(
          sessionId,
          ['indigo'],
        ))
            .map((entity) => entity.entityId),
        'rejected FTS': await facts.searchWorldFacts(sessionId, [
          'vermilion',
        ]),
        'rejected fact search': await facts.searchEntitiesByText(sessionId, [
          rejectedDescription,
        ]),
      },
      {
        'attributes': originalAttributes.map((attribute) => attribute.toJson()),
        'original FTS': [entityId],
        'rejected FTS': isEmpty,
        'rejected fact search': isEmpty,
      },
    );
  });

  test('a regenerated round reports every fact write that rolls back',
      () async {
    await rejectHistory(
      historyValue: rejectedFactName,
      writtenDescription: rejectedFactDescription,
    );

    final result = await persistRound(
      1,
      [rejectedFact, rejectedFact, acceptedFact],
      regenerate: true,
    );

    await expectAcceptedRound(1, result);
    expect(result.factWriteFailureCount, 2);
    expect(rejectedHistoryEntityIds.toSet(), hasLength(2));
    for (final entityId in rejectedHistoryEntityIds) {
      expect(await facts.getEntityById(entityId), isNull);
      expect(await facts.getAttributes(sessionId, [entityId]), isEmpty);
      expect(await facts.getHistory(entityId), isEmpty);
    }
    final variants = await service.loadMessageVariants(sessionId);
    expect(variants[1]?.single.content, 'The gate opened in round 1.');
    final variantRow = await db
        .customSelect(
          'SELECT facts_changes FROM message_variants',
        )
        .getSingle();
    expect(jsonDecode(variantRow.read<String>('facts_changes')), [
      result.factsChanges.single.toJson(),
    ]);
  });

  test('ownership guards skip facts without counting failed writes', () async {
    final other = await chat.createSession(
      title: 'Other synthetic story',
      mode: 'intermediate',
    );
    await FactApplier(repository: facts).applyDeltas(
      other.sessionId,
      [acceptedFact],
      1,
      const FactualConfig(),
    );
    final foreign = (await facts.getEntities(other.sessionId)).single;
    const missingId = 'missing-synthetic-fact';
    await rejectHistory(
      historyValue: rejectedFactName,
      writtenDescription: rejectedFactDescription,
    );

    final result = await persistRound(1, [
      for (final id in [foreign.entityId, missingId])
        FactsDelta(
          action: FactAction.updateAttr,
          entityId: id,
          attrKey: 'description',
          value: 'unexpected change outside this story',
          confidence: 5,
        ),
      rejectedFact,
      acceptedFact,
    ]);

    await expectAcceptedRound(1, result);
    expect(
      (await facts.getEntities(sessionId)).single.primaryName,
      acceptedFactName,
    );
    final rejectedId = rejectedHistoryEntityIds.single;
    expect(await facts.getEntityById(rejectedId), isNull);
    expect(await facts.getHistory(rejectedId), isEmpty);
    expect(await facts.getEntityById(missingId), isNull);
    expect(await facts.getHistory(missingId), isEmpty);
    final foreignAttribute =
        (await facts.getAttributes(other.sessionId, [foreign.entityId])).single;
    expect(foreignAttribute.value, acceptedFact.value);
    final foreignHistory = (await facts.getHistory(foreign.entityId)).single;
    expect(foreignHistory.action, FactAction.createEntity);
    expect(foreignHistory.newValue, acceptedFactName);
    expect(result.factWriteFailureCount, 1);
  });

  test('guarded, unchanged and disabled facts do not report write failures',
      () async {
    final firstRound = await persistRound(1, [acceptedFact]);
    expect(firstRound.factWriteFailureCount, 0);
    final entityId =
        (await facts.findByName(sessionId, [acceptedFactName])).single.entityId;

    final skippedRound = await persistRound(2, [
      FactsDelta(
        action: FactAction.updateAttr,
        entityId: entityId,
        attrKey: 'unsupported_field',
        value: 'unsupported value',
        confidence: 5,
      ),
      FactsDelta(
        action: FactAction.updateAttr,
        entityId: entityId,
        attrKey: acceptedFact.attrKey,
        value: acceptedFact.value,
        confidence: 5,
      ),
    ]);
    expect(skippedRound.factsChanges, isEmpty);
    expect(skippedRound.factWriteFailureCount, 0);
    expect((await facts.getHistory(entityId)).single.turnNumber, 1);
    expect(
      (await facts.getAttributes(sessionId, [entityId])).single.value,
      acceptedFact.value,
    );

    await rejectHistory(
      historyValue: rejectedFactName,
      writtenDescription: rejectedFactDescription,
    );
    final disabledRound = await persistRound(
      3,
      [rejectedFact],
      factualConfig: const FactualConfig(enabled: false),
    );
    expect(disabledRound.factsChanges, isEmpty);
    expect(disabledRound.factWriteFailureCount, 0);
    expect(rejectedHistoryEntityIds, isEmpty);
    expect(
      await facts.findByName(sessionId, [rejectedFactName]),
      isEmpty,
    );
  });

  test('a rolled-back round cannot carry its fact failure into a retry',
      () async {
    await rejectHistory(
      historyValue: rejectedFactName,
      writtenDescription: rejectedFactDescription,
    );
    await db.customStatement('''
      CREATE TRIGGER reject_round BEFORE INSERT ON intermediate_round_artifacts
      BEGIN
        SELECT RAISE(ABORT, 'synthetic round failure');
      END
    ''');

    await expectLater(
      persistRound(1, [rejectedFact, acceptedFact]),
      throwsA(
        predicate<Object>(
          (error) => error.toString().contains('synthetic round failure'),
        ),
      ),
    );
    expect(rejectedHistoryEntityIds, hasLength(1));
    expect(await chat.getMessages(sessionId), isEmpty);
    expect(await experiences.getAllExperiences(sessionId), isEmpty);
    expect(await facts.getEntities(sessionId), isEmpty);
    expect(await service.loadArtifactsBySession(sessionId), isEmpty);

    await db.customStatement('DROP TRIGGER reject_round');
    final retried = await persistRound(1, [acceptedFact]);
    expect(retried.factWriteFailureCount, 0);
    await expectAcceptedRound(1, retried);
  });
}
