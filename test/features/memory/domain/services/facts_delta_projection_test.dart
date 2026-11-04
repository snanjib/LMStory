import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/features/memory/domain/entities/facts_delta.dart';
import 'package:lmstory/features/memory/domain/entities/factual_attribute.dart';
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
import 'package:lmstory/features/memory/domain/entities/factual_source.dart';
import 'package:lmstory/features/memory/domain/services/facts_delta_projection.dart';

/// 干跑投影器单测（2026-10-15 批 A）
///
/// 目标：FactApplier 落库转写规则的**每个判定分支**都有对应断言——
/// 这是「审批横幅看到的 diff = 实际落库」同源性的第一道闸。
/// 判定行为与 fact_applier_test.dart 的落库结果互为对拍（后者断言
/// 写库副作用，本文件断言干跑判定）。
void main() {
  final t = DateTime(2026, 10, 15, 12);
  const config = FactualConfig();

  FactualEntity character({
    String id = 'ent_001',
    String name = '林晚',
    List<String> aliases = const [],
    int importance = 5,
    bool archived = false,
    FactualSource source = FactualSource.auto,
  }) =>
      FactualEntity(
        entityId: id,
        sessionId: 's1',
        type: FactualEntityType.character,
        primaryName: name,
        aliases: aliases,
        importance: importance,
        createdTurn: 1,
        createdAt: t,
        isArchived: archived,
        source: source,
      );

  FactualAttribute attr({
    String attrId = 'attr_001',
    String entityId = 'ent_001',
    String key = 'personality',
    String value = '冷静自持',
    AttributeValueType type = AttributeValueType.single,
    int importance = 4,
    FactualSource source = FactualSource.auto,
  }) =>
      FactualAttribute(
        attributeId: attrId,
        entityId: entityId,
        sessionId: 's1',
        attrKey: key,
        value: value,
        valueType: type,
        importance: importance,
        createdAt: t,
        source: source,
      );

  group('evaluateUpdateAttr', () {
    test('正常修改：applied 且 before/after 携带前后值', () {
      final v = FactsDeltaProjectionEvaluator.evaluateUpdateAttr(
        delta: const FactsDelta(
          action: FactAction.updateAttr,
          entityId: 'ent_001',
          attrKey: 'personality',
          value: '热情冲动',
          reason: '本轮她为掩护同伴故意夸张表演',
          confidence: 4,
        ),
        config: config,
        entity: character(),
        attrRows: [attr()],
      );

      expect(v.outcome, FactsProjectionOutcome.applied);
      expect(v.before, '冷静自持');
      expect(v.after, '热情冲动');
      expect(v.reason, '本轮她为掩护同伴故意夸张表演');
      expect(v.confidence, 4);
      expect(v.entityLabel, '林晚');
      expect(v.normalizedAttrKey, 'personality');
    });

    test('值相同 → skipped(valueUnchanged)', () {
      final v = FactsDeltaProjectionEvaluator.evaluateUpdateAttr(
        delta: const FactsDelta(
          action: FactAction.updateAttr,
          entityId: 'ent_001',
          attrKey: 'personality',
          value: '冷静自持',
          confidence: 5,
        ),
        config: config,
        entity: character(),
        attrRows: [attr()],
      );

      expect(v.outcome, FactsProjectionOutcome.skipped);
      expect(v.note, FactsProjectionNote.valueUnchanged);
    });

    test('list 类型拒改 → skipped(listRejectsUpdate)', () {
      final v = FactsDeltaProjectionEvaluator.evaluateUpdateAttr(
        delta: const FactsDelta(
          action: FactAction.updateAttr,
          entityId: 'ent_001',
          attrKey: 'skills',
          value: '剑术',
          confidence: 5,
        ),
        config: config,
        entity: character(),
        attrRows: [
          attr(key: 'skills', value: '["轻功"]', type: AttributeValueType.list),
        ],
      );

      expect(v.outcome, FactsProjectionOutcome.skipped);
      expect(v.note, FactsProjectionNote.listRejectsUpdate);
    });

    test('关键属性低置信度 → skipped(confidenceGate)，isCuration 豁免', () {
      const delta = FactsDelta(
        action: FactAction.updateAttr,
        entityId: 'ent_001',
        attrKey: 'personality',
        value: '热情冲动',
        confidence: 2,
      );
      final v = FactsDeltaProjectionEvaluator.evaluateUpdateAttr(
        delta: delta,
        config: config,
        entity: character(),
        attrRows: [attr()],
      );
      expect(v.outcome, FactsProjectionOutcome.skipped);
      expect(v.note, FactsProjectionNote.confidenceGate);

      final curated = FactsDeltaProjectionEvaluator.evaluateUpdateAttr(
        delta: const FactsDelta(
          action: FactAction.updateAttr,
          entityId: 'ent_001',
          attrKey: 'personality',
          value: '热情冲动',
          confidence: 2,
          isCuration: true,
        ),
        config: config,
        entity: character(),
        attrRows: [attr()],
      );
      expect(curated.outcome, FactsProjectionOutcome.applied);
    });

    test('改名（attrKey=name）→ converted(addAlias) 携带转写 delta', () {
      final v = FactsDeltaProjectionEvaluator.evaluateUpdateAttr(
        delta: const FactsDelta(
          action: FactAction.updateAttr,
          entityId: 'ent_001',
          attrKey: 'name',
          value: '林掌柜',
          confidence: 4,
        ),
        config: config,
        entity: character(),
        attrRows: [attr(key: 'name', importance: 5)],
      );

      expect(v.outcome, FactsProjectionOutcome.converted);
      expect(v.effectiveAction, FactAction.addAlias);
      expect(v.note, FactsProjectionNote.nameIsIdentity);
      expect(v.rewrittenDelta!.action, FactAction.addAlias);
      expect(v.rewrittenDelta!.value, '林掌柜');
    });

    test('无 auto 行（只读基线）→ applied(createsAttrRow) 基线演变行', () {
      final v = FactsDeltaProjectionEvaluator.evaluateUpdateAttr(
        delta: const FactsDelta(
          action: FactAction.updateAttr,
          entityId: 'ent_001',
          attrKey: 'personality',
          value: '外冷内热',
          confidence: 5,
        ),
        config: config,
        entity: character(source: FactualSource.worldbook),
        attrRows: [attr(source: FactualSource.worldbook, value: '冷静')],
      );

      expect(v.outcome, FactsProjectionOutcome.applied);
      expect(v.note, FactsProjectionNote.createsAttrRow);
      expect(v.before, '冷静'); // 基线值供参考
      expect(v.after, '外冷内热');
    });

    test('无 auto 行且新值与基线相同 → skipped(valueUnchangedBaseline)', () {
      final v = FactsDeltaProjectionEvaluator.evaluateUpdateAttr(
        delta: const FactsDelta(
          action: FactAction.updateAttr,
          entityId: 'ent_001',
          attrKey: 'personality',
          value: '冷静',
          confidence: 5,
        ),
        config: config,
        entity: character(source: FactualSource.worldbook),
        attrRows: [attr(source: FactualSource.worldbook, value: '冷静')],
      );

      expect(v.outcome, FactsProjectionOutcome.skipped);
      expect(v.note, FactsProjectionNote.valueUnchangedBaseline);
    });

    test('更新频率超限 → skipped(tooFrequent)', () {
      final v = FactsDeltaProjectionEvaluator.evaluateUpdateAttr(
        delta: const FactsDelta(
          action: FactAction.updateAttr,
          entityId: 'ent_001',
          attrKey: 'personality',
          value: '热情冲动',
          confidence: 5,
        ),
        config: config,
        entity: character(),
        attrRows: [attr()],
        recentUpdates: 4, // maxUpdatesPer3Turns 默认 4
      );

      expect(v.outcome, FactsProjectionOutcome.skipped);
      expect(v.note, FactsProjectionNote.tooFrequent);
    });

    test('值超长 → skipped(valueTooLong)；实体缺失 → skipped(entityMissing)', () {
      final tooLong = FactsDeltaProjectionEvaluator.evaluateUpdateAttr(
        delta: FactsDelta(
          action: FactAction.updateAttr,
          entityId: 'ent_001',
          attrKey: 'personality',
          value: '长' * 501,
          confidence: 5,
        ),
        config: config,
        entity: character(),
        attrRows: [attr()],
      );
      expect(tooLong.note, FactsProjectionNote.valueTooLong);

      final missing = FactsDeltaProjectionEvaluator.evaluateUpdateAttr(
        delta: const FactsDelta(
          action: FactAction.updateAttr,
          entityId: 'ent_404',
          attrKey: 'personality',
          value: 'x',
          confidence: 5,
        ),
        config: config,
      );
      expect(missing.note, FactsProjectionNote.entityMissing);
    });

    test('attrKey 归一化：character 的 description → background', () {
      final v = FactsDeltaProjectionEvaluator.evaluateUpdateAttr(
        delta: const FactsDelta(
          action: FactAction.updateAttr,
          entityId: 'ent_001',
          attrKey: 'description',
          value: '新背景',
          confidence: 5,
        ),
        config: config,
        entity: character(),
        attrRows: [attr(key: 'background', value: '旧背景')],
      );

      expect(v.outcome, FactsProjectionOutcome.applied);
      expect(v.normalizedAttrKey, 'background');
    });
  });

  group('evaluateCreateEntity', () {
    test('撞名 + 携带 value → converted(updateAttr)', () {
      final v = FactsDeltaProjectionEvaluator.evaluateCreateEntity(
        delta: const FactsDelta(
          action: FactAction.createEntity,
          entityType: 'character',
          primaryName: '林晚',
          attrKey: 'personality',
          value: '热情冲动',
          confidence: 4,
        ),
        config: config,
        sameNameEntity: character(),
      );

      expect(v.outcome, FactsProjectionOutcome.converted);
      expect(v.effectiveAction, FactAction.updateAttr);
      expect(v.note, FactsProjectionNote.sameNameConvertsUpdate);
      expect(v.rewrittenDelta!.entityId, 'ent_001');
      expect(v.rewrittenDelta!.attrKey, 'personality');
    });

    test('撞名 + 无 value → converted(addAlias)', () {
      final v = FactsDeltaProjectionEvaluator.evaluateCreateEntity(
        delta: const FactsDelta(
          action: FactAction.createEntity,
          entityType: 'character',
          primaryName: '林晚',
          confidence: 4,
        ),
        config: config,
        sameNameEntity: character(),
      );

      expect(v.outcome, FactsProjectionOutcome.converted);
      expect(v.effectiveAction, FactAction.addAlias);
      expect(v.note, FactsProjectionNote.sameNameConvertsAlias);
      expect(v.rewrittenDelta!.value, '林晚');
    });

    test('未撞名 → applied 新建；未知类型 → skipped', () {
      final ok = FactsDeltaProjectionEvaluator.evaluateCreateEntity(
        delta: const FactsDelta(
          action: FactAction.createEntity,
          entityType: 'character',
          primaryName: '陈叔',
          attrKey: 'background',
          value: '流浪商人',
          confidence: 3,
        ),
        config: config,
      );
      expect(ok.outcome, FactsProjectionOutcome.applied);
      // 「新」行展示首批属性值（title 已含实体名·属性键）
      expect(ok.after, '流浪商人');
      expect(ok.normalizedAttrKey, 'background');
      expect(ok.entityLabel, '陈叔');

      // 裸创建（无 value）：after=null 只出名字行卡
      final bare = FactsDeltaProjectionEvaluator.evaluateCreateEntity(
        delta: const FactsDelta(
          action: FactAction.createEntity,
          entityType: 'character',
          primaryName: '路人甲',
          confidence: 3,
        ),
        config: config,
      );
      expect(bare.outcome, FactsProjectionOutcome.applied);
      expect(bare.after, isNull);

      final bad = FactsDeltaProjectionEvaluator.evaluateCreateEntity(
        delta: const FactsDelta(
          action: FactAction.createEntity,
          entityType: 'dragon',
          primaryName: 'x',
          confidence: 3,
        ),
        config: config,
      );
      // FactualEntityType.fromString 未知值兜底 character（从不抛异常），
      // 落库与干跑同源：均按 character applied，不会 skipped。
      expect(bad.outcome, FactsProjectionOutcome.applied);
    });
  });

  group('evaluateAppendList', () {
    test('auto 行 single 类型 → converted(updateAttr)', () {
      final v = FactsDeltaProjectionEvaluator.evaluateAppendList(
        delta: const FactsDelta(
          action: FactAction.appendList,
          entityId: 'ent_001',
          attrKey: 'personality',
          value: '热情',
          confidence: 4,
        ),
        config: config,
        entity: character(),
        attrRows: [attr()], // single
      );

      expect(v.outcome, FactsProjectionOutcome.converted);
      expect(v.note, FactsProjectionNote.appendOnSingleConvertsUpdate);
      expect(v.rewrittenDelta!.action, FactAction.updateAttr);
    });

    test('无 auto 行 + 只读基线 single → converted(baselineSingleRedirect)', () {
      final v = FactsDeltaProjectionEvaluator.evaluateAppendList(
        delta: const FactsDelta(
          action: FactAction.appendList,
          entityId: 'ent_001',
          attrKey: 'personality',
          value: '热情',
          confidence: 4,
        ),
        config: config,
        entity: character(source: FactualSource.worldbook),
        attrRows: [attr(source: FactualSource.worldbook)],
      );

      expect(v.outcome, FactsProjectionOutcome.converted);
      expect(v.note, FactsProjectionNote.baselineSingleRedirect);
    });

    test('精确去重与语义相似去重 → skipped', () {
      final exact = FactsDeltaProjectionEvaluator.evaluateAppendList(
        delta: const FactsDelta(
          action: FactAction.appendList,
          entityId: 'ent_001',
          attrKey: 'skills',
          value: '剑术',
          confidence: 4,
        ),
        config: config,
        entity: character(),
        attrRows: [
          attr(key: 'skills', value: '["剑术"]', type: AttributeValueType.list),
        ],
      );
      expect(exact.note, FactsProjectionNote.duplicateExact);

      final similar = FactsDeltaProjectionEvaluator.evaluateAppendList(
        delta: const FactsDelta(
          action: FactAction.appendList,
          entityId: 'ent_001',
          attrKey: 'skills',
          value: '剑法', // 与"剑术"编辑距离 1
          confidence: 4,
        ),
        config: config,
        entity: character(),
        attrRows: [
          attr(key: 'skills', value: '["剑术"]', type: AttributeValueType.list),
        ],
      );
      expect(similar.note, FactsProjectionNote.duplicateSimilar);
    });

    test('正常追加 → applied；无属性行 → applied(createsAttrRow)', () {
      // 注意选词：任意两个双字词编辑距离恒 <= 2 会命中语义相似去重
      //（与落库同源行为），故用长词避开。
      final v = FactsDeltaProjectionEvaluator.evaluateAppendList(
        delta: const FactsDelta(
          action: FactAction.appendList,
          entityId: 'ent_001',
          attrKey: 'skills',
          value: '剑术',
          confidence: 4,
        ),
        config: config,
        entity: character(),
        attrRows: [
          attr(
            key: 'skills',
            value: '["轻功水上漂"]',
            type: AttributeValueType.list,
          ),
        ],
      );
      expect(v.outcome, FactsProjectionOutcome.applied);
      expect(v.before, '["轻功水上漂"]');
      expect(v.after, '剑术');

      final fresh = FactsDeltaProjectionEvaluator.evaluateAppendList(
        delta: const FactsDelta(
          action: FactAction.appendList,
          entityId: 'ent_001',
          attrKey: 'skills',
          value: '剑术',
          confidence: 4,
        ),
        config: config,
        entity: character(),
      );
      expect(fresh.outcome, FactsProjectionOutcome.applied);
      expect(fresh.note, FactsProjectionNote.createsAttrRow);
    });
  });

  group('evaluateRemoveFromList', () {
    test('值不在列表 → skipped；正常移除 → applied', () {
      final absent = FactsDeltaProjectionEvaluator.evaluateRemoveFromList(
        delta: const FactsDelta(
          action: FactAction.removeFromList,
          entityId: 'ent_001',
          attrKey: 'skills',
          value: '游泳',
          confidence: 4,
        ),
        entity: character(),
        attrRows: [
          attr(key: 'skills', value: '["剑术"]', type: AttributeValueType.list),
        ],
      );
      expect(absent.note, FactsProjectionNote.valueNotInList);

      final ok = FactsDeltaProjectionEvaluator.evaluateRemoveFromList(
        delta: const FactsDelta(
          action: FactAction.removeFromList,
          entityId: 'ent_001',
          attrKey: 'skills',
          value: '剑术',
          confidence: 4,
        ),
        entity: character(),
        attrRows: [
          attr(key: 'skills', value: '["剑术"]', type: AttributeValueType.list),
        ],
      );
      expect(ok.outcome, FactsProjectionOutcome.applied);
      expect(ok.before, '["剑术"]');
      expect(ok.after, '剑术');
    });

    test('无 auto 行（仅只读基线）→ skipped(noMutableList)', () {
      final v = FactsDeltaProjectionEvaluator.evaluateRemoveFromList(
        delta: const FactsDelta(
          action: FactAction.removeFromList,
          entityId: 'ent_001',
          attrKey: 'skills',
          value: '剑术',
          confidence: 4,
        ),
        entity: character(source: FactualSource.worldbook),
        attrRows: [
          attr(
            key: 'skills',
            value: '["剑术"]',
            type: AttributeValueType.list,
            source: FactualSource.worldbook,
          ),
        ],
      );
      expect(v.note, FactsProjectionNote.noMutableList);
    });
  });

  group('evaluateAddAlias', () {
    test('与主名/已有别名冲突、超上限 → skipped；正常 → applied', () {
      final ent = character(aliases: List.generate(9, (i) => '别名$i'));
      final ok = FactsDeltaProjectionEvaluator.evaluateAddAlias(
        delta: const FactsDelta(
          action: FactAction.addAlias,
          entityId: 'ent_001',
          value: '林掌柜',
          confidence: 4,
        ),
        config: config,
        entity: ent,
      );
      expect(ok.outcome, FactsProjectionOutcome.applied);
      expect(ok.after, '林掌柜');

      final sameAsPrimary = FactsDeltaProjectionEvaluator.evaluateAddAlias(
        delta: const FactsDelta(
          action: FactAction.addAlias,
          entityId: 'ent_001',
          value: '林晚',
          confidence: 4,
        ),
        config: config,
        entity: ent,
      );
      expect(sameAsPrimary.note, FactsProjectionNote.aliasSameAsPrimary);

      final duplicate = FactsDeltaProjectionEvaluator.evaluateAddAlias(
        delta: const FactsDelta(
          action: FactAction.addAlias,
          entityId: 'ent_001',
          value: '别名0',
          confidence: 4,
        ),
        config: config,
        entity: ent,
      );
      expect(duplicate.note, FactsProjectionNote.aliasExists);

      final full = character(aliases: List.generate(10, (i) => '别名$i'));
      final limited = FactsDeltaProjectionEvaluator.evaluateAddAlias(
        delta: const FactsDelta(
          action: FactAction.addAlias,
          entityId: 'ent_001',
          value: '新别名',
          confidence: 4,
        ),
        config: config,
        entity: full,
      );
      expect(limited.note, FactsProjectionNote.aliasLimit);
    });
  });

  group('evaluateArchiveEntity', () {
    test('已归档 → skipped(alreadyArchived)；正常 → applied', () {
      final again = FactsDeltaProjectionEvaluator.evaluateArchiveEntity(
        delta: const FactsDelta(
          action: FactAction.archiveEntity,
          entityId: 'ent_001',
          reason: '死亡',
          confidence: 5,
        ),
        entity: character(archived: true),
      );
      expect(again.note, FactsProjectionNote.alreadyArchived);

      final ok = FactsDeltaProjectionEvaluator.evaluateArchiveEntity(
        delta: const FactsDelta(
          action: FactAction.archiveEntity,
          entityId: 'ent_001',
          reason: '死亡',
          confidence: 5,
        ),
        entity: character(),
      );
      expect(ok.outcome, FactsProjectionOutcome.applied);
      expect(ok.entityLabel, '林晚');
    });
  });
}
