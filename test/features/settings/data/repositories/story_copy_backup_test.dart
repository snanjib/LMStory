import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Variable, driftRuntimeOptions;
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

import 'fixtures/story_copy_legacy_v55.dart';

const _oldBody = '陈默活着的版本';
const _newBody = '陈默战死的版本';
const _oldSummary = '陈默存活的旧稿摘要';
const _newSummary = '陈默战死的新稿摘要';

class _Harness {
  _Harness(this.db) {
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

  Future<String> seed() async {
    final session = await chat.createSession(title: '合成故事', mode: 'advanced');
    final sid = session.sessionId;
    const entityId = 'new-source-entity';
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
    StoryRoundArtifacts artifacts(String body) => StoryRoundArtifacts(
          sessionId: sid,
          turnNumber: 1,
          createdAt: DateTime(2026),
          replyText: body,
        );
    List<FactsDelta> deltas(String value) => [
          FactsDelta(
            action: FactAction.updateAttr,
            entityId: entityId,
            attrKey: 'background',
            value: value,
            confidence: 5,
            importance: 4,
          ),
        ];
    EventSummary event(String summary) => EventSummary(
          summary: summary,
          importance: 3,
          tags: const [],
          turnNumber: 1,
        );
    ChatMessage assistant(String id, String body) => ChatMessage(
          messageId: id,
          sessionId: sid,
          role: 'assistant',
          content: body,
          createdAt: DateTime(2026),
        );

    await persistence.persistRound(
      userMessage: ChatMessage(
        messageId: 'new-user',
        sessionId: sid,
        role: 'user',
        content: '推进剧情',
        createdAt: DateTime(2026),
      ),
      assistantMessage: assistant('new-a1', _oldBody),
      eventSummary: event(_oldSummary),
      embedding: null,
      artifacts: artifacts(_oldBody),
      factsDeltas: deltas('陈默存活'),
      factualConfig: const FactualConfig(),
    );
    await persistence.snapshotMessageVariant(
      sessionId: sid,
      turnNumber: 1,
      content: _oldBody,
      sourceInput: '推进剧情',
      process: artifacts(_oldBody),
    );
    await persistence.deleteRoundAndDownstream(
      sessionId: sid,
      fromTurnNumber: 1,
      messageIdsToDelete: const [],
      keepVariantsAtFromTurn: true,
    );
    await chat.deleteMessage('new-a1');
    await persistence.persistRegeneratedRound(
      assistantMessage: assistant('new-a2', _newBody),
      eventSummary: event(_newSummary),
      embedding: null,
      artifacts: artifacts(_newBody),
      factsDeltas: deltas('陈默战死'),
      factualConfig: const FactualConfig(),
      recordVariant: true,
    );
    return sid;
  }

  Future<bool> switchTo(String sid, int variantIndex) async {
    final assistant = (await chat.getMessages(sid))
        .singleWhere((message) => message.role == 'assistant');
    return persistence.switchMessageVariant(
      sessionId: sid,
      turnNumber: 1,
      variantIndex: variantIndex,
      assistantMessageId: assistant.messageId,
      factualConfig: const FactualConfig(),
    );
  }

  Future<List<String>> fts(String sid, String query) async {
    final results = await experience.searchExperiences(
      sessionId: sid,
      query: query,
      queryVector: null,
      topK: 5,
      fts5Weight: 0.5,
      vectorWeight: 0.5,
      keyEventThreshold: 4,
      keyEventBoost: 1.5,
      normalizationEpsilon: 0.01,
    );
    for (final result in results) {
      expect(result.memory.sessionId, sid);
      expect(result.fts5Score, greaterThan(0));
    }
    return results.map((result) => result.memory.summary ?? '').toList();
  }
}

Map<String, dynamic> _legacy(String key) =>
    (jsonDecode(storyCopyLegacyV55Json) as Map<String, dynamic>)[key]
        as Map<String, dynamic>;

String _sessionId(Map<String, dynamic> data) =>
    (data['session'] as Map<String, dynamic>)['session_id'] as String;

List<Map<String, dynamic>> _rows(Map<String, dynamic> data, String key) =>
    (data[key] as List<dynamic>).cast<Map<String, dynamic>>();

Map<String, dynamic> _variant(Map<String, dynamic> data, int index) =>
    _rows(data, 'messageVariants').singleWhere(
      (row) => row['variant_index'] == index,
    );

List<Map<String, dynamic>> _snapshot(Map<String, dynamic> data, int index) =>
    (jsonDecode(_variant(data, index)['experiential_snapshot'] as String)
            as List<dynamic>)
        .cast<Map<String, dynamic>>();

List<List<Object?>> _project(
  Map<String, dynamic> data,
  String key,
  List<String> columns,
) =>
    _rows(data, key)
        .map((row) => columns.map((column) => row[column]).toList())
        .toList();

Future<void> _expectRestoredRows(
  _Harness h,
  Map<String, dynamic> exported,
) async {
  final restored = await h.backup.exportSessionData(_sessionId(exported));
  for (final entry in <String, List<String>>{
    'messages': ['message_id', 'session_id', 'role', 'content'],
    'experientialMemories': [
      'memory_id',
      'session_id',
      'summary',
      'turn_number',
    ],
    'factualEntities': ['entity_id', 'session_id', 'primary_name'],
    'factualAttributes': [
      'attribute_id',
      'entity_id',
      'session_id',
      'attr_key',
      'value',
    ],
    'factualHistory': [
      'entity_id',
      'attribute_id',
      'action',
      'old_value',
      'new_value',
      'turn_number',
    ],
    'intermediateArtifacts': [
      'session_id',
      'turn_number',
      'current_variant_index',
      'facts_deltas',
    ],
    'messageVariants': [
      'session_id',
      'turn_number',
      'variant_index',
      'content',
      'facts_deltas',
      'experiential_snapshot',
    ],
  }.entries) {
    expect(
      _project(restored, entry.key, entry.value),
      _project(exported, entry.key, entry.value),
      reason: '${entry.key} 必须按业务 ID 实际恢复，不能因冲突静默跳行',
    );
  }
}

Future<String> _expectStory(
  _Harness h,
  String sid, {
  required String body,
  required String summary,
  String? fact,
}) async {
  expect(
    (await h.chat.getMessages(sid))
        .singleWhere((message) => message.role == 'assistant')
        .content,
    body,
  );
  final memories = await h.experience.getAllExperiences(sid);
  expect(memories.length, 1);
  expect(memories.single.summary, summary);
  expect(memories.single.turnNumber, 1);
  final query = summary == _oldSummary ? '陈默存活' : '陈默战死';
  final otherQuery = summary == _oldSummary ? '陈默战死' : '陈默存活';
  expect(await h.fts(sid, query), [summary]);
  expect(await h.fts(sid, otherQuery), isEmpty);
  if (fact != null) {
    final entities = await h.facts.findByName(sid, ['陈默']);
    expect(entities.length, 1);
    final attributes = await h.facts.getAttributesByKey(
      entities.single.entityId,
      'background',
    );
    expect(attributes.map((attribute) => attribute.value), [fact]);
  }
  return memories.single.memoryId;
}

Map<String, dynamic> _factOnlyLegacyCopy({required bool includeLocalAction}) {
  final data = _legacy('factCopy');
  // Keep the legacy foreign fact ID untouched. Make only the memory fixture
  // self-consistent, so memory validation cannot mask a missing fact guard.
  final activeId = _rows(data, 'experientialMemories').single['memory_id'];
  final currentSnapshot = _snapshot(data, 1);
  currentSnapshot.single['memory_id'] = activeId;
  _variant(data, 1)['experiential_snapshot'] = jsonEncode(currentSnapshot);
  _variant(data, 0)['experiential_snapshot'] = null;
  if (includeLocalAction) {
    final target = _variant(data, 0);
    final deltas =
        (jsonDecode(target['facts_deltas'] as String) as List<dynamic>)
          ..insert(0, {
            'action': 'add_alias',
            'confidence': 5,
            'entityId': _rows(data, 'factualEntities').single['entity_id'],
            'value': '本地合成别名',
          });
    target['facts_deltas'] = jsonEncode(deltas);
  }
  return data;
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test('两份新副本分别备份，追加和覆盖后仍独立切稿并可检索', () async {
    final source = _Harness(AppDatabase.forTesting(NativeDatabase.memory()));
    final imported = _Harness(AppDatabase.forTesting(NativeDatabase.memory()));
    addTearDown(source.db.close);
    addTearDown(imported.db.close);
    final sourceId = await source.seed();
    final first = await source.chat.copySession(sourceId);
    final second = await source.chat.copySession(sourceId);
    final firstBackup = await source.backup.exportSessionData(first.sessionId);
    final secondBackup =
        await source.backup.exportSessionData(second.sessionId);

    for (final data in [firstBackup, secondBackup]) {
      expect(_rows(data, 'messages').length, 2);
      expect(_rows(data, 'experientialMemories').length, 1);
      expect(_rows(data, 'factualEntities').length, 1);
      expect(_rows(data, 'factualAttributes').length, 1);
      expect(_rows(data, 'factualHistory').length, 1);
      expect(_rows(data, 'intermediateArtifacts').length, 1);
      expect(_rows(data, 'messageVariants').length, 2);
      expect(
        await imported.backup.importSessionData(data, mode: ImportMode.append),
        2,
      );
      await _expectRestoredRows(imported, data);
    }
    expect(
      _rows(firstBackup, 'experientialMemories').single['memory_id'],
      isNot(_rows(secondBackup, 'experientialMemories').single['memory_id']),
    );
    await _expectStory(
      imported,
      first.sessionId,
      body: _newBody,
      summary: _newSummary,
      fact: '陈默战死',
    );
    await _expectStory(
      imported,
      second.sessionId,
      body: _newBody,
      summary: _newSummary,
      fact: '陈默战死',
    );

    expect(await imported.switchTo(first.sessionId, 0), isTrue);
    final firstOldId = await _expectStory(
      imported,
      first.sessionId,
      body: _oldBody,
      summary: _oldSummary,
      fact: '陈默存活',
    );
    await _expectStory(
      imported,
      second.sessionId,
      body: _newBody,
      summary: _newSummary,
      fact: '陈默战死',
    );
    expect(await imported.switchTo(second.sessionId, 0), isTrue);
    final secondOldId = await _expectStory(
      imported,
      second.sessionId,
      body: _oldBody,
      summary: _oldSummary,
      fact: '陈默存活',
    );
    expect(firstOldId, isNot(secondOldId));

    expect(await imported.switchTo(first.sessionId, 1), isTrue);
    await _expectStory(
      imported,
      first.sessionId,
      body: _newBody,
      summary: _newSummary,
      fact: '陈默战死',
    );
    expect(await imported.switchTo(first.sessionId, 0), isTrue);
    expect(
      await _expectStory(
        imported,
        first.sessionId,
        body: _oldBody,
        summary: _oldSummary,
        fact: '陈默存活',
      ),
      firstOldId,
    );

    final secondBeforeAppend =
        await imported.backup.exportSessionData(second.sessionId);
    expect(
      await imported.backup
          .importSessionData(secondBackup, mode: ImportMode.append),
      -1,
    );
    expect(
      await imported.backup.exportSessionData(second.sessionId),
      secondBeforeAppend,
    );
    expect(
      await imported.backup
          .importSessionData(secondBackup, mode: ImportMode.overwrite),
      2,
    );
    await _expectRestoredRows(imported, secondBackup);
    await _expectStory(
      imported,
      first.sessionId,
      body: _oldBody,
      summary: _oldSummary,
      fact: '陈默存活',
    );
    await _expectStory(
      imported,
      second.sessionId,
      body: _newBody,
      summary: _newSummary,
      fact: '陈默战死',
    );
    expect(await imported.switchTo(second.sessionId, 0), isTrue);
    expect(
      await _expectStory(
        imported,
        second.sessionId,
        body: _oldBody,
        summary: _oldSummary,
        fact: '陈默存活',
      ),
      secondOldId,
    );
    await _expectStory(
      imported,
      second.sessionId,
      body: _oldBody,
      summary: _oldSummary,
      fact: '陈默存活',
    );
    await _expectStory(
      source,
      sourceId,
      body: _newBody,
      summary: _newSummary,
      fact: '陈默战死',
    );

    final beforeAppend =
        await imported.backup.exportSessionData(first.sessionId);
    expect(
      await imported.backup
          .importSessionData(firstBackup, mode: ImportMode.append),
      -1,
    );
    expect(
      await imported.backup.exportSessionData(first.sessionId),
      beforeAppend,
    );
    expect(
      await imported.backup
          .importSessionData(firstBackup, mode: ImportMode.overwrite),
      2,
    );
    await _expectRestoredRows(imported, firstBackup);
    await _expectStory(
      imported,
      first.sessionId,
      body: _newBody,
      summary: _newSummary,
      fact: '陈默战死',
    );
    await _expectStory(
      imported,
      second.sessionId,
      body: _oldBody,
      summary: _oldSummary,
      fact: '陈默存活',
    );
    expect(await imported.switchTo(first.sessionId, 0), isTrue);
    expect(
      await _expectStory(
        imported,
        first.sessionId,
        body: _oldBody,
        summary: _oldSummary,
        fact: '陈默存活',
      ),
      firstOldId,
    );
  });

  test('旧副本在全新库缺少经历身份凭据时拒绝切稿并保留现场', () async {
    final h = _Harness(AppDatabase.forTesting(NativeDatabase.memory()));
    addTearDown(h.db.close);
    final first = _legacy('memoryOne');
    final second = _legacy('memoryTwo');
    final oldSnapshotId = _snapshot(first, 0).single['memory_id'];
    expect(_snapshot(second, 0).single['memory_id'], oldSnapshotId);
    expect(
      _rows(first, 'experientialMemories').single['memory_id'],
      isNot(oldSnapshotId),
    );
    expect(
      _rows(second, 'experientialMemories').single['memory_id'],
      isNot(oldSnapshotId),
    );
    expect(
      _snapshot(first, 1).single['memory_id'],
      isNot(_rows(first, 'experientialMemories').single['memory_id']),
    );
    for (final data in [first, second]) {
      expect(
        await h.backup.importSessionData(data, mode: ImportMode.append),
        2,
      );
      await _expectRestoredRows(h, data);
    }
    final oldIdRows = await h.db.customSelect(
      'SELECT memory_id FROM experiential_memories WHERE memory_id = ?',
      variables: [Variable.withString(oldSnapshotId as String)],
    ).get();
    expect(oldIdRows, isEmpty, reason: '旧 ID 只存在变体快照中，不在空库导入后的活动表');
    final beforeFirst = await h.backup.exportSessionData(_sessionId(first));
    final beforeSecond = await h.backup.exportSessionData(_sessionId(second));
    expect(await h.switchTo(_sessionId(first), 0), isFalse);
    expect(await h.switchTo(_sessionId(second), 0), isFalse);
    expect(await h.backup.exportSessionData(_sessionId(first)), beforeFirst);
    expect(await h.backup.exportSessionData(_sessionId(second)), beforeSecond);
    await _expectStory(
      h,
      _sessionId(first),
      body: _newBody,
      summary: _newSummary,
    );
    await _expectStory(
      h,
      _sessionId(second),
      body: _newBody,
      summary: _newSummary,
    );
  });

  test('旧原生会话的经历身份可证明时仍可往返切稿', () async {
    final h = _Harness(AppDatabase.forTesting(NativeDatabase.memory()));
    addTearDown(h.db.close);
    final data = _legacy('memorySource');
    final sid = _sessionId(data);
    expect(
      _snapshot(data, 1).single['memory_id'],
      _rows(data, 'experientialMemories').single['memory_id'],
    );
    expect(await h.backup.importSessionData(data, mode: ImportMode.append), 2);
    expect(await h.switchTo(sid, 0), isTrue);
    final oldId =
        await _expectStory(h, sid, body: _oldBody, summary: _oldSummary);
    expect(await h.switchTo(sid, 1), isTrue);
    await _expectStory(h, sid, body: _newBody, summary: _newSummary);
    expect(await h.switchTo(sid, 0), isTrue);
    expect(
      await _expectStory(h, sid, body: _oldBody, summary: _oldSummary),
      oldId,
    );
  });

  test('旧快照 ID 已被源会话使用时拒绝恢复且不影响源会话', () async {
    final h = _Harness(AppDatabase.forTesting(NativeDatabase.memory()));
    addTearDown(h.db.close);
    final source = _legacy('memorySource');
    final copy = _legacy('memoryOne');
    expect(
      await h.backup.importSessionData(source, mode: ImportMode.append),
      2,
    );
    expect(await h.switchTo(_sessionId(source), 0), isTrue);
    expect(await h.backup.importSessionData(copy, mode: ImportMode.append), 2);
    final sourceId = await _expectStory(
      h,
      _sessionId(source),
      body: _oldBody,
      summary: _oldSummary,
    );
    expect(sourceId, _snapshot(copy, 0).single['memory_id']);
    final sourceBefore = await h.backup.exportSessionData(_sessionId(source));
    final copyBefore = await h.backup.exportSessionData(_sessionId(copy));
    expect(await h.switchTo(_sessionId(copy), 0), isFalse);
    expect(await h.backup.exportSessionData(_sessionId(source)), sourceBefore);
    expect(await h.backup.exportSessionData(_sessionId(copy)), copyBefore);
    await _expectStory(
      h,
      _sessionId(source),
      body: _oldBody,
      summary: _oldSummary,
    );
    await _expectStory(
      h,
      _sessionId(copy),
      body: _newBody,
      summary: _newSummary,
    );
  });

  for (final mode in ImportMode.values) {
    test('旧备份的活动经历跨会话冲突时拒绝${mode.name}并保留现场', () async {
      final h = _Harness(AppDatabase.forTesting(NativeDatabase.memory()));
      addTearDown(h.db.close);
      final source = _legacy('memorySource');
      final copy = _legacy('memoryOne');
      final sourceId = _sessionId(source);
      final copyId = _sessionId(copy);
      expect(
        await h.backup.importSessionData(source, mode: ImportMode.append),
        2,
      );
      expect(await h.switchTo(sourceId, 0), isTrue);
      final oldId = await _expectStory(
        h,
        sourceId,
        body: _oldBody,
        summary: _oldSummary,
      );
      if (mode == ImportMode.overwrite) {
        expect(
          await h.backup.importSessionData(copy, mode: ImportMode.append),
          2,
        );
      }

      // 旧实现切稿时会让副本复用源会话的经历 ID。
      final snapshot = _snapshot(copy, 0).single;
      expect(snapshot['memory_id'], oldId);
      _rows(copy, 'experientialMemories').single
        ..['memory_id'] = snapshot['memory_id']
        ..['summary'] = snapshot['summary'];
      _rows(copy, 'messages')
              .singleWhere((row) => row['role'] == 'assistant')['content'] =
          _oldBody;
      _rows(copy, 'intermediateArtifacts').single
        ..['current_variant_index'] = 0
        ..['reply_text'] = _oldBody;

      final before = await h.backup.exportAllSessionsData();
      if (mode == ImportMode.overwrite) {
        expect(
          await h.backup.importSessionData(copy, mode: ImportMode.append),
          -1,
        );
      }
      await expectLater(
        h.backup.importSessionData(copy, mode: mode),
        throwsA(
          isA<FormatException>()
              .having((error) => error.source, 'source', isNull)
              .having(
                (error) => error.message,
                'message',
                'Backup experience ID belongs to another session',
              ),
        ),
      );
      expect(await h.backup.exportAllSessionsData(), before);
      expect(await h.fts(sourceId, '陈默存活'), [_oldSummary]);
      expect(await h.fts(copyId, '陈默存活'), isEmpty);
      expect(
        await h.fts(copyId, '陈默战死'),
        mode == ImportMode.overwrite ? [_newSummary] : isEmpty,
      );

      await h.backup.deleteSessionData(sourceId);
      expect(await h.backup.importSessionData(copy, mode: mode), 2);
      await _expectRestoredRows(h, copy);
      expect(
        await _expectStory(h, copyId, body: _oldBody, summary: _oldSummary),
        oldId,
      );
    });
  }

  for (final sourcePresent in [true, false]) {
    test('旧事实外部 ID 无法映射时拒绝整单并回滚，源会话${sourcePresent ? '存在' : '缺失'}', () async {
      final h = _Harness(AppDatabase.forTesting(NativeDatabase.memory()));
      addTearDown(h.db.close);
      final source = _legacy('factSource');
      final copy = _factOnlyLegacyCopy(includeLocalAction: true);
      final target = jsonDecode(_variant(copy, 0)['facts_deltas'] as String)
          as List<dynamic>;
      expect(
        (target.first as Map<String, dynamic>)['entityId'],
        _rows(copy, 'factualEntities').single['entity_id'],
      );
      expect(
        (target.last as Map<String, dynamic>)['entityId'],
        _rows(source, 'factualEntities').single['entity_id'],
      );
      expect(
        (target.first as Map<String, dynamic>)['entityId'],
        isNot((target.last as Map<String, dynamic>)['entityId']),
      );
      if (sourcePresent) {
        expect(
          await h.backup.importSessionData(source, mode: ImportMode.append),
          2,
        );
      }
      expect(
        await h.backup.importSessionData(copy, mode: ImportMode.append),
        2,
      );
      final sourceBefore = sourcePresent
          ? await h.backup.exportSessionData(_sessionId(source))
          : null;
      final copyBefore = await h.backup.exportSessionData(_sessionId(copy));
      expect(await h.switchTo(_sessionId(copy), 0), isFalse);
      expect(await h.backup.exportSessionData(_sessionId(copy)), copyBefore);
      if (sourcePresent) {
        expect(
          await h.backup.exportSessionData(_sessionId(source)),
          sourceBefore,
        );
        await _expectStory(
          h,
          _sessionId(source),
          body: _newBody,
          summary: _newSummary,
          fact: '陈默战死',
        );
      }
      await _expectStory(
        h,
        _sessionId(copy),
        body: _newBody,
        summary: _newSummary,
        fact: '陈默战死',
      );
    });
  }

  test('旧稿中事后插入的提议即使指向本地人物也不能作为生效事实恢复', () async {
    final h = _Harness(AppDatabase.forTesting(NativeDatabase.memory()));
    addTearDown(h.db.close);
    final copy = _factOnlyLegacyCopy(includeLocalAction: true);
    final target = _variant(copy, 0);
    final deltas =
        jsonDecode(target['facts_deltas'] as String) as List<dynamic>;
    (deltas.last as Map<String, dynamic>)['entityId'] =
        _rows(copy, 'factualEntities').single['entity_id'];
    target['facts_deltas'] = jsonEncode(deltas);
    expect(await h.backup.importSessionData(copy, mode: ImportMode.append), 2);
    final sid = _sessionId(copy);
    final before = await h.backup.exportSessionData(sid);
    expect(await h.switchTo(sid, 0), isFalse);
    expect(await h.backup.exportSessionData(sid), before);
    await _expectStory(
      h,
      sid,
      body: _newBody,
      summary: _newSummary,
      fact: '陈默战死',
    );
    expect((await h.facts.findByName(sid, ['陈默'])).single.aliases, isEmpty);
  });

  test('旧版本实际生成的显式事实可在原档和新做的副本各自往返', () async {
    final h = _Harness(AppDatabase.forTesting(NativeDatabase.memory()));
    addTearDown(h.db.close);
    final data = _legacy('factSource');
    final source = _sessionId(data);
    expect(await h.backup.importSessionData(data, mode: ImportMode.append), 2);
    final copy = (await h.chat.copySession(source)).sessionId;
    final sourceEntity =
        (await h.facts.findByName(source, ['陈默'])).single.entityId;
    final copyEntity = (await h.facts.findByName(copy, ['陈默'])).single.entityId;
    expect(copyEntity, isNot(sourceEntity));

    for (final (story, other, entity) in [
      (copy, source, copyEntity),
      (source, copy, sourceEntity),
    ]) {
      final otherBefore = await h.backup.exportSessionData(other);
      for (final index in [0, 1, 0]) {
        final old = index == 0;
        final value = old ? '陈默存活' : '陈默战死';
        expect(await h.switchTo(story, index), isTrue);
        await _expectStory(
          h,
          story,
          body: old ? _oldBody : _newBody,
          summary: old ? _oldSummary : _newSummary,
          fact: value,
        );
        final history = (await h.facts.getHistory(entity)).single;
        expect(history.entityId, entity);
        expect(history.newValue, value);
        expect(await h.backup.exportSessionData(other), otherBefore);
      }
    }
  });

  for (final key in ['skills', 'description']) {
    test('导入旧事实后人物改为设定，缺少属性键或值类型凭据时保留当前稿（$key）', () async {
      final h = _Harness(AppDatabase.forTesting(NativeDatabase.memory()));
      addTearDown(h.db.close);
      final data = _legacy('factSource');
      final target = _variant(data, 0);
      // v55 only carried the proposed attribute key and the audit's scalar value.
      final proposals =
          jsonDecode(target['facts_deltas'] as String) as List<dynamic>;
      final changes =
          jsonDecode(target['facts_changes'] as String) as List<dynamic>;
      (proposals.single as Map<String, dynamic>)
        ..['attrKey'] = key
        ..['value'] = '配药';
      (changes.single as Map<String, dynamic>)
        ..['attrKey'] = key
        ..['newValue'] = '配药';
      target['facts_deltas'] = jsonEncode(proposals);
      target['facts_changes'] = jsonEncode(changes);
      final sid = _sessionId(data);
      expect(
        await h.backup.importSessionData(data, mode: ImportMode.append),
        2,
      );
      final entity = (await h.facts.findByName(sid, ['陈默'])).single;
      await h.facts.updateEntityBasic(
        entityId: entity.entityId,
        type: FactualEntityType.lore,
      );
      final before = await h.backup.exportSessionData(sid);
      expect(await h.switchTo(sid, 0), isFalse);
      expect(await h.backup.exportSessionData(sid), before);
      await _expectStory(
        h,
        sid,
        body: _newBody,
        summary: _newSummary,
        fact: '陈默战死',
      );
    });
  }

  for (final completeIds in [true, false]) {
    test('导入乱序的同轮事实流水时${completeIds ? '依据源 ID' : '保留备份数组顺序'}', () async {
      final h = _Harness(AppDatabase.forTesting(NativeDatabase.memory()));
      addTearDown(h.db.close);
      final data = _legacy('factSourceAfterCorruption');
      final history = _rows(data, 'factualHistory').reversed.toList();
      expect(history.map((row) => row['turn_number']).toSet(), {1});
      if (!completeIds) history.last.remove('id');
      data['factualHistory'] = history;
      final original = jsonEncode(data);

      expect(
        await h.backup.importSessionData(data, mode: ImportMode.append),
        2,
      );
      final restored = await h.db
          .customSelect(
            'SELECT new_value FROM factual_memory_history ORDER BY id',
          )
          .get();
      expect(
        restored.map((row) => row.read<String>('new_value')),
        completeIds ? ['陈默战死', '陈默存活'] : ['陈默存活', '陈默战死'],
      );
      expect(jsonEncode(data), original);
    });
  }

  test('打开旧库不会猜测并改写既有错误事实和流水', () async {
    final temp = await Directory.systemTemp.createTemp('story-copy-legacy-');
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/legacy.sqlite');
    final bytes = gzip.decode(base64Decode(storyCopyLegacyV55SqliteGzip));
    expect(
      bytes.sublist(60, 64),
      [0, 0, 0, 55],
      reason: '样本由旧生产代码生成，真实版本号为 v55',
    );
    await file.writeAsBytes(bytes, flush: true);
    final expected = _legacy('factSourceAfterCorruption');
    final sid = _sessionId(expected);
    final first = _Harness(AppDatabase.forTesting(NativeDatabase(file)));
    final opened = await first.backup.exportSessionData(sid);
    final version =
        await first.db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), AppDatabase.currentSchemaVersion);
    expect(
      _project(
        opened,
        'factualAttributes',
        ['entity_id', 'attribute_id', 'attr_key', 'value', 'updated_turn'],
      ),
      _project(expected, 'factualAttributes', [
        'entity_id',
        'attribute_id',
        'attr_key',
        'value',
        'updated_turn',
      ]),
    );
    expect(
      _project(opened, 'factualHistory', [
        'entity_id',
        'attribute_id',
        'action',
        'old_value',
        'new_value',
        'turn_number',
      ]),
      _project(expected, 'factualHistory', [
        'entity_id',
        'attribute_id',
        'action',
        'old_value',
        'new_value',
        'turn_number',
      ]),
    );
    expect(_project(opened, 'factualHistory', ['new_value']), [
      ['陈默战死'],
      ['陈默存活'],
    ]);
    await _expectStory(
      first,
      sid,
      body: _newBody,
      summary: _newSummary,
      fact: '陈默存活',
    );
    await first.db.close();

    final reopened = _Harness(AppDatabase.forTesting(NativeDatabase(file)));
    addTearDown(reopened.db.close);
    expect(await reopened.backup.exportSessionData(sid), opened);
    await _expectStory(
      reopened,
      sid,
      body: _newBody,
      summary: _newSummary,
      fact: '陈默存活',
    );
  });
}
