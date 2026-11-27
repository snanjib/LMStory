import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/chat/data/repositories/chat_repository_impl.dart';

/// 复制会话继承记忆测试
///
/// 副本不再失忆：事实层三表（实体/属性/审计历史）与经历记忆随会话搬运，
/// 业务 ID 全部重映射（内容等价、ID 不共享），FTS 索引以副本主表重建。
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase db;
  late ChatRepositoryImpl repo;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.customSelect('SELECT 1').get();
    repo = ChatRepositoryImpl(database: db);
    await seedSourceSession(db);
  });

  tearDown(() async {
    await db.close();
  });

  test('副本记忆内容与源等价，业务 ID 全部重映射且全局唯一', () async {
    final copy = await repo.copySession('s1');

    // ---- 实体：条数一致，逐列内容等价，entity_id 全新 ----
    final sourceEntities = await entitiesOf(db, 's1');
    final copyEntities = await entitiesOf(db, copy.sessionId);
    expect(copyEntities, hasLength(sourceEntities.length));
    final copyEntityByOld = <String, Map<String, Object?>>{};
    for (final e in copyEntities) {
      expect(
        e['entity_id'],
        isNot(anyOf(sourceEntities.map((s) => s['entity_id']).toList())),
        reason: '副本实体不得沿用源 entity_id',
      );
      copyEntityByOld[e['primary_name'] as String] = e;
    }
    final oldEntA =
        sourceEntities.firstWhere((e) => e['primary_name'] == '青云门');
    final newEntA = copyEntityByOld['青云门']!;
    expect(newEntA['type'], oldEntA['type']);
    expect(newEntA['aliases'], oldEntA['aliases']);
    expect(newEntA['is_archived'], oldEntA['is_archived']);
    expect(newEntA['importance'], oldEntA['importance']);
    expect(newEntA['force_inject'], oldEntA['force_inject']);
    expect(newEntA['injection_disabled'], oldEntA['injection_disabled']);
    expect(newEntA['source'], oldEntA['source']);
    expect(newEntA['source_ref'], oldEntA['source_ref']);
    expect(newEntA['created_turn'], oldEntA['created_turn']);

    // ---- 属性：attribute_id 全新、entity_id 指向副本实体 ----
    final copyAttributes = await attributesOf(db, copy.sessionId);
    expect(copyAttributes, hasLength(2));
    final copyAttrIds =
        copyAttributes.map((a) => a['attribute_id'] as String).toSet();
    final sourceAttrIds = (await attributesOf(db, 's1'))
        .map((a) => a['attribute_id'] as String)
        .toSet();
    expect(copyAttrIds.intersection(sourceAttrIds), isEmpty);
    for (final attr in copyAttributes) {
      expect(
        copyEntities.map((e) => e['entity_id']),
        contains(attr['entity_id']),
        reason: '副本属性必须指向副本内实体',
      );
      expect(attr['session_id'], copy.sessionId);
    }
    final copySpecies =
        copyAttributes.firstWhere((a) => a['attr_key'] == 'species');
    final oldSpecies = (await attributesOf(db, 's1'))
        .firstWhere((a) => a['attr_key'] == 'species');
    expect(copySpecies['value'], oldSpecies['value']);
    expect(copySpecies['importance'], oldSpecies['importance']);
    expect(copySpecies['update_reason'], oldSpecies['update_reason']);

    // ---- 审计历史：条数一致、entity/attribute 引用重映射 ----
    final copyHistory = await db.customSelect(
      'SELECT h.* FROM factual_memory_history h '
      'JOIN factual_entities e ON e.entity_id = h.entity_id '
      'WHERE e.session_id = ?',
      variables: [Variable.withString(copy.sessionId)],
    ).get();
    expect(copyHistory, hasLength(4), reason: '源 4 条历史全部随会话复制');

    // ---- 经历记忆：memory_id 全新、内容等价、embedding 原样 ----
    final sourceMemories = await memoriesOf(db, 's1');
    final copyMemories = await memoriesOf(db, copy.sessionId);
    expect(copyMemories, hasLength(sourceMemories.length));
    expect(
      copyMemories.map((m) => m['memory_id'] as String).toSet().intersection(
            sourceMemories.map((m) => m['memory_id'] as String).toSet(),
          ),
      isEmpty,
    );
    final oldMicro1 =
        sourceMemories.firstWhere((m) => m['memory_id'] == 'mem_1');
    final newMicro1 = copyMemories.firstWhere(
      (m) => m['summary'] == oldMicro1['summary'] as String,
    );
    expect(newMicro1['importance'], oldMicro1['importance']);
    expect(newMicro1['turn_number'], oldMicro1['turn_number']);
    expect(newMicro1['has_embedding'], 1);
    expect(
      newMicro1['embedding'],
      oldMicro1['embedding'],
      reason: 'embedding BLOB 原样保留（同模型下仍有效）',
    );
    final lowMemory = copyMemories.firstWhere(
      (m) => m['summary'] == '低重要性事件',
    );
    expect(lowMemory['has_embedding'], 0);

    // ---- 全局唯一：两侧全部业务 ID 互不重叠、各自无重复 ----
    final allIds = <String>{
      ...sourceEntities.map((e) => e['entity_id'] as String),
      ...copyEntities.map((e) => e['entity_id'] as String),
      ...copyAttrIds,
      ...sourceAttrIds,
      ...sourceMemories.map((m) => m['memory_id'] as String),
      ...copyMemories.map((m) => m['memory_id'] as String),
    };
    expect(
      allIds.length,
      sourceEntities.length * 2 +
          copyAttrIds.length * 2 +
          sourceMemories.length * 2,
      reason: '两侧 ID 总数无重复（重复会使 Set 长度小于计数和）',
    );
  });

  test('宏记忆 parent_event_ids 指向副本内 micro 记忆，未命中 id 剔除', () async {
    final copy = await repo.copySession('s1');
    final copyMemories = await memoriesOf(db, copy.sessionId);
    final copyIds = copyMemories.map((m) => m['memory_id'] as String).toSet();

    final macro = copyMemories.firstWhere((m) => m['memory_level'] == 'macro');
    final parents =
        (jsonDecode(macro['parent_event_ids'] as String) as List<dynamic>)
            .cast<String>();
    expect(parents, hasLength(2), reason: 'mem_1/mem_2 命中映射，mem_ghost 剔除');
    for (final id in parents) {
      expect(copyIds, contains(id), reason: 'parent_event_ids 必须在副本内可解析');
    }
    // micro 行 parent_event_ids 保持 NULL
    final micro = copyMemories.firstWhere((m) => m['memory_level'] == 'micro');
    expect(micro['parent_event_ids'], null);

    // 源宏记忆保持原引用不动（源不被改写）
    final sourceMacro = (await memoriesOf(db, 's1'))
        .firstWhere((m) => m['memory_level'] == 'macro');
    expect(sourceMacro['parent_event_ids'], '["mem_1","mem_2","mem_ghost"]');
  });

  test('经历快照和活动行共用副本 ID，经历文本和来源字段保留', () async {
    const parentIds = '["mem_old","mem_1","mem_ghost"]';
    const archivedIds = '["mem_2","mem_old","mem_ghost"]';
    await (db.update(db.experientialMemoriesTable)
          ..where((t) => t.memoryId.equals('mem_macro')))
        .write(
      const ExperientialMemoriesTableCompanion(
        parentEventIds: Value(parentIds),
        archivedEventIds: Value(archivedIds),
      ),
    );
    const oldOnly = {
      'memory_id': 'mem_old',
      'summary': 'mem_1',
      'what_text': 'mem_old',
      'embedding': 'AACAPw==',
      'has_embedding': 1,
      'fts_present': 0,
      'has_verified_source_turn': 0,
    };
    const macro = {
      'memory_id': 'mem_macro',
      'snapshot_session_id': 's1',
      'parent_event_ids': parentIds,
      'archived_event_ids': archivedIds,
      'macro_trigger_reason': 'mem_old',
      'fts_present': 1,
      'has_verified_source_turn': 1,
    };
    final snapshot = jsonEncode([oldOnly, macro]);
    await db.into(db.messageVariantsTable).insert(
          MessageVariantsTableCompanion.insert(
            sessionId: 's1',
            turnNumber: 2,
            variantIndex: 0,
            content: const Value('mem_old'),
            experientialSnapshot: Value(snapshot),
            createdAt: 0,
          ),
        );

    final copy = await repo.copySession('s1');
    final active = await memoriesOf(db, copy.sessionId);
    final microOneId =
        active.singleWhere((row) => row['summary'] == '主角拜入青云门')['memory_id'];
    final microTwoId =
        active.singleWhere((row) => row['summary'] == '低重要性事件')['memory_id'];
    final activeMacro =
        active.singleWhere((row) => row['memory_level'] == 'macro');
    final variant =
        (await rowsOf(db, 'message_variants', copy.sessionId)).single;
    final copiedSnapshot =
        (jsonDecode(variant['experiential_snapshot'] as String)
                as List<Object?>)
            .cast<Map<String, Object?>>();
    final oldOnlyId = copiedSnapshot.first['memory_id'];

    expect(oldOnlyId, isA<String>());
    expect(oldOnlyId, isNot(anyOf('mem_old', 'mem_1', 'mem_2', 'mem_macro')));
    expect(active.map((row) => row['memory_id']), isNot(contains(oldOnlyId)));
    expect(variant['content'], 'mem_old');
    final expectedParents = jsonEncode([oldOnlyId, microOneId]);
    final expectedArchived = jsonEncode([microTwoId, oldOnlyId]);
    expect(activeMacro['parent_event_ids'], expectedParents);
    expect(activeMacro['archived_event_ids'], expectedArchived);
    expect(copiedSnapshot, [
      {
        ...oldOnly,
        'memory_id': oldOnlyId,
        'snapshot_session_id': copy.sessionId,
      },
      {
        ...macro,
        'memory_id': activeMacro['memory_id'],
        'snapshot_session_id': copy.sessionId,
        'parent_event_ids': expectedParents,
        'archived_event_ids': expectedArchived,
      },
    ]);
    final sourceVariant = (await rowsOf(db, 'message_variants', 's1')).single;
    expect(sourceVariant['experiential_snapshot'], snapshot);
  });

  test('两个稿件表重写事实引用，保留未知引用和历史展示', () async {
    const liveCreate = {
      'action': 'create_entity',
      'entityType': 'character',
      'primaryName': '旺财',
      'replayCreatedId': 'ent_b',
      'confidence': 5,
    };
    const liveUpdate = {
      'action': 'update_attr',
      'entityId': 'ent_b',
      'attrKey': 'species',
      'value': 'ent_b',
      'reason': 'ent_old',
      'confidence': 5,
    };
    const oldCreate = {
      'action': 'create_entity',
      'entityType': 'character',
      'primaryName': 'ent_b',
      'replayCreatedId': 'ent_old',
      'confidence': 5,
    };
    const oldAlias = {
      'action': 'add_alias',
      'entityId': 'ent_old',
      'value': 'ent_old',
      'confidence': 5,
    };
    const unprovenAlias = {
      'action': 'add_alias',
      'entityId': 'ent_unproven',
      'value': 'ent_b',
      'confidence': 5,
    };
    final display = jsonEncode([
      {
        'action': 'create_entity',
        'entityId': 'ent_unproven',
        'entityName': '旺财',
      },
    ]);
    final artifactsDeltas = jsonEncode([liveCreate, liveUpdate, oldAlias]);
    final variantDeltas = jsonEncode([
      liveUpdate,
      oldCreate,
      oldAlias,
      unprovenAlias,
    ]);
    await db.into(db.intermediateRoundArtifactsTable).insert(
          IntermediateRoundArtifactsTableCompanion.insert(
            sessionId: 's1',
            turnNumber: 2,
            generatedText: const Value('ent_b'),
            factsChanges: Value(display),
            factsDeltas: Value(artifactsDeltas),
            createdAt: 0,
          ),
        );
    await db.into(db.messageVariantsTable).insert(
          MessageVariantsTableCompanion.insert(
            sessionId: 's1',
            turnNumber: 2,
            variantIndex: 0,
            factsChanges: Value(display),
            factsDeltas: Value(variantDeltas),
            createdAt: 0,
          ),
        );

    final copy = await repo.copySession('s1');
    final liveId = (await entitiesOf(db, copy.sessionId))
        .singleWhere((row) => row['primary_name'] == '旺财')['entity_id'];
    final artifacts =
        (await rowsOf(db, 'intermediate_round_artifacts', copy.sessionId))
            .single;
    final variant =
        (await rowsOf(db, 'message_variants', copy.sessionId)).single;
    final copiedDeltas =
        (jsonDecode(variant['facts_deltas'] as String) as List<Object?>)
            .cast<Map<String, Object?>>();
    final oldId = copiedDeltas[1]['replayCreatedId'];
    expect(oldId, isA<String>());
    expect(oldId, isNot(anyOf('ent_old', liveId)));
    expect(copiedDeltas, [
      {...liveUpdate, 'entityId': liveId},
      {...oldCreate, 'replayCreatedId': oldId},
      {...oldAlias, 'entityId': oldId},
      unprovenAlias,
    ]);
    expect(jsonDecode(artifacts['facts_deltas'] as String), [
      {...liveCreate, 'replayCreatedId': liveId},
      {...liveUpdate, 'entityId': liveId},
      {...oldAlias, 'entityId': oldId},
    ]);
    expect(artifacts['generated_text'], 'ent_b');
    expect(artifacts['facts_changes'], display);
    expect(variant['facts_changes'], display);
    final sourceVariant = (await rowsOf(db, 'message_variants', 's1')).single;
    expect(sourceVariant['facts_deltas'], variantDeltas);
  });

  test('不复制指向外部实体或悬空实体的旧属性', () async {
    await db.customStatement(
      "INSERT INTO chat_sessions (session_id, title) VALUES ('s2', '外部')",
    );
    await db.customStatement(
      'INSERT INTO factual_entities (entity_id, session_id, type, '
      "primary_name, created_turn) VALUES ('ent_foreign', 's2', 'character', "
      "'旺财', 1)",
    );
    await db.customStatement(
      'INSERT INTO factual_attributes '
      '(attribute_id, entity_id, session_id, attr_key, value) VALUES '
      "('attr_foreign', 'ent_foreign', 's1', 'species', '边牧'), "
      "('attr_dangling', 'ent_missing', 's1', 'species', '狸花')",
    );
    final sourceAttributes = await attributesOf(db, 's1');

    final copy = await repo.copySession('s1');

    expect(
      (await attributesOf(db, copy.sessionId)).map((row) => row['value']),
      unorderedEquals(['修仙门派', '金毛']),
    );
    expect(await attributesOf(db, 's1'), sourceAttributes);
  });

  test('FTS 索引以副本主表重建：factual_fts 仅世界书词条且指向新 id', () async {
    final copy = await repo.copySession('s1');
    final copyEntities = await entitiesOf(db, copy.sessionId);
    final newEntAId = copyEntities
        .firstWhere((e) => e['primary_name'] == '青云门')['entity_id'] as String;

    final factualFts = await db.customSelect(
      'SELECT primary_name, entity_id, session_id FROM factual_fts '
      'WHERE session_id = ?',
      variables: [Variable.withString(copy.sessionId)],
    ).get();
    expect(factualFts, hasLength(1), reason: '仅 worldbook 词条入 factual_fts');
    expect(factualFts.single.read<String>('primary_name'), '青云门');
    expect(factualFts.single.read<String>('entity_id'), newEntAId);

    final memoriesFts = await db.customSelect(
      'SELECT COUNT(*) AS c FROM memories_fts WHERE session_id = ?',
      variables: [Variable.withString(copy.sessionId)],
    ).get();
    final copyMemoryCount = (await memoriesOf(db, copy.sessionId)).length;
    expect(memoriesFts.single.read<int>('c'), copyMemoryCount);
  });

  test('删任一侧不影响另一侧（副本记忆独立）', () async {
    final copy = await repo.copySession('s1');

    await repo.deleteSession(copy.sessionId);
    expect(await memoriesOf(db, 's1'), isNotEmpty);
    expect(await entitiesOf(db, 's1'), isNotEmpty);
    final copyMemoryLeak = await db.customSelect(
      'SELECT COUNT(*) AS c FROM experiential_memories '
      'WHERE session_id != ?',
      variables: [Variable.withString('s1')],
    ).get();
    expect(
      copyMemoryLeak.single.read<int>('c'),
      0,
      reason: '删副本须连带清掉副本记忆与 FTS 行',
    );

    final copy2 = await repo.copySession('s1');
    await repo.deleteSession('s1');
    expect(await memoriesOf(db, copy2.sessionId), isNotEmpty);
    expect(await entitiesOf(db, copy2.sessionId), isNotEmpty);
  });

  test('复制中途失败整体回滚：不留半份副本（实体已插、记忆未插场景）', () async {
    final flaky = _FailMemoriesInsert();
    final flakyDb =
        AppDatabase.forTesting(NativeDatabase.memory().interceptWith(flaky));
    await flakyDb.customSelect('SELECT 1').get();
    addTearDown(flakyDb.close);
    final flakyRepo = ChatRepositoryImpl(database: flakyDb);
    await seedSourceSession(flakyDb);

    flaky.armed = true;
    await expectLater(
      flakyRepo.copySession('s1'),
      throwsA(isA<Exception>()),
    );

    // 会话行：只剩源
    final sessions = await flakyDb
        .customSelect('SELECT COUNT(*) AS c FROM chat_sessions')
        .get();
    expect(sessions.single.read<int>('c'), 1);
    // 事实层：只有源的行数（中途插入的实体/属性/历史全部回滚）
    final entities = await flakyDb
        .customSelect('SELECT COUNT(*) AS c FROM factual_entities')
        .get();
    expect(entities.single.read<int>('c'), 2);
    final attributes = await flakyDb
        .customSelect('SELECT COUNT(*) AS c FROM factual_attributes')
        .get();
    expect(attributes.single.read<int>('c'), 2);
    final history = await flakyDb
        .customSelect('SELECT COUNT(*) AS c FROM factual_memory_history')
        .get();
    expect(history.single.read<int>('c'), 4);
    // 经历层与 FTS：无残留
    final memories = await flakyDb
        .customSelect('SELECT COUNT(*) AS c FROM experiential_memories')
        .get();
    expect(memories.single.read<int>('c'), 3);
    for (final table in ['memories_fts', 'factual_fts']) {
      final rows =
          await flakyDb.customSelect('SELECT COUNT(*) AS c FROM $table').get();
      expect(rows.single.read<int>('c'), 0, reason: '$table 不得残留副本行');
    }
  });
}

/// 在 's1' 上布防源数据：
/// - 实体：青云门（worldbook 投影，source_ref=wb_1，常驻+注入停用+别名）、
///   旺财（auto，含归档标记）；
/// - 属性：青云门 description（worldbook）、旺财 species（auto，带审计字段）；
/// - 历史：4 条（CREATE_ENTITY 无属性、UPDATE_ATTR 带属性、指向悬空属性、
///   普通一条）——覆盖 NULL 保持与映射外置 NULL 两条路径；
/// - 经历记忆：micro×2（一有一无 embedding）+ macro×1
///   （parent_event_ids 含可命中/不可命中 id）。
Future<void> seedSourceSession(AppDatabase db) async {
  await db.customStatement(
    "INSERT INTO chat_sessions (session_id, title) VALUES ('s1', '源')",
  );
  await db.customStatement(
    'INSERT INTO factual_entities (entity_id, session_id, type, primary_name, '
    'aliases, importance, is_archived, source, source_ref, force_inject, '
    'injection_disabled, created_turn) '
    "VALUES ('ent_a', 's1', 'lore', '青云门', '[\"青云剑派\"]', 5, 0, "
    "'worldbook', 'wb_1', 'world', 1, 1)",
  );
  await db.customStatement(
    'INSERT INTO factual_entities (entity_id, session_id, type, primary_name, '
    'aliases, importance, is_archived, source, force_inject, '
    'injection_disabled, created_turn) '
    "VALUES ('ent_b', 's1', 'character', '旺财', '[]', 3, 1, "
    "'auto', 'none', 0, 2)",
  );
  await db.customStatement(
    'INSERT INTO factual_attributes (attribute_id, entity_id, session_id, '
    'attr_key, value, importance, source, update_reason) '
    "VALUES ('attr_a1', 'ent_a', 's1', 'description', '修仙门派', 3, "
    "'worldbook', NULL)",
  );
  await db.customStatement(
    'INSERT INTO factual_attributes (attribute_id, entity_id, session_id, '
    'attr_key, value, value_type, importance, source, '
    'updated_turn, update_reason) '
    "VALUES ('attr_b1', 'ent_b', 's1', 'species', '金毛', 'single', 4, "
    "'auto', 5, '第一轮登场')",
  );
  await db.customStatement(
    'INSERT INTO factual_memory_history (entity_id, action, turn_number) '
    "VALUES ('ent_a', 'CREATE_ENTITY', 1)",
  );
  await db.customStatement(
    'INSERT INTO factual_memory_history (entity_id, attribute_id, action, '
    'old_value, new_value, reason, confidence, turn_number) '
    "VALUES ('ent_b', 'attr_b1', 'UPDATE_ATTR', '拉布拉多', '金毛', "
    "'第5轮确认为金毛', 5, 5)",
  );
  await db.customStatement(
    'INSERT INTO factual_memory_history (entity_id, attribute_id, action, '
    "turn_number) VALUES ('ent_b', 'attr_ghost', 'UPDATE_ATTR', 6)",
  );
  await db.customStatement(
    'INSERT INTO factual_memory_history (entity_id, action, turn_number) '
    "VALUES ('ent_b', 'ADD_ALIAS', 7)",
  );

  final embeddingBytes = Uint8List.fromList(
    Float32List.fromList(List.filled(8, 0.5)).buffer.asUint8List(),
  );
  await db.customStatement(
    'INSERT INTO experiential_memories (memory_id, session_id, summary, '
    'importance, turn_number, embedding, has_embedding) '
    "VALUES ('mem_1', 's1', '主角拜入青云门', 4, 1, ?, 1)",
    [embeddingBytes],
  );
  await db.customStatement(
    'INSERT INTO experiential_memories (memory_id, session_id, summary, '
    'importance, turn_number, has_embedding) '
    "VALUES ('mem_2', 's1', '低重要性事件', 2, 2, 0)",
  );
  await db.customStatement(
    'INSERT INTO experiential_memories (memory_id, session_id, summary, '
    'importance, turn_number, memory_level, parent_event_ids, '
    'macro_trigger_reason, has_embedding) '
    "VALUES ('mem_macro', 's1', '入门事件收束', 5, 2, 'macro', "
    "'[\"mem_1\",\"mem_2\",\"mem_ghost\"]', 'round_limit', 0)",
  );
}

Future<List<Map<String, dynamic>>> entitiesOf(
  AppDatabase db,
  String sessionId,
) =>
    rowsOf(db, 'factual_entities', sessionId);

Future<List<Map<String, dynamic>>> attributesOf(
  AppDatabase db,
  String sessionId,
) =>
    rowsOf(db, 'factual_attributes', sessionId);

Future<List<Map<String, dynamic>>> memoriesOf(
  AppDatabase db,
  String sessionId,
) =>
    rowsOf(db, 'experiential_memories', sessionId);

Future<List<Map<String, dynamic>>> rowsOf(
  AppDatabase db,
  String table,
  String sessionId,
) async {
  final rows = await db.customSelect(
    'SELECT * FROM $table WHERE session_id = ?',
    variables: [Variable.withString(sessionId)],
  ).get();
  return [
    for (final row in rows)
      {for (final entry in row.data.entries) entry.key: entry.value},
  ];
}

/// 在第一条 experiential_memories 插入语句上抛错的拦截器
///
/// 记忆四表在 copySession 的同一 batch 内插入：拦截 runBatched 中含
/// experiential_memories 的，模拟「实体已插、记忆未插」的中途失败。
class _FailMemoriesInsert extends QueryInterceptor {
  bool armed = false;

  final _pattern = RegExp(r'INSERT\s+INTO\s+"?experiential_memories"?');

  @override
  Future<void> runBatched(
    QueryExecutor executor,
    BatchedStatements statements,
  ) async {
    if (armed && statements.statements.any(_pattern.hasMatch)) {
      armed = false;
      throw Exception('注入失败：experiential_memories 插入中断');
    }
    return executor.runBatched(statements);
  }
}
