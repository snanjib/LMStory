import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/agent/agent_cancellation.dart';
import 'package:lmstory/core/agent/agent_tool.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_round_draft.dart';
import 'package:lmstory/features/advanced/domain/services/agent_session_tools.dart';
import 'package:lmstory/features/advanced/domain/services/agent_story_reader.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/memory/data/repositories/factual_repository_impl.dart';
import 'package:lmstory/features/memory/domain/entities/experiential_memory.dart';
import 'package:lmstory/features/memory/domain/entities/facts_delta.dart';
import 'package:lmstory/features/memory/domain/entities/factual_memory_changes_snapshot.dart';
import 'package:lmstory/features/memory/domain/entities/factual_memory_history.dart';
import 'package:lmstory/features/memory/domain/repositories/experience_repository.dart';
import 'package:lmstory/features/memory/domain/repositories/factual_repository.dart';
import 'package:lmstory/features/memory/domain/services/fact_applier.dart';

class _NoopExperienceRepository implements ExperienceRepository {
  @override
  Never noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _FailingFactualRepository implements FactualRepository {
  @override
  Future<FactualMemoryChangesSnapshot> readMemoryChangesSnapshot(
    String sessionId,
  ) async =>
      throw StateError('synthetic read failure');

  @override
  Never noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _NoopUserPort implements AgentUserInteractionPort {
  @override
  Future<String?> askUser({required String question, List<String>? options}) =>
      Future<String?>.value();
}

class _StoryReader implements AgentStoryReader {
  _StoryReader(this.rounds);

  final List<AgentStoryRound> rounds;

  @override
  Future<int> totalRounds() async => rounds.length;

  @override
  Future<List<AgentStoryRound>> readAllRounds() async => rounds;

  @override
  Future<List<AgentStoryRound>> readRounds({
    required int fromTurn,
    required int count,
  }) async =>
      rounds
          .where(
            (round) =>
                round.turnNumber >= fromTurn &&
                round.turnNumber < fromTurn + count,
          )
          .toList();
}

AgentToolInvocation _invocation() => AgentToolInvocation(
      callId: 'query-memory-changes-test',
      toolName: 'query_memory_changes',
      stepIndex: 0,
      cancellation: AgentCancellationToken(),
    );

AgentToolDeps _deps({
  required FactualRepository repository,
  required AgentStoryReader storyReader,
  required AgentRoundDraft draft,
}) =>
    AgentToolDeps(
      sessionId: 'story-a',
      draft: draft,
      factualRepository: repository,
      experienceRepository: _NoopExperienceRepository(),
      storyReader: storyReader,
      latestMacros: () async => const <ExperientialMemory>[],
      userInteraction: _NoopUserPort(),
      commitRound: (value) async => value.explicitReply ?? '',
    );

void main() {
  late AppDatabase database;
  late FactualRepositoryImpl repository;
  late FactApplier applier;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    repository = FactualRepositoryImpl(database: database);
    applier = FactApplier(repository: repository);
  });

  tearDown(() async {
    await database.close();
  });

  test('真实事实流水可按当前会话、轮区间、动作和分页回执', () async {
    const config = FactualConfig();
    await applier.applyDeltas(
      'story-a',
      const [
        FactsDelta(
          action: FactAction.createEntity,
          confidence: 5,
          entityType: 'character',
          primaryName: '师姐',
        ),
      ],
      1,
      config,
    );
    final entity = (await repository.getEntities('story-a')).single;
    await applier.applyDeltas(
      'story-a',
      [
        FactsDelta(
          action: FactAction.updateAttr,
          confidence: 5,
          entityId: entity.entityId,
          attrKey: 'background',
          value: '北门',
          reason: '守门',
        ),
      ],
      55,
      config,
    );
    await applier.applyDeltas(
      'story-a',
      [
        FactsDelta(
          action: FactAction.appendList,
          confidence: 5,
          entityId: entity.entityId,
          attrKey: 'skills',
          value: '地图',
          reason: '获得物品',
        ),
      ],
      56,
      config,
    );
    await applier.applyDeltas(
      'story-a',
      [
        FactsDelta(
          action: FactAction.appendList,
          confidence: 5,
          entityId: entity.entityId,
          attrKey: 'skills',
          value: '青铜令牌',
          reason: '获得物品',
        ),
      ],
      57,
      config,
    );
    await applier.applyDeltas(
      'story-a',
      [
        FactsDelta(
          action: FactAction.removeFromList,
          confidence: 5,
          entityId: entity.entityId,
          attrKey: 'skills',
          value: '青铜令牌',
          reason: '交还主角',
        ),
      ],
      58,
      config,
    );
    final removedHistory = (await repository.getHistory(entity.entityId))
        .firstWhere((item) => item.turnNumber == 58);
    await database.customStatement(
      'INSERT INTO intermediate_round_artifacts '
      '(session_id, turn_number, facts_changes, generated_text, reply_text, '
      'created_at) VALUES (?, ?, ?, ?, ?, ?)',
      [
        'story-a',
        58,
        jsonEncode([
          {
            'action': 'remove_from_list',
            'confidence': 5,
            'entityId': entity.entityId,
            'primaryName': '师姐',
            'attrKey': 'skills',
            'oldValue': removedHistory.oldValue,
            'newValue': removedHistory.newValue,
            'reason': '交还主角',
          },
        ]),
        '师姐把青铜令牌交还主角。',
        '师姐把青铜令牌交还主角。',
        DateTime(2026).millisecondsSinceEpoch,
      ],
    );
    await repository.insertHistory(
      FactualMemoryHistory(
        entityId: entity.entityId,
        action: FactAction.updateAttr,
        attributeId: removedHistory.attributeId,
        oldValue: '迁移前',
        newValue: '迁移后',
        reason: '关系拆分迁移：个人关系按对象拆出',
        confidence: 5,
        turnNumber: 59,
        createdAt: DateTime(2026, 1, 2),
      ),
    );
    await repository.insertHistory(
      FactualMemoryHistory(
        entityId: entity.entityId,
        action: FactAction.updateAttr,
        attributeId: removedHistory.attributeId,
        oldValue: '["旧值","保留"]',
        newValue: '["新值","保留"]',
        reason: '列表改写',
        confidence: 5,
        turnNumber: 54,
        createdAt: DateTime(2026, 1, 3),
      ),
    );
    await applier.applyDeltas(
      'story-a',
      [
        FactsDelta(
          action: FactAction.archiveEntity,
          confidence: 5,
          entityId: entity.entityId,
          reason: '封存师姐',
        ),
      ],
      60,
      config,
    );

    // 同名对象在另一会话中写入相同字面，查询仍由程序绑定 story-a。
    await applier.applyDeltas(
      'story-b',
      const [
        FactsDelta(
          action: FactAction.createEntity,
          confidence: 5,
          entityType: 'character',
          primaryName: '师姐',
        ),
      ],
      59,
      config,
    );
    final reader = _StoryReader([
      AgentStoryRound(
        turnNumber: 58,
        createdAt: DateTime(2026),
        narrativeText: '师姐把青铜令牌交还主角。',
      ),
    ]);
    final draft = AgentRoundDraft(turnNumber: 60);
    final registeredTools = buildAgentTools(
      _deps(repository: repository, storyReader: reader, draft: draft),
    );
    final tool = registeredTools.firstWhere(
      (candidate) => candidate.name == 'query_memory_changes',
    );

    final result = await tool.invoke(
      _invocation(),
      {'q': '令牌', 'to_turn': 59, 'limit': 1},
    );
    expect(result.isError, isFalse);
    expect(result.metadata?['status'], 'matched');
    expect(result.metadata?['count'], 1);
    expect(result.metadata?['hasNext'], isTrue);
    expect(result.metadata?['cursor'], isA<String>());
    expect(result.output, contains('第 58 轮入账'));
    expect(result.output, contains('remove_from_list'));
    expect(result.output, contains('read_story({"turn":58})'));
    expect(result.output, contains('青铜令牌'));

    final created = await tool.invoke(
      _invocation(),
      {
        'actions': ['create_entity'],
        'entity_name': '师姐',
      },
    );
    expect(created.isError, isFalse);
    expect(created.metadata?['status'], 'matched');
    expect(created.output, contains('create_entity'));

    final updated = await tool.invoke(
      _invocation(),
      {
        'actions': ['update_attr'],
        'q': '北门',
      },
    );
    expect(updated.isError, isFalse);
    expect(updated.metadata?['status'], 'matched');
    expect(updated.output, contains('update_attr'));

    final appended = await tool.invoke(
      _invocation(),
      {
        'actions': ['append_list'],
        'q': '地图',
      },
    );
    expect(appended.isError, isFalse);
    expect(appended.metadata?['status'], 'matched');
    expect(appended.output, contains('append_list'));

    final archived = await tool.invoke(
      _invocation(),
      {
        'actions': ['archive_entity'],
        'q': '封存师姐',
      },
    );
    expect(archived.isError, isFalse);
    expect(archived.metadata?['status'], 'matched');
    expect(archived.output, contains('archive_entity'));
    expect(archived.output, isNot(contains('可用 read_story')));

    final oldListOnly = await tool.invoke(
      _invocation(),
      {'q': '地图', 'from_turn': 58, 'to_turn': 59},
    );
    expect(oldListOnly.isError, isFalse);
    expect(oldListOnly.metadata?['status'], 'no_match_in_recorded_history');
    expect(oldListOnly.output, contains('没有找到已记录的变更'));

    final migration = await tool.invoke(
      _invocation(),
      {'q': '迁移', 'to_turn': 59},
    );
    expect(migration.isError, isFalse);
    expect(migration.metadata?['status'], 'no_match_in_recorded_history');

    final retainedListMember = await tool.invoke(
      _invocation(),
      {
        'actions': ['update_attr'],
        'q': '保留',
        'from_turn': 54,
        'to_turn': 54,
      },
    );
    expect(retainedListMember.isError, isFalse);
    expect(
      retainedListMember.metadata?['status'],
      'no_match_in_recorded_history',
    );

    final next = await tool.invoke(
      _invocation(),
      {
        'q': '令牌',
        'to_turn': 59,
        'limit': 1,
        'cursor': result.metadata?['cursor'],
      },
    );
    expect(next.isError, isFalse);
    expect(next.metadata?['status'], 'matched');
    expect(next.metadata?['hasNext'], isFalse);
    expect(next.output, contains('第 57 轮入账'));

    final recreatedTool = QueryMemoryChangesTool(
      _deps(repository: repository, storyReader: reader, draft: draft),
    );
    final stale = await recreatedTool.invoke(
      _invocation(),
      {
        'q': '令牌',
        'to_turn': 59,
        'limit': 1,
        'cursor': result.metadata?['cursor'],
      },
    );
    expect(stale.isError, isTrue);
    expect(stale.metadata?['status'], 'cursor_stale');

    final invalid = await tool.invoke(
      _invocation(),
      {'from_turn': 'not-a-turn'},
    );
    expect(invalid.isError, isTrue);
    expect(invalid.metadata?['status'], 'invalid_arguments');

    await database.customStatement(
      'INSERT INTO message_variants '
      '(session_id, turn_number, variant_index, content, facts_changes, '
      'created_at) VALUES (?, ?, ?, ?, ?, ?)',
      [
        'story-a',
        58,
        1,
        '师姐把青铜令牌留下。',
        '[]',
        DateTime(2026).millisecondsSinceEpoch,
      ],
    );
    await database.customStatement(
      'UPDATE intermediate_round_artifacts SET current_variant_index = ? '
      'WHERE session_id = ? AND turn_number = ?',
      [1, 'story-a', 58],
    );
    final switchedVariant = await tool.invoke(
      _invocation(),
      {'q': '令牌', 'from_turn': 58, 'to_turn': 58},
    );
    expect(switchedVariant.isError, isFalse);
    expect(switchedVariant.metadata?['status'], 'matched');
    expect(switchedVariant.output, isNot(contains('可用 read_story')));
    expect(
      switchedVariant.output,
      contains('当前正文未能唯一对应这条流水'),
    );

    final otherSession = await repository.getEntities('story-b');
    expect(otherSession, hasLength(1));
    expect(result.output, isNot(contains(otherSession.single.entityId)));
  });

  test('属性键失联时区分历史覆盖不足和可判定的无匹配', () async {
    const config = FactualConfig();
    await applier.applyDeltas(
      'story-a',
      const [
        FactsDelta(
          action: FactAction.createEntity,
          confidence: 5,
          entityType: 'character',
          primaryName: '林岚',
        ),
      ],
      1,
      config,
    );
    final entity = (await repository.getEntities('story-a')).single;
    await applier.applyDeltas(
      'story-a',
      [
        FactsDelta(
          action: FactAction.updateAttr,
          confidence: 5,
          entityId: entity.entityId,
          attrKey: 'background',
          value: '持有蓝钥匙',
        ),
      ],
      2,
      config,
    );
    await applier.applyDeltas(
      'story-a',
      [
        FactsDelta(
          action: FactAction.updateAttr,
          confidence: 5,
          entityId: entity.entityId,
          attrKey: 'personality',
          value: '沉着',
        ),
      ],
      3,
      config,
    );
    final before = await repository.readMemoryChangesSnapshot('story-a');
    final recorded = before.history.singleWhere(
      (item) => item.turnNumber == 2 && item.action == FactAction.updateAttr,
    );
    final recordedAttribute = before.attributes.singleWhere(
      (attr) => attr.attributeId == recorded.attributeId,
    );
    expect(recorded.entityId, entity.entityId);
    expect(recorded.historyId, isNotNull);
    expect(recorded.newValue, '持有蓝钥匙');
    expect(recordedAttribute.attrKey, 'background');
    expect(
      before.attributes.map((attr) => attr.attrKey),
      contains('personality'),
    );

    final tool = QueryMemoryChangesTool(
      _deps(
        repository: repository,
        storyReader: _StoryReader(const []),
        draft: AgentRoundDraft(turnNumber: 4),
      ),
    );
    final scope = {
      'entity_id': entity.entityId,
      'from_turn': 2,
      'to_turn': 2,
      'actions': ['update_attr'],
    };
    final byAttribute = {...scope, 'attr_key': 'personality'};
    final noMatch = await tool.invoke(_invocation(), byAttribute);
    expect(noMatch.isError, isFalse);
    expect(noMatch.metadata?['status'], 'no_match_in_recorded_history');
    expect(noMatch.metadata?['scope'], 'current_story_current_variant');
    expect(noMatch.metadata?['count'], 0);
    expect(noMatch.output, contains('在所查范围内没有找到已记录的变更'));

    // 已留存流水，但查询所需的属性行已删除。
    final deleted = await (database.delete(database.factualAttributesTable)
          ..where(
            (row) => row.attributeId.equals(recordedAttribute.attributeId),
          ))
        .go();
    expect(deleted, 1);
    final after = await repository.readMemoryChangesSnapshot('story-a');
    final orphaned = after.history.singleWhere(
      (item) => item.historyId == recorded.historyId,
    );
    expect(orphaned.attributeId, recordedAttribute.attributeId);
    expect(orphaned.newValue, recorded.newValue);
    expect(after.attributes.map((attr) => attr.attrKey), ['personality']);

    final insufficient = await tool.invoke(_invocation(), byAttribute);
    expect(insufficient.isError, isFalse);
    expect(insufficient.metadata?['status'], 'coverage_insufficient');
    expect(insufficient.metadata?['count'], 0);
    expect(insufficient.metadata?['hasNext'], isFalse);
    expect(insufficient.metadata?['coverage'], isNotNull);
    expect(insufficient.output, contains('已删除或失联的属性键'));

    final withoutAttribute = await tool.invoke(_invocation(), scope);
    expect(withoutAttribute.isError, isFalse);
    expect(withoutAttribute.metadata?['status'], 'matched');
    expect(withoutAttribute.metadata?['count'], 1);
    expect(withoutAttribute.output, contains('持有蓝钥匙'));
    expect(withoutAttribute.output, isNot(contains('沉着')));
  });

  test('游标在流水变化后失效，experience-only 查询诚实降级', () async {
    const config = FactualConfig();
    await applier.applyDeltas(
      'story-a',
      const [
        FactsDelta(
          action: FactAction.createEntity,
          confidence: 5,
          entityType: 'character',
          primaryName: '守门人',
        ),
      ],
      1,
      config,
    );
    final entity = (await repository.getEntities('story-a')).single;
    await applier.applyDeltas(
      'story-a',
      [
        FactsDelta(
          action: FactAction.updateAttr,
          confidence: 5,
          entityId: entity.entityId,
          attrKey: 'background',
          value: '北门',
        ),
      ],
      10,
      config,
    );
    final reader = _StoryReader(const []);
    final draft = AgentRoundDraft(turnNumber: 11);
    final tool = QueryMemoryChangesTool(
      _deps(repository: repository, storyReader: reader, draft: draft),
    );
    final first = await tool.invoke(
      _invocation(),
      {'limit': 1},
    );
    final cursor = first.metadata?['cursor'];
    expect(cursor, isA<String>(), reason: '创建和属性写入形成两条流水');

    await applier.applyDeltas(
      'story-a',
      [
        FactsDelta(
          action: FactAction.updateAttr,
          confidence: 5,
          entityId: entity.entityId,
          attrKey: 'background',
          value: '南门',
        ),
      ],
      12,
      config,
    );
    final stale = await tool.invoke(
      _invocation(),
      {'limit': 1, 'cursor': cursor},
    );
    expect(stale.isError, isTrue);
    expect(stale.metadata?['status'], 'cursor_stale');

    final noHistory = await tool.invoke(
      _invocation(),
      {
        'kinds': ['experience'],
      },
    );
    expect(noHistory.isError, isFalse);
    expect(noHistory.metadata?['status'], 'history_unavailable');
    expect(noHistory.output, contains('经历编辑'));

    final readErrorTool = QueryMemoryChangesTool(
      _deps(
        repository: _FailingFactualRepository(),
        storyReader: reader,
        draft: draft,
      ),
    );
    final readError = await readErrorTool.invoke(_invocation(), const {});
    expect(readError.isError, isTrue);
    expect(readError.metadata?['status'], 'read_error');
  });
}
