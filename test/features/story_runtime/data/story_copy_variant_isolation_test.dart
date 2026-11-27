import 'dart:convert';

import 'package:drift/drift.dart' show Variable;
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

const _bodyA = '陈默活着的版本。';
const _bodyB = '陈默战死的版本。';
const _summaryA = '古碑遗迹中陈默存活';
const _summaryB = '雪山隘口中陈默战死';
const _factA = '陈默：存活，担任向导';
const _factB = '陈默：已战死';
const _originalEntityId = 'original-entity-id';

void main() {
  late _Fixture fixture;

  setUp(() async {
    fixture = await _Fixture.create();
  });

  tearDown(() async => fixture.db.close());

  test('副本切稿只修改副本的既有实体、属性和流水', () async {
    await fixture.seed(existingEntity: true);
    final source = fixture.sessionId;
    final copy = (await fixture.chat.copySession(source)).sessionId;
    final sourceBefore = await fixture.rawState(source);
    final sourceMemory = await fixture.expectState(source, 1);
    final copyMemory = await fixture.expectState(copy, 1);
    expect(copyMemory, isNot(sourceMemory));

    await fixture.switchTo(copy, 0);
    expect(await fixture.rawState(source), sourceBefore);
    expect(await fixture.expectState(source, 1), sourceMemory);
    final firstA = await fixture.expectState(copy, 0);

    await fixture.switchTo(copy, 1);
    expect(await fixture.rawState(source), sourceBefore);
    expect(await fixture.expectState(source, 1), sourceMemory);
    expect(await fixture.expectState(copy, 1), copyMemory);

    await fixture.switchTo(copy, 0);
    expect(await fixture.rawState(source), sourceBefore);
    expect(await fixture.expectState(source, 1), sourceMemory);
    expect(await fixture.expectState(copy, 0), firstA);
  });

  test('副本人物改名且另一人物接用旧名后，旧稿不能写错人物', () async {
    await fixture.facts.createEntity(
      FactualEntity(
        entityId: 'other-entity-id',
        sessionId: fixture.sessionId,
        type: FactualEntityType.character,
        primaryName: '白芷',
        aliases: const [],
        importance: 3,
        createdTurn: 0,
        createdAt: DateTime(2026),
      ),
    );
    await fixture.seed(existingEntity: true, resolveByName: true);
    final source = fixture.sessionId;
    final copy = (await fixture.chat.copySession(source)).sessionId;
    final intended = (await fixture.facts.findByName(copy, ['陈默'])).single;
    final other = (await fixture.facts.findByName(copy, ['白芷'])).single;
    await fixture.facts.updateEntityBasic(
      entityId: intended.entityId,
      primaryName: '陈先生',
    );
    await fixture.facts.updateEntityBasic(
      entityId: other.entityId,
      primaryName: '陈默',
    );
    final sourceBefore = await fixture.rawState(source);
    final otherBefore = await fixture.rawEntity(other.entityId);
    var current = 1;

    for (final target in [0, 1, 0]) {
      final copyBefore = await fixture.rawState(copy);
      final switched = await fixture.attemptSwitch(copy, target);
      if (switched) {
        current = target;
      } else {
        expect(await fixture.rawState(copy), copyBefore);
      }
      expect(await fixture.rawState(source), sourceBefore);
      await fixture.expectState(source, 1);
      expect(await fixture.rawEntity(other.entityId), otherBefore);
      expect(
        (await fixture.facts.getEntityById(intended.entityId))?.primaryName,
        '陈先生',
      );
      expect(
        (await fixture.facts.getEntityById(other.entityId))?.primaryName,
        '陈默',
      );
      await fixture.expectCharacterVariant(
        copy,
        intended.entityId,
        current,
      );
    }
  });

  test('同名创建实际转换为更新后，旧稿不能转写给后来接用该名的人', () async {
    await fixture.facts.createEntity(
      FactualEntity(
        entityId: 'other-entity-id',
        sessionId: fixture.sessionId,
        type: FactualEntityType.character,
        primaryName: '白芷',
        aliases: const [],
        importance: 3,
        createdTurn: 0,
        createdAt: DateTime(2026),
      ),
    );
    const converted = '甲稿转换后的记录';
    await fixture.seed(
      existingEntity: true,
      extraDeltasA: const [
        FactsDelta(
          action: FactAction.createEntity,
          entityType: 'character',
          primaryName: '陈默',
          attrKey: 'background',
          value: converted,
          confidence: 5,
        ),
      ],
      afterPersistA: () async {
        final entities = await fixture.facts.findByName(
          fixture.sessionId,
          ['陈默'],
        );
        expect(entities.map((entity) => entity.entityId), [_originalEntityId]);
        expect(
          (await fixture.facts.getAttributesByKey(
            _originalEntityId,
            'background',
          ))
              .single
              .value,
          converted,
        );
        final history = await fixture.facts.getHistory(_originalEntityId);
        expect(
          history.map((entry) => entry.action),
          unorderedEquals([FactAction.updateAttr, FactAction.updateAttr]),
        );
        expect(
          history.map((entry) => entry.newValue),
          unorderedEquals([_factA, converted]),
        );
      },
    );
    final source = fixture.sessionId;
    final copy = (await fixture.chat.copySession(source)).sessionId;
    final intended = (await fixture.facts.findByName(copy, ['陈默'])).single;
    final other = (await fixture.facts.findByName(copy, ['白芷'])).single;
    await fixture.facts.updateEntityBasic(
      entityId: intended.entityId,
      primaryName: '陈先生',
    );
    await fixture.facts.updateEntityBasic(
      entityId: other.entityId,
      primaryName: '陈默',
    );
    final sourceBefore = await fixture.rawState(source);
    final otherBefore = await fixture.rawEntity(other.entityId);
    var current = 1;
    for (final target in [0, 1, 0]) {
      final before = await fixture.rawState(copy);
      if (await fixture.attemptSwitch(copy, target)) {
        current = target;
      } else {
        expect(await fixture.rawState(copy), before);
      }
      expect(await fixture.rawState(source), sourceBefore);
      await fixture.expectState(source, 1);
      expect(await fixture.rawEntity(other.entityId), otherBefore);
      await fixture.expectCharacterVariant(
        copy,
        intended.entityId,
        current,
        background: current == 0 ? converted : null,
        historyValues: current == 0 ? [_factA, converted] : null,
      );
    }
  });

  test('旧稿实际新建的人物与前轮人物同名时，不能合写前轮人物', () async {
    await fixture.facts.createEntity(
      FactualEntity(
        entityId: 'prior-entity-id',
        sessionId: fixture.sessionId,
        type: FactualEntityType.character,
        primaryName: '白芷',
        aliases: const [],
        importance: 3,
        createdTurn: 0,
        createdAt: DateTime(2026),
      ),
    );
    await fixture.seed();
    final source = fixture.sessionId;
    final copy = (await fixture.chat.copySession(source)).sessionId;
    final current = (await fixture.facts.findByName(copy, ['陈默'])).single;
    final prior = (await fixture.facts.findByName(copy, ['白芷'])).single;
    await fixture.facts.updateEntityBasic(
      entityId: current.entityId,
      primaryName: '陈乙',
    );
    await fixture.facts.updateEntityBasic(
      entityId: prior.entityId,
      primaryName: '陈默',
    );
    final sourceBefore = await fixture.rawState(source);
    final priorBefore = await fixture.rawEntity(prior.entityId);
    var activeIndex = 1;
    for (final target in [0, 1, 0]) {
      final before = await fixture.rawState(copy);
      final switched = await fixture.attemptSwitch(copy, target);
      if (!switched) {
        expect(await fixture.rawState(copy), before);
      } else if (target != activeIndex) {
        final matches = await fixture.facts.findByName(copy, ['陈默']);
        final restored = matches
            .where((entity) => entity.entityId != prior.entityId)
            .toList();
        expect(restored, hasLength(1));
        final restoredEntity = restored.single;
        expect(restoredEntity.sessionId, copy);
        expect(
          (await fixture.facts.getAttributesByKey(
            restoredEntity.entityId,
            'background',
          ))
              .single
              .value,
          target == 0 ? _factA : _factB,
        );
        final history = await fixture.facts.getHistory(restoredEntity.entityId);
        expect(history.map((entry) => entry.action), [FactAction.createEntity]);
        expect(history.map((entry) => entry.newValue), ['陈默']);
        activeIndex = target;
      }
      expect(await fixture.rawEntity(prior.entityId), priorBefore);
      expect(await fixture.rawState(source), sourceBefore);
      await fixture.expectState(source, 1);
      await fixture.expectMemoryOnlyState(
        copy,
        index: activeIndex,
        body: activeIndex == 0 ? _bodyA : _bodyB,
        summary: activeIndex == 0 ? _summaryA : _summaryB,
        query: activeIndex == 0 ? '古碑遗迹' : '雪山隘口',
      );
    }
  });

  test('收紧限长后，旧稿曾成功的长事实完整恢复或整笔拒绝', () async {
    final longFact = '旅行见闻' * 75;
    expect(longFact.length, 300);
    await fixture.seed(
      existingEntity: true,
      extraDeltasA: [_personalityDelta(longFact)],
      afterPersistA: () => fixture.expectGeneratedPersonality(longFact),
    );
    final source = fixture.sessionId;
    final copy = (await fixture.chat.copySession(source)).sessionId;
    final entity = (await fixture.facts.findByName(copy, ['陈默'])).single;
    expect(
      await fixture.facts.getAttributesByKey(_originalEntityId, 'personality'),
      isEmpty,
    );
    final sourceBefore = await fixture.rawState(source);
    final copyBefore = await fixture.rawState(copy);
    final switched = await fixture.attemptSwitch(
      copy,
      0,
      factualConfig: const FactualConfig(maxAttrValueLength: 200),
    );
    if (switched) {
      await fixture.expectCharacterVariant(
        copy,
        entity.entityId,
        0,
        personality: longFact,
      );
    } else {
      expect(await fixture.rawState(copy), copyBefore);
      await fixture.expectCharacterVariant(copy, entity.entityId, 1);
    }
    expect(await fixture.rawState(source), sourceBefore);
    await fixture.expectState(source, 1);
    for (final index in switched ? [1, 0] : [0, 1, 0]) {
      expect(await fixture.attemptSwitch(copy, index), isTrue);
      await fixture.expectCharacterVariant(
        copy,
        entity.entityId,
        index,
        personality: index == 0 ? longFact : null,
      );
      expect(await fixture.rawState(source), sourceBefore);
      await fixture.expectState(source, 1);
    }
  });

  test('放宽限长后，不补写生成时被跳过的长事实', () async {
    final rejectedFact = '原始提议' * 150;
    expect(rejectedFact.length, 600);
    await fixture.seed(
      existingEntity: true,
      extraDeltasA: [_personalityDelta(rejectedFact)],
      afterPersistA: () => fixture.expectGeneratedPersonality(null),
    );
    final source = fixture.sessionId;
    final copy = (await fixture.chat.copySession(source)).sessionId;
    final entity = (await fixture.facts.findByName(copy, ['陈默'])).single;
    expect(
      await fixture.facts.getAttributesByKey(_originalEntityId, 'personality'),
      isEmpty,
    );
    final sourceBefore = await fixture.rawState(source);
    final copyBefore = await fixture.rawState(copy);
    final switched = await fixture.attemptSwitch(
      copy,
      0,
      factualConfig: const FactualConfig(maxAttrValueLength: 1000),
    );
    if (switched) {
      await fixture.expectCharacterVariant(copy, entity.entityId, 0);
    } else {
      expect(await fixture.rawState(copy), copyBefore);
      await fixture.expectCharacterVariant(copy, entity.entityId, 1);
    }
    expect(await fixture.rawState(source), sourceBefore);
    await fixture.expectState(source, 1);
    for (final index in switched ? [1, 0] : [0, 1, 0]) {
      expect(await fixture.attemptSwitch(copy, index), isTrue);
      await fixture.expectCharacterVariant(copy, entity.entityId, index);
      expect(await fixture.rawState(source), sourceBefore);
      await fixture.expectState(source, 1);
    }
  });

  test('正常设置下，已成功的长事实随稿件连续恢复', () async {
    final longFact = '旅行见闻' * 75;
    expect(longFact.length, 300);
    await fixture.seed(
      existingEntity: true,
      extraDeltasA: [_personalityDelta(longFact)],
      afterPersistA: () => fixture.expectGeneratedPersonality(longFact),
    );
    final source = fixture.sessionId;
    final copy = (await fixture.chat.copySession(source)).sessionId;
    final entity = (await fixture.facts.findByName(copy, ['陈默'])).single;
    expect(
      await fixture.facts.getAttributesByKey(_originalEntityId, 'personality'),
      isEmpty,
    );
    final sourceBefore = await fixture.rawState(source);
    for (final index in [0, 1, 0]) {
      expect(await fixture.attemptSwitch(copy, index), isTrue);
      await fixture.expectCharacterVariant(
        copy,
        entity.entityId,
        index,
        personality: index == 0 ? longFact : null,
      );
      expect(await fixture.rawState(source), sourceBefore);
      await fixture.expectState(source, 1);
    }
  });

  test('两个副本和再复制的副本交错切稿，各自恢复并检索自己的经历', () async {
    await fixture.seed();
    final source = fixture.sessionId;
    final first = (await fixture.chat.copySession(source)).sessionId;
    final second = (await fixture.chat.copySession(source)).sessionId;
    final sourceBefore = await fixture.rawState(source);
    final sourceB = await fixture.expectState(source, 1);
    final firstB = await fixture.expectState(first, 1);
    final secondB = await fixture.expectState(second, 1);
    expect({sourceB, firstB, secondB}, hasLength(3));

    await fixture.switchTo(first, 0);
    expect(await fixture.rawState(source), sourceBefore);
    expect(await fixture.expectState(source, 1), sourceB);
    final firstA = await fixture.expectState(first, 0);
    expect(await fixture.expectState(second, 1), secondB);

    await fixture.switchTo(second, 0);
    expect(await fixture.rawState(source), sourceBefore);
    expect(await fixture.expectState(source, 1), sourceB);
    expect(await fixture.expectState(first, 0), firstA);
    final secondA = await fixture.expectState(second, 0);
    expect({sourceB, firstA, secondA}, hasLength(3));

    await fixture.switchTo(first, 1);
    expect(await fixture.rawState(source), sourceBefore);
    expect(await fixture.expectState(source, 1), sourceB);
    expect(await fixture.expectState(first, 1), firstB);
    expect(await fixture.expectState(second, 0), secondA);

    await fixture.switchTo(first, 0);
    expect(await fixture.rawState(source), sourceBefore);
    expect(await fixture.expectState(source, 1), sourceB);
    expect(await fixture.expectState(first, 0), firstA);
    expect(await fixture.expectState(second, 0), secondA);

    final child = (await fixture.chat.copySession(first)).sessionId;
    final childA = await fixture.expectState(child, 0);
    expect({sourceB, firstA, secondA, childA}, hasLength(4));
    expect(await fixture.rawState(source), sourceBefore);
    expect(await fixture.expectState(first, 0), firstA);
    expect(await fixture.expectState(second, 0), secondA);

    await fixture.switchTo(child, 1);
    expect(await fixture.rawState(source), sourceBefore);
    expect(await fixture.expectState(source, 1), sourceB);
    expect(await fixture.expectState(first, 0), firstA);
    expect(await fixture.expectState(second, 0), secondA);
    final childB = await fixture.expectState(child, 1);
    expect({sourceB, firstA, secondA, childB}, hasLength(4));

    await fixture.switchTo(second, 1);
    expect(await fixture.rawState(source), sourceBefore);
    expect(await fixture.expectState(source, 1), sourceB);
    expect(await fixture.expectState(first, 0), firstA);
    expect(await fixture.expectState(second, 1), secondB);
    expect(await fixture.expectState(child, 1), childB);

    await fixture.switchTo(child, 0);
    expect(await fixture.rawState(source), sourceBefore);
    expect(await fixture.expectState(source, 1), sourceB);
    expect(await fixture.expectState(first, 0), firstA);
    expect(await fixture.expectState(second, 1), secondB);
    expect(await fixture.expectState(child, 0), childA);

    final firstBefore = await fixture.rawState(first);
    final secondBefore = await fixture.rawState(second);
    final childBefore = await fixture.rawState(child);
    await fixture.switchTo(source, 0);
    final sourceA = await fixture.expectState(source, 0);
    expect({sourceA, firstA, secondB, childA}, hasLength(4));
    expect(await fixture.rawState(first), firstBefore);
    expect(await fixture.rawState(second), secondBefore);
    expect(await fixture.rawState(child), childBefore);
    expect(await fixture.expectState(first, 0), firstA);
    expect(await fixture.expectState(second, 1), secondB);
    expect(await fixture.expectState(child, 0), childA);

    await fixture.switchTo(source, 1);
    expect(await fixture.expectState(source, 1), sourceB);
    expect(await fixture.rawState(first), firstBefore);
    expect(await fixture.rawState(second), secondBefore);
    expect(await fixture.rawState(child), childBefore);
    expect(await fixture.expectState(first, 0), firstA);
    expect(await fixture.expectState(second, 1), secondB);
    expect(await fixture.expectState(child, 0), childA);
  });

  test('原故事连续三次切稿，正文、事实、经历和检索始终一致', () async {
    await fixture.seed();
    final source = fixture.sessionId;
    final originalB = await fixture.expectState(source, 1);

    await fixture.switchTo(source, 0);
    final originalA = await fixture.expectState(source, 0);
    await fixture.switchTo(source, 1);
    expect(await fixture.expectState(source, 1), originalB);
    await fixture.switchTo(source, 0);
    expect(await fixture.expectState(source, 0), originalA);
  });

  test('旧原生故事当前产物残留旧稿事实时，导入后按各稿数据往返', () async {
    await fixture.seed(existingEntity: true);
    final source = fixture.sessionId;
    final factsA = await fixture.readDeltas(source, 0);
    final factsB = await fixture.readDeltas(source, 1);
    expect((factsA.single as Map<String, dynamic>)['value'], _factA);
    expect((factsB.single as Map<String, dynamic>)['value'], _factB);
    await fixture.switchTo(source, 0);
    await fixture.removeSnapshotOwners(source);
    // 模拟旧版切到甲后仍把乙稿的 deltas 留在当前产物中。
    await fixture.db.customStatement(
      'UPDATE intermediate_round_artifacts SET facts_deltas = ? '
      'WHERE session_id = ? AND turn_number = 1',
      [jsonEncode(factsB), source],
    );
    final beforeExport = await fixture.expectState(source, 0);
    expect(await fixture.readArtifactDeltas(source), factsB);
    expect(await fixture.readDeltas(source, 0), factsA);

    final backup = await BackupRepositoryImpl(database: fixture.db)
        .exportSessionData(source);
    await fixture.db.close();
    fixture = (await _Fixture.create()).._existingEntity = true;
    final upgraded = fixture;
    expect(
      await BackupRepositoryImpl(database: upgraded.db)
          .importSessionData(backup, mode: ImportMode.append),
      2,
    );
    expect(await upgraded.readArtifactDeltas(source), factsB);
    expect(await upgraded.readDeltas(source, 0), factsA);
    expect(
      (await upgraded.readSnapshot(source, 0))
          .single
          .containsKey('snapshot_session_id'),
      isFalse,
    );
    expect(await upgraded.expectState(source, 0), beforeExport);

    await upgraded.switchTo(source, 1);
    await upgraded.expectState(source, 1);
    expect(await upgraded.readDeltas(source, 0), factsA);
    await upgraded.switchTo(source, 0);
    expect(await upgraded.expectState(source, 0), beforeExport);
    expect(await upgraded.readDeltas(source, 0), factsA);
  });

  test('旧副本当前稿自洽但休眠经历被共享时拒绝恢复并保留两侧现场', () async {
    await fixture.seed(withFacts: false);
    final source = fixture.sessionId;
    await fixture.addThirdVariant();
    final copy = (await fixture.chat.copySession(source)).sessionId;
    await fixture.switchTo(copy, 0);
    await fixture.removeSnapshotOwners(source);
    await fixture.removeSnapshotOwners(copy);

    // 旧副本沿用源故事的历史快照，切甲后活动经历也沿用甲的 ID。
    final sourceA = await fixture.readSnapshot(source, 0);
    final sourceB = await fixture.readSnapshot(source, 1);
    await fixture.writeSnapshot(copy, 0, sourceA);
    await fixture.writeSnapshot(copy, 1, sourceB);
    final borrowedA = sourceA.single['memory_id'] as String;
    final dormantB = sourceB.single['memory_id'] as String;
    final activeCopy =
        (await fixture.experiences.getAllExperiences(copy)).single;
    await fixture.db.customStatement(
      'UPDATE experiential_memories SET memory_id = ? '
      'WHERE session_id = ? AND memory_id = ?',
      [borrowedA, copy, activeCopy.memoryId],
    );
    await fixture.db.customStatement(
      'UPDATE memories_fts SET memory_id = ? '
      'WHERE session_id = ? AND memory_id = ?',
      [borrowedA, copy, activeCopy.memoryId],
    );

    final oldBackup = BackupRepositoryImpl(database: fixture.db);
    final sourceBackup = await oldBackup.exportSessionData(source);
    final copyBackup = await oldBackup.exportSessionData(copy);
    await fixture.db.close();
    fixture = await _Fixture.create();
    final upgraded = fixture;
    final importer = BackupRepositoryImpl(database: upgraded.db);
    expect(
      await importer.importSessionData(sourceBackup, mode: ImportMode.append),
      2,
    );
    expect(
      await importer.importSessionData(copyBackup, mode: ImportMode.append),
      2,
    );

    final sourceSnapshotA = await upgraded.readSnapshot(source, 0);
    final sourceSnapshotB = await upgraded.readSnapshot(source, 1);
    final copySnapshotA = await upgraded.readSnapshot(copy, 0);
    final copySnapshotB = await upgraded.readSnapshot(copy, 1);
    expect(sourceSnapshotA.single['memory_id'], borrowedA);
    expect(sourceSnapshotB.single['memory_id'], dormantB);
    expect(copySnapshotB.single['memory_id'], dormantB);
    expect(sourceSnapshotB.single['summary'], _summaryB);
    expect(copySnapshotB.single['summary'], _summaryB);
    expect(copySnapshotA.single['memory_id'], borrowedA);
    expect(copySnapshotA.single.containsKey('snapshot_session_id'), isFalse);
    expect(copySnapshotB.single.containsKey('snapshot_session_id'), isFalse);
    expect(
      (await upgraded.experiences.getAllExperiences(copy)).single.memoryId,
      borrowedA,
    );
    expect(
      await upgraded.db.customSelect(
        'SELECT memory_id FROM experiential_memories WHERE memory_id = ?',
        variables: [Variable.withString(dormantB)],
      ).get(),
      isEmpty,
      reason: '乙稿 ID 只在双方休眠快照中，不被活动行占用',
    );
    await upgraded.expectMemoryOnlyState(
      source,
      index: 3,
      body: '第三种结局',
      summary: '第三稿旧城相聚',
      query: '旧城相聚',
    );
    await upgraded.expectMemoryOnlyState(
      copy,
      index: 0,
      body: _bodyA,
      summary: _summaryA,
      query: '古碑遗迹',
    );
    final sourceBefore = await upgraded.rawState(source);
    final copyBefore = await upgraded.rawState(copy);

    expect(await upgraded.attemptSwitch(copy, 1), isFalse);
    expect(await upgraded.rawState(source), sourceBefore);
    expect(await upgraded.rawState(copy), copyBefore);
    await upgraded.expectMemoryOnlyState(
      source,
      index: 3,
      body: '第三种结局',
      summary: '第三稿旧城相聚',
      query: '旧城相聚',
    );
    await upgraded.expectMemoryOnlyState(
      copy,
      index: 0,
      body: _bodyA,
      summary: _summaryA,
      query: '古碑遗迹',
    );
    await upgraded.expectSearch(source, '雪山隘口', null);
    await upgraded.expectSearch(copy, '雪山隘口', null);
  });

  test('切稿中途写入经历失败时整笔回滚，解除故障后可重试', () async {
    await fixture.seed(existingEntity: true);
    final source = fixture.sessionId;
    final copy = (await fixture.chat.copySession(source)).sessionId;
    final other = (await fixture.chat.copySession(source)).sessionId;
    final sourceBefore = await fixture.rawState(source);
    final copyBefore = await fixture.rawState(copy);
    final otherBefore = await fixture.rawState(other);
    final sourceMemory = await fixture.expectState(source, 1);
    final copyMemory = await fixture.expectState(copy, 1);
    final otherMemory = await fixture.expectState(other, 1);

    // 切稿已更新正文、撤销当前派生后才恢复经历，因此此处失败能检验回滚。
    await fixture.db.customStatement(
      'CREATE TEMP TRIGGER fail_restoring_memory '
      'BEFORE INSERT ON experiential_memories '
      "BEGIN SELECT RAISE(ABORT, 'injected restore failure'); END",
    );
    await expectLater(
      fixture.switchTo(copy, 0),
      throwsA(
        isA<Exception>().having(
          (error) => error.toString(),
          '错误原因',
          contains('injected restore failure'),
        ),
      ),
    );
    expect(await fixture.rawState(source), sourceBefore);
    expect(await fixture.rawState(copy), copyBefore);
    expect(await fixture.rawState(other), otherBefore);
    expect(await fixture.expectState(source, 1), sourceMemory);
    expect(await fixture.expectState(copy, 1), copyMemory);
    expect(await fixture.expectState(other, 1), otherMemory);

    await fixture.db.customStatement('DROP TRIGGER fail_restoring_memory');
    await fixture.switchTo(copy, 0);
    expect(await fixture.rawState(source), sourceBefore);
    expect(await fixture.rawState(other), otherBefore);
    expect(await fixture.expectState(source, 1), sourceMemory);
    await fixture.expectState(copy, 0);
    expect(await fixture.expectState(other, 1), otherMemory);
  });

  test('副本删轮后的异常回滚旧稿，重生成只重放已写入的事实', () async {
    await fixture.seed(existingEntity: true);
    final source = fixture.sessionId;
    final copy = (await fixture.chat.copySession(source)).sessionId;
    await fixture.switchTo(copy, 0);
    final sourceBefore = await fixture.rawState(source);
    final copyBefore = await fixture.rawState(copy);
    final assistant = (await fixture.chat.getMessages(copy))
        .singleWhere((message) => message.role == 'assistant');
    final process = (await fixture.service.loadArtifactsBySession(copy))[1];
    final local = (await fixture.facts.findByName(copy, ['陈默'])).single;
    final snapshot = (
      assistant: assistant,
      sourceInput: '推进剧情',
      process: process,
    );

    await expectLater(
      fixture.service.rollbackRoundAndDownstream(
        sessionId: copy,
        fromTurnNumber: 1,
        messageIdsToDelete: [assistant.messageId],
        variantSnapshot: snapshot,
        truncateEvents: (sessionId, turn) async {
          expect(sessionId, copy);
          expect(turn, 1);
          expect(await fixture.chat.getMessageCount(copy), 1);
          expect(await fixture.experiences.getAllExperiences(copy), isEmpty);
          expect(await fixture.facts.getHistory(local.entityId), isEmpty);
          throw StateError('synthetic failure after deleting turn');
        },
      ),
      throwsStateError,
    );
    expect(await fixture.rawState(source), sourceBefore);
    expect(await fixture.rawState(copy), copyBefore);

    await fixture.service.rollbackRoundAndDownstream(
      sessionId: copy,
      fromTurnNumber: 1,
      messageIdsToDelete: [assistant.messageId],
      variantSnapshot: snapshot,
    );
    const failedFact = '流水写入失败的事实';
    await fixture.db.customStatement(
      'CREATE TEMP TRIGGER reject_regenerated_history '
      'BEFORE INSERT ON factual_memory_history '
      "WHEN NEW.new_value = '$failedFact' "
      "BEGIN SELECT RAISE(ABORT, 'synthetic history failure'); END",
    );
    const body = '陈默重返遗迹的新稿。';
    const summary = EventSummary(
      summary: '陈默重返遗迹',
      importance: 3,
      tags: [],
      turnNumber: 1,
    );
    final result = await fixture.service.persistRegeneratedRound(
      assistantMessage: assistant.copyWith(content: body),
      eventSummary: summary,
      embedding: null,
      artifacts: StoryRoundArtifacts(
        sessionId: copy,
        turnNumber: 1,
        createdAt: DateTime(2026),
        replyText: body,
        eventSummary: summary,
      ),
      factsDeltas: [
        for (final value in [failedFact, '陈默重返遗迹'])
          FactsDelta(
            action: FactAction.updateAttr,
            entityId: local.entityId,
            attrKey: 'background',
            value: value,
            confidence: 5,
            importance: 4,
          ),
      ],
      factualConfig: const FactualConfig(),
      recordVariant: true,
      variantSourceInput: '推进剧情',
      hasVerifiedSourceTurn: true,
    );
    expect(result.factWriteFailureCount, 1);
    expect(result.factsChanges.single.newValue, '陈默重返遗迹');
    final selected = (await fixture.service.loadArtifactsBySession(copy))[1]
        ?.currentVariantIndex;
    if (selected == null) fail('新稿缺少已提交的变体指针');
    await fixture.db.customStatement('DROP TRIGGER reject_regenerated_history');

    await fixture.switchTo(copy, 0);
    await fixture.expectState(copy, 0);
    await fixture.switchTo(copy, selected);

    expect(await fixture.rawState(source), sourceBefore);
    final messages = await fixture.chat.getMessages(copy);
    expect(messages.singleWhere((m) => m.role == 'assistant').content, body);
    expect(
      (await fixture.facts.getAttributesByKey(local.entityId, 'background'))
          .single
          .value,
      '陈默重返遗迹',
    );
    final history = (await fixture.facts.getHistory(local.entityId)).single;
    expect(history.newValue, '陈默重返遗迹');
    expect(history.oldValue, isNull);
    final memory = (await fixture.experiences.getAllExperiences(copy)).single;
    expect(memory.memoryId, result.memory.memoryId);
    expect(memory.sessionId, copy);
    expect(memory.summary, summary.summary);
    expect(memory.hasVerifiedSourceTurn, isTrue);
  });

  test('保存事实流水中止整轮事务后停止写入并保留两个故事', () async {
    await fixture.seed(existingEntity: true);
    final source = fixture.sessionId;
    final copy = (await fixture.chat.copySession(source)).sessionId;
    final sourceBefore = await fixture.rawState(source);
    final copyBefore = await fixture.rawState(copy);
    final local = (await fixture.facts.findByName(copy, ['陈默'])).single;
    const rejected = '合成故障中止事务';
    await fixture.db.customStatement(
      'CREATE TEMP TRIGGER abort_round_transaction BEFORE INSERT '
      'ON factual_memory_history '
      "WHEN NEW.new_value = '$rejected' "
      "BEGIN SELECT RAISE(ROLLBACK, 'synthetic history failure'); END",
    );

    await expectLater(
      fixture.persistNextRound(copy, [
        for (final value in [rejected, '稍后写入的事实'])
          FactsDelta(
            action: FactAction.updateAttr,
            entityId: local.entityId,
            attrKey: 'background',
            value: value,
            confidence: 5,
            importance: 4,
          ),
      ]),
      throwsException,
    );
    expect(await fixture.rawState(source), sourceBefore);
    expect(await fixture.rawState(copy), copyBefore);
  });

  final mutatingActions = [
    FactAction.updateAttr,
    FactAction.appendList,
    FactAction.removeFromList,
    FactAction.addAlias,
    FactAction.archiveEntity,
  ];
  for (final action in mutatingActions) {
    test('正常生成逐项容错，拒绝 ${action.name} 的外部同名目标', () async {
      await fixture.seed(existingEntity: true, withBaseSkill: true);
      final source = fixture.sessionId;
      final copy = (await fixture.chat.copySession(source)).sessionId;
      final other = (await fixture.chat.copySession(source)).sessionId;
      final local = (await fixture.facts.findByName(copy, ['陈默'])).single;
      expect(local.entityId, isNot(_originalEntityId));
      final sourceBefore = await fixture.rawState(source);
      final otherBefore = await fixture.rawState(other);

      await fixture.persistNextRound(copy, [
        _targetDelta(action, _originalEntityId),
        FactsDelta(
          action: FactAction.updateAttr,
          entityId: local.entityId,
          attrKey: 'background',
          value: '副本自己的后续变化',
          confidence: 5,
        ),
      ]);

      expect(await fixture.rawState(source), sourceBefore);
      expect(await fixture.rawState(other), otherBefore);
      expect(
        (await fixture.facts.getAttributesByKey(local.entityId, 'background'))
            .single
            .value,
        '副本自己的后续变化',
      );
      expect(
        (await fixture.chat.getMessages(copy)).last.content,
        '副本的后续正文',
      );
      await fixture.expectSearch(copy, '后续回合摘要', '后续回合摘要');
      await fixture.expectSearch(source, '雪山隘口', _summaryB);
      await fixture.expectSearch(other, '雪山隘口', _summaryB);
    });

    test('旧稿混合合法动作和外部 ${action.name} 时拒绝并回滚整笔', () async {
      await fixture.seed(existingEntity: true, withBaseSkill: true);
      final source = fixture.sessionId;
      final copy = (await fixture.chat.copySession(source)).sessionId;
      final other = (await fixture.chat.copySession(source)).sessionId;
      final local = (await fixture.facts.findByName(copy, ['陈默'])).single;
      final deltas = await fixture.readDeltas(copy, 0);
      expect(
        (deltas.first as Map<String, dynamic>)['entityId'],
        local.entityId,
      );
      deltas.add(_targetDelta(action, _originalEntityId).toJson());
      await fixture.writeDeltas(copy, 0, deltas);
      final sourceBefore = await fixture.rawState(source);
      final copyBefore = await fixture.rawState(copy);
      final otherBefore = await fixture.rawState(other);

      expect(await fixture.attemptSwitch(copy, 0), isFalse);
      expect(await fixture.rawState(source), sourceBefore);
      expect(await fixture.rawState(copy), copyBefore);
      expect(await fixture.rawState(other), otherBefore);
      await fixture.expectSearch(source, '雪山隘口', _summaryB);
      await fixture.expectSearch(copy, '雪山隘口', _summaryB);
      await fixture.expectSearch(other, '雪山隘口', _summaryB);
      await fixture.expectSearch(copy, '古碑遗迹', null);
    });
  }

  test('旧稿引用不存在的实体时拒绝并回滚整笔', () async {
    await fixture.seed(existingEntity: true);
    final source = fixture.sessionId;
    final copy = (await fixture.chat.copySession(source)).sessionId;
    final deltas = await fixture.readDeltas(copy, 0);
    deltas.add(_targetDelta(FactAction.updateAttr, 'missing-entity').toJson());
    await fixture.writeDeltas(copy, 0, deltas);
    final sourceBefore = await fixture.rawState(source);
    final copyBefore = await fixture.rawState(copy);

    expect(await fixture.attemptSwitch(copy, 0), isFalse);
    expect(await fixture.rawState(source), sourceBefore);
    expect(await fixture.rawState(copy), copyBefore);
    await fixture.expectSearch(copy, '雪山隘口', _summaryB);
    await fixture.expectSearch(copy, '古碑遗迹', null);
  });

  test('副本旧稿可重放合法的属性、列表、别名和归档动作', () async {
    await fixture.seed(
      existingEntity: true,
      withBaseSkill: true,
      extraDeltasA: [
        _targetDelta(FactAction.appendList, _originalEntityId),
        _targetDelta(FactAction.removeFromList, _originalEntityId),
        _targetDelta(FactAction.addAlias, _originalEntityId),
        _targetDelta(FactAction.archiveEntity, _originalEntityId),
      ],
    );
    final source = fixture.sessionId;
    final copy = (await fixture.chat.copySession(source)).sessionId;
    final other = (await fixture.chat.copySession(source)).sessionId;
    final local = (await fixture.facts.findByName(copy, ['陈默'])).single;
    final proposals = await fixture.readDeltas(copy, 0);
    final append = proposals.cast<Map<String, dynamic>>().singleWhere(
          (row) => row['action'] == 'append_list',
        );
    final effect = append['applied'] as Map<String, dynamic>;
    expect(effect['value'], '天雷破');
    for (final field in ['beforeHash', 'afterHash']) {
      expect(effect[field], matches(RegExp(r'^[0-9a-f]{64}$')));
    }
    expect(jsonEncode(effect), isNot(contains('御剑术')));
    final sourceBefore = await fixture.rawState(source);
    final otherBefore = await fixture.rawState(other);

    Future<void> expectCopy(int index) async {
      final entity = await fixture.facts.getEntityById(local.entityId);
      expect(entity, isNotNull);
      expect(entity?.sessionId, copy);
      expect(entity?.isArchived, index == 0);
      expect(entity?.aliases, index == 0 ? ['青衣客'] : isEmpty);
      expect(
        (await fixture.facts.getAttributesByKey(local.entityId, 'background'))
            .single
            .value,
        index == 0 ? _factA : _factB,
      );
      expect(
        (await fixture.facts.getAttributesByKey(local.entityId, 'skills'))
            .single
            .listValue,
        index == 0 ? ['天雷破'] : ['御剑术'],
      );
      final assistant = (await fixture.chat.getMessages(copy))
          .singleWhere((message) => message.role == 'assistant');
      expect(assistant.content, index == 0 ? _bodyA : _bodyB);
      await fixture.expectSearch(
        copy,
        index == 0 ? '古碑遗迹' : '雪山隘口',
        index == 0 ? _summaryA : _summaryB,
      );
      final history = await fixture.facts.getHistory(local.entityId);
      final turnActions = history
          .where((entry) => entry.turnNumber == 1)
          .map((entry) => entry.action)
          .toList();
      expect(
        turnActions,
        unorderedEquals(
          index == 0 ? mutatingActions : [FactAction.updateAttr],
        ),
      );
    }

    await expectCopy(1);
    await fixture.switchTo(copy, 0);
    await expectCopy(0);
    expect(await fixture.rawState(source), sourceBefore);
    expect(await fixture.rawState(other), otherBefore);
    await fixture.switchTo(copy, 1);
    await expectCopy(1);
    expect(await fixture.rawState(source), sourceBefore);
    expect(await fixture.rawState(other), otherBefore);
    await fixture.switchTo(copy, 0);
    await expectCopy(0);
    expect(await fixture.rawState(source), sourceBefore);
    expect(await fixture.rawState(other), otherBefore);
  });

  test('旧稿引用该稿新建人物时，两个副本各自重放创建和后续更新', () async {
    late String createdId;
    await fixture.seed(
      extraDeltasA: const [
        FactsDelta(
          action: FactAction.updateAttr,
          primaryName: '陈默',
          attrKey: 'background',
          value: '陈默存活并找到古城',
          confidence: 5,
        ),
      ],
      afterPersistA: () async {
        final entity =
            (await fixture.facts.findByName(fixture.sessionId, ['陈默'])).single;
        createdId = entity.entityId;
        expect(
          (await fixture.facts.getAttributesByKey(createdId, 'background'))
              .single
              .value,
          '陈默存活并找到古城',
        );
        final history = await fixture.facts.getHistory(createdId);
        expect(
          history.map((entry) => entry.action),
          unorderedEquals([FactAction.createEntity, FactAction.updateAttr]),
        );
        expect(
          history.map((entry) => entry.newValue),
          unorderedEquals(['陈默', '陈默存活并找到古城']),
        );
      },
    );
    final source = fixture.sessionId;
    final first = (await fixture.chat.copySession(source)).sessionId;
    final second = (await fixture.chat.copySession(source)).sessionId;
    final sourceBefore = await fixture.rawState(source);

    Future<String> checkOld(String id) async {
      final entity = (await fixture.facts.findByName(id, ['陈默'])).single;
      expect(entity.sessionId, id);
      expect(
        (await fixture.facts.getAttributesByKey(entity.entityId, 'background'))
            .single
            .value,
        '陈默存活并找到古城',
      );
      expect(
        (await fixture.facts.getHistory(entity.entityId))
            .map((entry) => entry.action),
        unorderedEquals([FactAction.createEntity, FactAction.updateAttr]),
      );
      await fixture.expectMemoryOnlyState(
        id,
        index: 0,
        body: _bodyA,
        summary: _summaryA,
        query: '古碑遗迹',
      );
      return entity.entityId;
    }

    await fixture.switchTo(first, 0);
    final firstEntity = await checkOld(first);
    await fixture.switchTo(second, 0);
    final secondEntity = await checkOld(second);
    expect({createdId, firstEntity, secondEntity}, hasLength(3));
    expect(await fixture.rawState(source), sourceBefore);
    await fixture.switchTo(first, 1);
    await fixture.expectState(first, 1);
    expect(await checkOld(second), secondEntity);
    await fixture.switchTo(first, 0);
    final replayed = await checkOld(first);
    expect(replayed, isNot(secondEntity));
    expect(await checkOld(second), secondEntity);
    expect(await fixture.rawState(source), sourceBefore);
  });

  test('未实际成功的原始追加动作不能写入副本旧稿', () async {
    await fixture.seed();
    final source = fixture.sessionId;
    final copy = (await fixture.chat.copySession(source)).sessionId;
    final other = (await fixture.chat.copySession(source)).sessionId;
    final deltas = await fixture.readDeltas(copy, 0);
    final created = deltas.single as Map<String, dynamic>;
    final effect = created['applied'] as Map<String, dynamic>;
    final recordedId = effect['entityId'];
    expect(recordedId, isA<String>());
    deltas.add(
      FactsDelta(
        action: FactAction.updateAttr,
        entityId: recordedId as String,
        attrKey: 'background',
        value: '未经生成成功的追加事实',
        confidence: 5,
      ).toJson(),
    );
    await fixture.writeDeltas(copy, 0, deltas);
    final sourceBefore = await fixture.rawState(source);
    final copyBefore = await fixture.rawState(copy);
    final otherBefore = await fixture.rawState(other);
    final switched = await fixture.attemptSwitch(copy, 0);
    expect(await fixture.rawState(source), sourceBefore);
    expect(await fixture.rawState(other), otherBefore);
    if (switched) {
      await fixture.expectState(copy, 0);
    } else {
      expect(await fixture.rawState(copy), copyBefore);
      await fixture.expectState(copy, 1);
    }
  });
}

FactsDelta _targetDelta(FactAction action, String id) => FactsDelta(
      action: action,
      entityId: id,
      primaryName: '陈默',
      attrKey: action == FactAction.updateAttr
          ? 'background'
          : action == FactAction.appendList ||
                  action == FactAction.removeFromList
              ? 'skills'
              : null,
      value: switch (action) {
        FactAction.updateAttr => '外部人物状态',
        FactAction.appendList => '天雷破',
        FactAction.removeFromList => '御剑术',
        FactAction.addAlias => '青衣客',
        _ => null,
      },
      reason: '合成剧情变化',
      confidence: 5,
    );

FactsDelta _personalityDelta(String value) => FactsDelta(
      action: FactAction.updateAttr,
      entityId: _originalEntityId,
      attrKey: 'personality',
      value: value,
      confidence: 5,
    );

class _Fixture {
  _Fixture(
    this.db,
    this.chat,
    this.experiences,
    this.facts,
    this.service,
    this.sessionId,
  );

  static Future<_Fixture> create() async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final chat = ChatRepositoryImpl(database: db);
    final experiences = ExperienceRepositoryImpl(
      database: db,
      vectorEngine: const VectorEngine(),
    );
    final facts = FactualRepositoryImpl(database: db);
    final service = StoryPersistenceServiceImpl(
      database: db,
      chatRepository: chat,
      experienceRepository: experiences,
      factApplier: FactApplier(repository: facts),
    );
    final session = await chat.createSession(title: '合成故事', mode: 'advanced');
    return _Fixture(db, chat, experiences, facts, service, session.sessionId);
  }

  final AppDatabase db;
  final ChatRepositoryImpl chat;
  final ExperienceRepositoryImpl experiences;
  final FactualRepositoryImpl facts;
  final StoryPersistenceServiceImpl service;
  final String sessionId;
  var _existingEntity = false;

  StoryRoundArtifacts _artifacts(String body) => StoryRoundArtifacts(
        sessionId: sessionId,
        turnNumber: 1,
        createdAt: DateTime(2026),
        replyText: body,
      );

  Future<void> seed({
    bool existingEntity = false,
    bool withFacts = true,
    bool withBaseSkill = false,
    bool resolveByName = false,
    List<FactsDelta> extraDeltasA = const [],
    Future<void> Function()? afterPersistA,
  }) async {
    _existingEntity = existingEntity;
    if (existingEntity) {
      await facts.createEntity(
        FactualEntity(
          entityId: _originalEntityId,
          sessionId: sessionId,
          type: FactualEntityType.character,
          primaryName: '陈默',
          aliases: const [],
          importance: 3,
          createdTurn: 0,
          createdAt: DateTime(2026),
        ),
      );
    }
    if (withBaseSkill) {
      final changes = await FactApplier(repository: facts).applyDeltas(
        sessionId,
        const [
          FactsDelta(
            action: FactAction.appendList,
            entityId: _originalEntityId,
            attrKey: 'skills',
            value: '御剑术',
            confidence: 5,
          ),
        ],
        0,
        const FactualConfig(),
      );
      expect(changes, hasLength(1));
    }
    await _persist(
      body: _bodyA,
      summary: _summaryA,
      fact: _factA,
      withFacts: withFacts,
      resolveByName: resolveByName,
      extraDeltas: extraDeltasA,
    );
    if (afterPersistA != null) await afterPersistA();
    await service.snapshotMessageVariant(
      sessionId: sessionId,
      turnNumber: 1,
      content: _bodyA,
      sourceInput: '推进剧情',
      process: _artifacts(_bodyA),
    );
    await service.deleteRoundAndDownstream(
      sessionId: sessionId,
      fromTurnNumber: 1,
      messageIdsToDelete: const [],
      keepVariantsAtFromTurn: true,
    );
    await chat.deleteMessage('assistant-a');
    await _persist(
      body: _bodyB,
      summary: _summaryB,
      fact: _factB,
      withFacts: withFacts,
      resolveByName: resolveByName,
      regenerate: true,
    );
  }

  Future<void> _persist({
    required String body,
    required String summary,
    required String fact,
    bool withFacts = true,
    bool resolveByName = false,
    bool regenerate = false,
    List<FactsDelta> extraDeltas = const [],
  }) async {
    final message = ChatMessage(
      messageId: regenerate ? 'assistant-b' : 'assistant-a',
      sessionId: sessionId,
      role: 'assistant',
      content: body,
      createdAt: DateTime(2026),
    );
    final event = EventSummary(
      summary: summary,
      importance: 3,
      tags: const [],
      turnNumber: 1,
    );
    final delta = _existingEntity
        ? FactsDelta(
            action: FactAction.updateAttr,
            entityId: resolveByName ? null : _originalEntityId,
            primaryName: resolveByName ? '陈默' : null,
            attrKey: 'background',
            value: fact,
            confidence: 5,
            importance: 4,
          )
        : FactsDelta(
            action: FactAction.createEntity,
            entityType: 'character',
            primaryName: '陈默',
            attrKey: 'description',
            value: fact,
            confidence: 5,
            importance: 4,
          );
    if (regenerate) {
      await service.persistRegeneratedRound(
        assistantMessage: message,
        eventSummary: event,
        embedding: null,
        artifacts: _artifacts(body),
        factsDeltas: [if (withFacts) delta, ...extraDeltas],
        factualConfig: const FactualConfig(),
        recordVariant: true,
        variantSourceInput: '推进剧情',
      );
    } else {
      await service.persistRound(
        variantSourceInput: '推进剧情',
        userMessage: ChatMessage(
          messageId: 'user-1',
          sessionId: sessionId,
          role: 'user',
          content: '推进剧情',
          createdAt: DateTime(2026),
        ),
        assistantMessage: message,
        eventSummary: event,
        embedding: null,
        artifacts: _artifacts(body),
        factsDeltas: [if (withFacts) delta, ...extraDeltas],
        factualConfig: const FactualConfig(),
      );
    }
  }

  Future<bool> attemptSwitch(
    String id,
    int index, {
    FactualConfig factualConfig = const FactualConfig(),
  }) async {
    final assistant = (await chat.getMessages(id))
        .singleWhere((message) => message.role == 'assistant');
    return service.switchMessageVariant(
      sessionId: id,
      turnNumber: 1,
      variantIndex: index,
      assistantMessageId: assistant.messageId,
      factualConfig: factualConfig,
    );
  }

  Future<void> switchTo(String id, int index) async {
    expect(await attemptSwitch(id, index), isTrue);
  }

  Future<List<dynamic>> readDeltas(String id, int index) async {
    final row = await db.customSelect(
      'SELECT facts_deltas FROM message_variants '
      'WHERE session_id = ? AND turn_number = 1 AND variant_index = ?',
      variables: [Variable.withString(id), Variable.withInt(index)],
    ).getSingle();
    return jsonDecode(row.read<String>('facts_deltas')) as List<dynamic>;
  }

  Future<List<dynamic>> readArtifactDeltas(String id) async {
    final row = await db.customSelect(
      'SELECT facts_deltas FROM intermediate_round_artifacts '
      'WHERE session_id = ? AND turn_number = 1',
      variables: [Variable.withString(id)],
    ).getSingle();
    return jsonDecode(row.read<String>('facts_deltas')) as List<dynamic>;
  }

  Future<List<Map<String, dynamic>>> readSnapshot(String id, int index) async {
    final row = await db.customSelect(
      'SELECT experiential_snapshot FROM message_variants '
      'WHERE session_id = ? AND turn_number = 1 AND variant_index = ?',
      variables: [Variable.withString(id), Variable.withInt(index)],
    ).getSingle();
    return (jsonDecode(row.read<String>('experiential_snapshot')) as List)
        .cast<Map<String, dynamic>>();
  }

  Future<void> writeSnapshot(
    String id,
    int index,
    List<Map<String, dynamic>> rows,
  ) async {
    await db.customStatement(
      'UPDATE message_variants SET experiential_snapshot = ? '
      'WHERE session_id = ? AND turn_number = 1 AND variant_index = ?',
      [jsonEncode(rows), id, index],
    );
  }

  Future<void> removeSnapshotOwners(String id) async {
    final variants = (await service.loadMessageVariants(id))[1];
    if (variants == null) throw StateError('缺少预期的稿件');
    for (final variant in variants) {
      final snapshot = await readSnapshot(id, variant.variantIndex);
      for (final item in snapshot) {
        item.remove('snapshot_session_id');
      }
      await writeSnapshot(id, variant.variantIndex, snapshot);
    }
  }

  Future<void> addThirdVariant() async {
    await service.snapshotMessageVariant(
      sessionId: sessionId,
      turnNumber: 1,
      content: _bodyB,
      sourceInput: '推进剧情',
      process: _artifacts(_bodyB),
    );
    await service.deleteRoundAndDownstream(
      sessionId: sessionId,
      fromTurnNumber: 1,
      messageIdsToDelete: const [],
      keepVariantsAtFromTurn: true,
    );
    await chat.deleteMessage('assistant-b');
    await service.persistRegeneratedRound(
      assistantMessage: ChatMessage(
        messageId: 'assistant-c',
        sessionId: sessionId,
        role: 'assistant',
        content: '第三种结局',
        createdAt: DateTime(2026),
      ),
      eventSummary: const EventSummary(
        summary: '第三稿旧城相聚',
        importance: 3,
        tags: [],
        turnNumber: 1,
      ),
      embedding: null,
      artifacts: _artifacts('第三种结局'),
      factsDeltas: const [],
      factualConfig: const FactualConfig(),
      recordVariant: true,
    );
  }

  Future<void> writeDeltas(String id, int index, List<dynamic> deltas) async {
    await db.customStatement(
      'UPDATE message_variants SET facts_deltas = ? '
      'WHERE session_id = ? AND turn_number = 1 AND variant_index = ?',
      [jsonEncode(deltas), id, index],
    );
  }

  Future<void> persistNextRound(String id, List<FactsDelta> deltas) async {
    await service.persistRound(
      userMessage: ChatMessage(
        messageId: 'user-2',
        sessionId: id,
        role: 'user',
        content: '继续剧情',
        createdAt: DateTime(2026),
      ),
      assistantMessage: ChatMessage(
        messageId: 'assistant-2',
        sessionId: id,
        role: 'assistant',
        content: '副本的后续正文',
        createdAt: DateTime(2026),
      ),
      eventSummary: const EventSummary(
        summary: '后续回合摘要',
        importance: 3,
        tags: [],
        turnNumber: 2,
      ),
      embedding: null,
      artifacts: StoryRoundArtifacts(
        sessionId: id,
        turnNumber: 2,
        createdAt: DateTime(2026),
        replyText: '副本的后续正文',
      ),
      factsDeltas: deltas,
      factualConfig: const FactualConfig(),
    );
  }

  Future<void> expectSearch(String id, String query, String? summary) async {
    final results = await experiences.searchExperiences(
      sessionId: id,
      query: query,
      queryVector: null,
      topK: 5,
      fts5Weight: 1,
      vectorWeight: 0,
      keyEventThreshold: 4,
      keyEventBoost: 1.5,
      normalizationEpsilon: 0.01,
    );
    if (summary == null) {
      expect(results, isEmpty);
    } else {
      expect(
        results.map((result) => result.memory.summary).toList(),
        [summary],
      );
      expect(results.single.memory.sessionId, id);
    }
  }

  Future<void> expectMemoryOnlyState(
    String id, {
    required int index,
    required String body,
    required String summary,
    required String query,
  }) async {
    final assistant = (await chat.getMessages(id))
        .singleWhere((message) => message.role == 'assistant');
    expect(assistant.content, body);
    final pointer = await db.customSelect(
      'SELECT current_variant_index FROM intermediate_round_artifacts '
      'WHERE session_id = ? AND turn_number = 1',
      variables: [Variable.withString(id)],
    ).getSingle();
    expect(pointer.read<int>('current_variant_index'), index);
    final memories = await experiences.getAllExperiences(id);
    expect(memories, hasLength(1));
    expect(memories.single.sessionId, id);
    expect(memories.single.turnNumber, 1);
    expect(memories.single.summary, summary);
    await expectSearch(id, query, summary);
  }

  Future<void> expectGeneratedPersonality(String? expected) async {
    final background =
        await facts.getAttributesByKey(_originalEntityId, 'background');
    expect(background.map((attribute) => attribute.value), [_factA]);
    final personality =
        await facts.getAttributesByKey(_originalEntityId, 'personality');
    expect(personality.map((attribute) => attribute.value), [
      if (expected != null) expected,
    ]);
    final history = await facts.getHistory(_originalEntityId);
    expect(
      history.map((entry) => entry.newValue),
      unorderedEquals([_factA, if (expected != null) expected]),
    );
    expect(history.every((entry) => entry.turnNumber == 1), isTrue);
    final memories = await experiences.getAllExperiences(sessionId);
    expect(memories, hasLength(1));
    expect(memories.single.summary, _summaryA);
    await expectSearch(sessionId, '古碑遗迹', _summaryA);
  }

  Future<void> expectCharacterVariant(
    String id,
    String entityId,
    int index, {
    String? personality,
    String? background,
    List<String>? historyValues,
  }) async {
    final entity = await facts.getEntityById(entityId);
    expect(entity?.sessionId, id);
    final fact = background ?? (index == 0 ? _factA : _factB);
    final attributes = await facts.getAttributesByKey(entityId, 'background');
    expect(attributes.map((attribute) => attribute.value), [fact]);
    final personalityRows = await facts.getAttributesByKey(
      entityId,
      'personality',
    );
    expect(personalityRows.map((attribute) => attribute.value), [
      if (personality != null) personality,
    ]);
    final history = await facts.getHistory(entityId);
    expect(
      history.map((entry) => entry.newValue),
      unorderedEquals(
        historyValues ?? [fact, if (personality != null) personality],
      ),
    );
    expect(history.every((entry) => entry.entityId == entityId), isTrue);
    expect(history.every((entry) => entry.turnNumber == 1), isTrue);
    await expectMemoryOnlyState(
      id,
      index: index,
      body: index == 0 ? _bodyA : _bodyB,
      summary: index == 0 ? _summaryA : _summaryB,
      query: index == 0 ? '古碑遗迹' : '雪山隘口',
    );
    await expectSearch(id, index == 0 ? '雪山隘口' : '古碑遗迹', null);
  }

  Future<List<List<Map<String, Object?>>>> rawEntity(String entityId) async {
    final statements = [
      'SELECT * FROM factual_entities WHERE entity_id = ? ORDER BY rowid',
      'SELECT * FROM factual_attributes WHERE entity_id = ? ORDER BY rowid',
      'SELECT * FROM factual_memory_history WHERE entity_id = ? ORDER BY rowid',
    ];
    final state = <List<Map<String, Object?>>>[];
    for (final statement in statements) {
      final rows = await db.customSelect(
        statement,
        variables: [Variable.withString(entityId)],
      ).get();
      state.add([for (final row in rows) Map<String, Object?>.from(row.data)]);
    }
    return state;
  }

  Future<String> expectState(String id, int index) async {
    final body = index == 0 ? _bodyA : _bodyB;
    final summary = index == 0 ? _summaryA : _summaryB;
    final fact = index == 0 ? _factA : _factB;
    final assistant = (await chat.getMessages(id))
        .singleWhere((message) => message.role == 'assistant');
    expect(assistant.content, body, reason: '会话 $id 正文');
    final pointer = await db.customSelect(
      'SELECT current_variant_index FROM intermediate_round_artifacts '
      'WHERE session_id = ? AND turn_number = 1',
      variables: [Variable.withString(id)],
    ).getSingle();
    expect(pointer.read<int>('current_variant_index'), index);

    final entities = await facts.findByName(id, ['陈默']);
    expect(entities, hasLength(1), reason: '会话 $id 应有唯一人物');
    final entity = entities.single;
    expect(entity.sessionId, id);
    final attributes =
        await facts.getAttributesByKey(entity.entityId, 'background');
    expect(attributes.map((attribute) => attribute.value).toList(), [fact]);
    expect(attributes.single.sessionId, id);
    expect(attributes.single.entityId, entity.entityId);
    final history = await facts.getHistory(entity.entityId);
    expect(history.map((entry) => entry.turnNumber).toList(), [1]);
    expect(history.single.entityId, entity.entityId);
    if (_existingEntity) {
      expect(history.single.attributeId, attributes.single.attributeId);
    }
    expect(
      history.single.action,
      _existingEntity ? FactAction.updateAttr : FactAction.createEntity,
    );
    expect(history.single.newValue, _existingEntity ? fact : '陈默');

    final memories = await experiences.getAllExperiences(id);
    expect(memories, hasLength(1), reason: '会话 $id 不应丢失或重复经历');
    final memory = memories.single;
    expect(memory.sessionId, id);
    expect(memory.turnNumber, 1);
    expect(memory.summary, summary);
    for (final query in ['古碑遗迹', '雪山隘口']) {
      final results = await experiences.searchExperiences(
        sessionId: id,
        query: query,
        queryVector: null,
        topK: 5,
        fts5Weight: 1,
        vectorWeight: 0,
        keyEventThreshold: 4,
        keyEventBoost: 1.5,
        normalizationEpsilon: 0.01,
      );
      final shouldMatch = index == 0 ? query == '古碑遗迹' : query == '雪山隘口';
      expect(
        results.map((result) => result.memory.memoryId).toList(),
        shouldMatch ? [memory.memoryId] : isEmpty,
        reason: '会话 $id 的 FTS 查询 $query',
      );
      if (shouldMatch) {
        expect(results.single.memory.sessionId, id);
        expect(results.single.memory.summary, summary);
      }
    }
    return memory.memoryId;
  }

  Future<List<List<Map<String, Object?>>>> rawState(String id) async {
    const historySql = 'SELECT h.* FROM factual_memory_history h '
        'JOIN factual_entities e ON e.entity_id = h.entity_id '
        'WHERE e.session_id = ? ORDER BY h.rowid';
    final statements = [
      'SELECT * FROM chat_sessions WHERE session_id = ? ORDER BY rowid',
      'SELECT * FROM chat_messages WHERE session_id = ? ORDER BY rowid',
      'SELECT * FROM intermediate_round_artifacts WHERE session_id = ? ORDER BY rowid',
      'SELECT * FROM message_variants WHERE session_id = ? ORDER BY rowid',
      'SELECT * FROM factual_entities WHERE session_id = ? ORDER BY rowid',
      'SELECT * FROM factual_attributes WHERE session_id = ? ORDER BY rowid',
      historySql,
      'SELECT * FROM experiential_memories WHERE session_id = ? ORDER BY rowid',
      'SELECT * FROM memories_fts WHERE session_id = ? ORDER BY rowid',
    ];
    final state = <List<Map<String, Object?>>>[];
    for (final statement in statements) {
      final rows = await db.customSelect(
        statement,
        variables: [Variable.withString(id)],
      ).get();
      state.add([for (final row in rows) Map<String, Object?>.from(row.data)]);
    }
    return state;
  }
}
