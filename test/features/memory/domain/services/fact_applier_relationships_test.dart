import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/features/memory/domain/entities/facts_delta.dart';
import 'package:lmstory/features/memory/domain/entities/factual_attribute.dart';
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
import 'package:lmstory/features/memory/domain/services/fact_applier.dart';

import '../../../../helpers/fake_factual_repository.dart';

/// 关系属性语义测试：按对象拆分保存 + dict 防覆盖 + 别名规范化
///
/// 语义契约：
/// - 个人关系走 `relationship:<对象名>`（single，update 完整当前描述）
/// - 群体/笼统关系留在 `relationships`（dict，update 整体维护，禁止 append）
/// - append_list 对 dict 行一律跳过，不得覆盖既有数据（含新建错型分支）
void main() {
  final t = DateTime(2026, 11, 8, 12);
  late FakeFactualRepository repo;
  late FactApplier applier;

  setUp(() {
    repo = FakeFactualRepository();
    applier = FactApplier(repository: repo);
  });

  FactualEntity character({
    required String id,
    required String name,
    List<String> aliases = const [],
  }) =>
      FactualEntity(
        entityId: id,
        sessionId: 's1',
        type: FactualEntityType.character,
        primaryName: name,
        aliases: aliases,
        importance: 4,
        createdTurn: 1,
        createdAt: t,
      );

  FactualAttribute dictRelationships({
    String attrId = 'attr_rel',
    String entityId = 'ent_lin',
    String value = '{"苏晴": "信任，曾受其救助", "顾远": "保持戒心"}',
  }) =>
      FactualAttribute(
        attributeId: attrId,
        entityId: entityId,
        sessionId: 's1',
        attrKey: 'relationships',
        value: value,
        valueType: AttributeValueType.dict,
        importance: 3,
        createdAt: t,
      );

  FactualAttribute singleAttr({
    required String attrId,
    required String entityId,
    required String key,
    required String value,
  }) =>
      FactualAttribute(
        attributeId: attrId,
        entityId: entityId,
        sessionId: 's1',
        attrKey: key,
        value: value,
        importance: 3,
        createdAt: t,
      );

  group('append_list 对 dict 关系属性的防覆盖守卫', () {
    test('追加到已有 dict 行：跳过且原 dict 值不被覆盖', () async {
      repo
        ..entitiesById = {
          'ent_lin': character(id: 'ent_lin', name: '林舟'),
        }
        ..attributesByKey = {
          ('ent_lin', 'relationships'): [dictRelationships()],
        };
      const delta = FactsDelta(
        action: FactAction.appendList,
        entityId: 'ent_lin',
        attrKey: 'relationships',
        value: '陈默=怀疑',
        confidence: 5,
      );

      final result =
          await applier.applyDeltas('s1', [delta], 3, const FactualConfig());

      expect(result, isEmpty, reason: 'dict 行 append 必须被跳过');
      expect(repo.updatedAttributes, isEmpty, reason: '不得产生任何覆盖写');
      final row = repo.attributesByKey[('ent_lin', 'relationships')]!.single;
      final decoded = jsonDecode(row.value) as Map<String, dynamic>;
      expect(decoded.containsKey('苏晴'), isTrue, reason: '旧关系不得丢失');
      expect(decoded.containsKey('顾远'), isTrue);
    });

    test('relationships 无任何行时 append_list：不再新建 list 错型行', () async {
      repo.entitiesById = {
        'ent_lin': character(id: 'ent_lin', name: '林舟'),
      };
      const delta = FactsDelta(
        action: FactAction.appendList,
        entityId: 'ent_lin',
        attrKey: 'relationships',
        value: '陈默=怀疑',
        confidence: 5,
      );

      final result =
          await applier.applyDeltas('s1', [delta], 3, const FactualConfig());

      expect(result, isEmpty);
      expect(repo.createdAttributes, isEmpty, reason: '不得为 dict 键新建 list 行');
    });

    test('remove_from_list 对 dict 行维持既有 noMutableList 跳过', () async {
      repo
        ..entitiesById = {
          'ent_lin': character(id: 'ent_lin', name: '林舟'),
        }
        ..attributesByKey = {
          ('ent_lin', 'relationships'): [dictRelationships()],
        };
      const delta = FactsDelta(
        action: FactAction.removeFromList,
        entityId: 'ent_lin',
        attrKey: 'relationships',
        value: '苏晴',
        confidence: 5,
      );

      final result =
          await applier.applyDeltas('s1', [delta], 3, const FactualConfig());
      expect(result, isEmpty);
      expect(repo.updatedAttributes, isEmpty);
    });
  });

  group('relationship:<对象名> 按对象独立保存', () {
    test('更新某对象关系不影响其他个人关系与群体关系', () async {
      repo
        ..entitiesById = {
          'ent_lin': character(id: 'ent_lin', name: '林舟'),
          'ent_su': character(id: 'ent_su', name: '苏晴'),
          'ent_gu': character(id: 'ent_gu', name: '顾远'),
        }
        ..attributesByKey = {
          ('ent_lin', 'relationships'): [
            dictRelationships(value: '{"师门众人": "交恶"}'),
          ],
          ('ent_lin', 'relationship:苏晴'): [
            singleAttr(
              attrId: 'attr_rel_su',
              entityId: 'ent_lin',
              key: 'relationship:苏晴',
              value: '信任，曾受其救助',
            ),
          ],
          ('ent_lin', 'relationship:顾远'): [
            singleAttr(
              attrId: 'attr_rel_gu',
              entityId: 'ent_lin',
              key: 'relationship:顾远',
              value: '保持戒心',
            ),
          ],
        };
      const delta = FactsDelta(
        action: FactAction.updateAttr,
        entityId: 'ent_lin',
        attrKey: 'relationship:苏晴',
        value: '信任加深，结为挚友',
        reason: '共同经历生死考验',
        confidence: 5,
      );

      final result =
          await applier.applyDeltas('s1', [delta], 5, const FactualConfig());

      expect(result.length, 1);
      expect(result.single.action, FactAction.updateAttr);
      expect(repo.updatedAttributes['attr_rel_su'], '信任加深，结为挚友');
      expect(
        repo.updatedAttributes.containsKey('attr_rel_gu'),
        isFalse,
        reason: '与顾远的关系不受影响',
      );
      expect(
        repo.updatedAttributes.containsKey('attr_rel'),
        isFalse,
        reason: '群体关系 dict 不受影响',
      );
      // 历史可回查：审计行携带变更前值
      final history = repo.histories.last;
      expect(history.oldValue, '信任，曾受其救助');
      expect(history.newValue, '信任加深，结为挚友');
    });

    test('新建 relationship 行（此前无该对象关系）', () async {
      repo
        ..entitiesById = {
          'ent_lin': character(id: 'ent_lin', name: '林舟'),
          'ent_chen': character(id: 'ent_chen', name: '陈默'),
        }
        ..attributesByKey = {
          ('ent_lin', 'relationships'): [
            dictRelationships(value: '{"师门众人": "交恶"}'),
          ],
        };
      const delta = FactsDelta(
        action: FactAction.updateAttr,
        entityId: 'ent_lin',
        attrKey: 'relationship:陈默',
        value: '初识，心存怀疑',
        reason: '首次相遇',
        confidence: 4,
      );

      final result =
          await applier.applyDeltas('s1', [delta], 2, const FactualConfig());

      expect(result.length, 1);
      final created = repo.createdAttributes
          .where((a) => a.attrKey == 'relationship:陈默')
          .toList();
      expect(created.length, 1, reason: '新建该对象的独立关系行');
      expect(created.single.valueType, AttributeValueType.single);
      // 群体 dict 不被动
      expect(repo.updatedAttributes, isEmpty);
    });

    test('别名键规范化：relationship:小晴 归一到 relationship:苏晴', () async {
      repo
        ..entitiesById = {
          'ent_lin': character(id: 'ent_lin', name: '林舟'),
          'ent_su': character(id: 'ent_su', name: '苏晴', aliases: const ['小晴']),
        }
        ..attributesByKey = {
          ('ent_lin', 'relationship:苏晴'): [
            singleAttr(
              attrId: 'attr_rel_su',
              entityId: 'ent_lin',
              key: 'relationship:苏晴',
              value: '信任',
            ),
          ],
        };
      const delta = FactsDelta(
        action: FactAction.updateAttr,
        entityId: 'ent_lin',
        attrKey: 'relationship:小晴',
        value: '信任加深',
        reason: '共同历险',
        confidence: 5,
      );

      final result =
          await applier.applyDeltas('s1', [delta], 5, const FactualConfig());

      expect(result.length, 1);
      expect(
        repo.updatedAttributes['attr_rel_su'],
        '信任加深',
        reason: '别名键应命中既有规范化行，而非新建一行',
      );
      expect(
        repo.createdAttributes.where((a) => a.attrKey.contains('小晴')).toList(),
        isEmpty,
      );
    });

    test('对象不可解析（无同名实体）：保留模型原键，不猜测绑定', () async {
      repo.entitiesById = {
        'ent_lin': character(id: 'ent_lin', name: '林舟'),
      };
      const delta = FactsDelta(
        action: FactAction.updateAttr,
        entityId: 'ent_lin',
        attrKey: 'relationship:神秘人',
        value: '来历不明，警惕',
        reason: '初次照面',
        confidence: 4,
      );

      final result =
          await applier.applyDeltas('s1', [delta], 2, const FactualConfig());

      expect(result.length, 1);
      final created = repo.createdAttributes.single;
      expect(created.attrKey, 'relationship:神秘人');
    });

    test('对象名歧义（两实体共享该别名）：保留模型原键', () async {
      repo
        ..entitiesById = {
          'ent_lin': character(id: 'ent_lin', name: '林舟'),
          'ent_a': character(id: 'ent_a', name: '苏甲', aliases: const ['阿苏']),
          'ent_b': character(id: 'ent_b', name: '苏乙', aliases: const ['阿苏']),
        }
        ..attributesByKey = {};
      const delta = FactsDelta(
        action: FactAction.updateAttr,
        entityId: 'ent_lin',
        attrKey: 'relationship:阿苏',
        value: '合作中',
        reason: '共同任务',
        confidence: 4,
      );

      final result =
          await applier.applyDeltas('s1', [delta], 2, const FactualConfig());

      expect(result.length, 1);
      expect(repo.createdAttributes.single.attrKey, 'relationship:阿苏');
    });
  });

  group('群体关系 dict 的整体更新仍可用', () {
    test('update_attr 整体更新 relationships dict（群体表述）', () async {
      repo
        ..entitiesById = {
          'ent_lin': character(id: 'ent_lin', name: '林舟'),
        }
        ..attributesByKey = {
          ('ent_lin', 'relationships'): [
            dictRelationships(value: '{"师门众人": "交恶"}'),
          ],
        };
      const delta = FactsDelta(
        action: FactAction.updateAttr,
        entityId: 'ent_lin',
        attrKey: 'relationships',
        value: '{"师门众人": "交恶加深", "衙门": "被通缉"}',
        reason: '剧情推进',
        confidence: 5,
      );

      final result =
          await applier.applyDeltas('s1', [delta], 5, const FactualConfig());

      expect(result.length, 1);
      expect(
        repo.updatedAttributes['attr_rel'],
        '{"师门众人": "交恶加深", "衙门": "被通缉"}',
      );
      final history = repo.histories.last;
      expect(history.oldValue, '{"师门众人": "交恶"}');
    });
  });
}
