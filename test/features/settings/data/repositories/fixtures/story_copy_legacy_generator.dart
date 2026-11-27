import 'dart:convert';
import 'dart:io';

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
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
import 'package:lmstory/features/memory/domain/services/fact_applier.dart';
import 'package:lmstory/features/settings/data/repositories/backup_repository_impl.dart';
import 'package:lmstory/features/settings/domain/entities/data_management_models.dart';
import 'package:lmstory/features/story_runtime/data/persistence_service_impl.dart';
import 'package:lmstory/features/story_runtime/domain/entities/round_artifacts.dart';

class Harness {
  Harness(this.db) {
    chat = ChatRepositoryImpl(database: db);
    experience = ExperienceRepositoryImpl(
      database: db,
      vectorEngine: const VectorEngine(),
    );
    facts = FactualRepositoryImpl(database: db);
    persistence = StoryPersistenceServiceImpl(
      database: db,
      chatRepository: chat,
      experienceRepository: experience,
      factApplier: FactApplier(repository: facts),
    );
    backup = BackupRepositoryImpl(database: db);
  }
  final AppDatabase db;
  late final ChatRepositoryImpl chat;
  late final ExperienceRepositoryImpl experience;
  late final FactualRepositoryImpl facts;
  late final StoryPersistenceServiceImpl persistence;
  late final BackupRepositoryImpl backup;

  Future<String> seed({required String tag, required bool withFacts}) async {
    final session =
        await chat.createSession(title: '合成故事$tag', mode: 'advanced');
    final sid = session.sessionId;
    final entityId = 'legacy-entity-$tag';
    if (withFacts) {
      await facts.createEntity(
        FactualEntity(
          entityId: entityId,
          sessionId: sid,
          type: FactualEntityType.character,
          primaryName: '陈默',
          aliases: const [],
          importance: 3,
          createdTurn: 0,
          createdAt: DateTime(2026),
        ),
      );
    }
    StoryRoundArtifacts artifacts(String body) => StoryRoundArtifacts(
          sessionId: sid,
          turnNumber: 1,
          createdAt: DateTime(2026),
          replyText: body,
        );
    List<FactsDelta> deltas(String value) => withFacts
        ? [
            FactsDelta(
              action: FactAction.updateAttr,
              entityId: entityId,
              attrKey: 'background',
              value: value,
              confidence: 5,
              importance: 4,
            ),
          ]
        : [];
    EventSummary event(String summary) => EventSummary(
          summary: summary,
          importance: 3,
          tags: const [],
          turnNumber: 1,
        );
    ChatMessage assistant(String id, String body) => ChatMessage(
          messageId: '$tag-$id',
          sessionId: sid,
          role: 'assistant',
          content: body,
          createdAt: DateTime(2026),
        );
    await persistence.persistRound(
      userMessage: ChatMessage(
        messageId: '$tag-user',
        sessionId: sid,
        role: 'user',
        content: '推进剧情',
        createdAt: DateTime(2026),
      ),
      assistantMessage: assistant('a1', '陈默活着的版本'),
      eventSummary: event('陈默存活的旧稿摘要'),
      embedding: null,
      artifacts: artifacts('陈默活着的版本'),
      factsDeltas: deltas('陈默存活'),
      factualConfig: const FactualConfig(),
    );
    await persistence.snapshotMessageVariant(
      sessionId: sid,
      turnNumber: 1,
      content: '陈默活着的版本',
      sourceInput: '推进剧情',
      process: artifacts('陈默活着的版本'),
    );
    await persistence.deleteRoundAndDownstream(
      sessionId: sid,
      fromTurnNumber: 1,
      messageIdsToDelete: const [],
      keepVariantsAtFromTurn: true,
    );
    await chat.deleteMessage('$tag-a1');
    await persistence.persistRegeneratedRound(
      assistantMessage: assistant('a2', '陈默战死的版本'),
      eventSummary: event('陈默战死的新稿摘要'),
      embedding: null,
      artifacts: artifacts('陈默战死的版本'),
      factsDeltas: deltas('陈默战死'),
      factualConfig: const FactualConfig(),
      recordVariant: true,
    );
    return sid;
  }
}

void main() {
  test('generate baseline legacy synthetic backups', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final h = Harness(db);
    final memorySource = await h.seed(tag: 'memory', withFacts: false);
    final memoryOne = await h.chat.copySession(memorySource);
    final memoryTwo = await h.chat.copySession(memorySource);
    final factSource = await h.seed(tag: 'fact', withFacts: true);
    final factCopy = await h.chat.copySession(factSource);
    final sourceBackup = await h.backup.exportSessionData(factSource);
    final copyBackup = await h.backup.exportSessionData(factCopy.sessionId);
    final factAssistant = (await h.chat.getMessages(factCopy.sessionId))
        .singleWhere((m) => m.role == 'assistant');
    final switched = await h.persistence.switchMessageVariant(
      sessionId: factCopy.sessionId,
      turnNumber: 1,
      variantIndex: 0,
      assistantMessageId: factAssistant.messageId,
      factualConfig: const FactualConfig(),
    );
    expect(switched, isTrue);
    final sourceAfterCorruption = await h.backup.exportSessionData(factSource);
    final variants = await h.backup.exportSessionData(memoryOne.sessionId);
    final fixture = {
      'producer': '564a5e8f85a232542221a844964c69eb38cd5a4e',
      'memorySource': await h.backup.exportSessionData(memorySource),
      'memoryOne': variants,
      'memoryTwo': await h.backup.exportSessionData(memoryTwo.sessionId),
      'factSource': sourceBackup,
      'factCopy': copyBackup,
      'factSourceAfterCorruption': sourceAfterCorruption,
    };
    final fixtureDirectory =
        await Directory.systemTemp.createTemp('story-copy-legacy-fixture-');
    final path = '${fixtureDirectory.path}/story_copy_legacy_v55.json';
    await File(path)
        .writeAsString(const JsonEncoder.withIndent('  ').convert(fixture));
    final sqlitePath = '${fixtureDirectory.path}/story_copy_legacy_v55.sqlite';
    final oldDb = AppDatabase.forTesting(NativeDatabase(File(sqlitePath)));
    final oldHarness = Harness(oldDb);
    await oldHarness.backup
        .importSessionData(sourceAfterCorruption, mode: ImportMode.append);
    final version = await oldDb.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), 55);
    await oldDb.close();
    final active = (variants['experientialMemories'] as List<dynamic>)
        .cast<Map<String, dynamic>>();
    final firstVariant = (variants['messageVariants'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .first;
    final snapshot = jsonDecode(firstVariant['experiential_snapshot'] as String)
        as List<dynamic>;
    expect(
      (snapshot.first as Map<String, dynamic>)['memory_id'],
      isNot(active.single['memory_id']),
    );
    final history = (sourceAfterCorruption['factualHistory'] as List<dynamic>)
        .cast<Map<String, dynamic>>();
    expect(history.map((row) => row['new_value']), ['陈默战死', '陈默存活']);
    stdout.writeln('Synthetic fixture directory: ${fixtureDirectory.path}');
    await db.close();
  });
}
