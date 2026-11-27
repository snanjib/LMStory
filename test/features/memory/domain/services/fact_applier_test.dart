import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/features/memory/domain/entities/facts_delta.dart';
import 'package:lmstory/features/memory/domain/entities/factual_attribute.dart';
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
import 'package:lmstory/features/memory/domain/entities/factual_source.dart';
import 'package:lmstory/features/memory/domain/services/fact_applier.dart';

import '../../../../helpers/fake_factual_repository.dart';

/// FactApplier 单元测试（DOC-11 §7 三重防护 + §7.4 5 层健康度防护）
///
/// 覆盖：
/// - 6 种 FactAction 的应用逻辑
/// - 三重防护：冲突检测 + 值未变 + 关键属性置信度
/// - 5 层健康度防护：schema 白名单 + 长度上限 + 更新频率 + 去重
/// - 边界：enabled=false、deltas 为空、必填字段缺失
void main() {
  final t = DateTime(2026, 7, 1, 12);
  late FakeFactualRepository repo;
  late FactApplier applier;

  setUp(() {
    repo = FakeFactualRepository();
    applier = FactApplier(repository: repo);
  });

  FactualEntity characterEntity({
    String id = 'ent_001',
    String name = '李逍遥',
    List<String> aliases = const [],
    int importance = 5,
    bool archived = false,
    int? updatedTurn,
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
        updatedTurn: updatedTurn,
      );

  FactualEntity npcEntity({
    String id = 'ent_n1',
    String name = 'Elara',
    List<String> aliases = const [],
    int importance = 4,
    bool archived = false,
    int? updatedTurn,
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
        updatedTurn: updatedTurn,
      );

  FactualEntity petEntity({
    String id = 'ent_p1',
    String name = '小金',
    List<String> aliases = const [],
    int importance = 4,
    bool archived = false,
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
      );

  FactualAttribute singleAttr({
    String attrId = 'attr_001',
    String entityId = 'ent_001',
    String key = 'personality',
    String value = '开朗',
    int importance = 4,
  }) =>
      FactualAttribute(
        attributeId: attrId,
        entityId: entityId,
        sessionId: 's1',
        attrKey: key,
        value: value,
        importance: importance,
        createdAt: t,
      );

  FactualAttribute listAttr({
    String attrId = 'attr_003',
    String entityId = 'ent_001',
    String key = 'skills',
    String value = '["御剑术"]',
    int importance = 3,
  }) =>
      FactualAttribute(
        attributeId: attrId,
        entityId: entityId,
        sessionId: 's1',
        attrKey: key,
        value: value,
        valueType: AttributeValueType.list,
        importance: importance,
        createdAt: t,
      );

  group('applyDeltas 边界', () {
    test('enabled=false 跳过所有 deltas', () async {
      const delta = FactsDelta(
        action: FactAction.createEntity,
        entityType: 'character',
        primaryName: '李逍遥',
        confidence: 5,
      );
      final result = await applier.applyDeltas(
        's1',
        [delta],
        1,
        const FactualConfig(enabled: false),
      );
      expect(result.length, 0);
      expect(repo.createdEntities, isEmpty);
    });

    test('deltas 为空返回 0', () async {
      final result = await applier.applyDeltas(
        's1',
        const [],
        1,
        const FactualConfig(),
      );
      expect(result.length, 0);
    });
  });

  group('create_entity', () {
    test('正常创建实体 + 审计日志 + 默认重要性 3（character 保守默认）', () async {
      const delta = FactsDelta(
        action: FactAction.createEntity,
        entityType: 'character',
        primaryName: '李逍遥',
        confidence: 5,
      );
      final result =
          await applier.applyDeltas('s1', [delta], 1, const FactualConfig());

      expect(result.length, 1);
      expect(result.single.action, FactAction.createEntity);
      expect(result.single.newValue, '李逍遥');
      expect(repo.createdEntities.single.primaryName, '李逍遥');
      expect(repo.createdEntities.single.importance, 3);
      expect(repo.histories.single.action, FactAction.createEntity);
    });

    test('create_entity 带 LLM 评分 importance', () async {
      const delta = FactsDelta(
        action: FactAction.createEntity,
        entityType: 'character',
        primaryName: '主角',
        confidence: 5,
        importance: 5,
      );
      final result =
          await applier.applyDeltas('s1', [delta], 1, const FactualConfig());

      expect(result.length, 1);
      expect(repo.createdEntities.single.importance, 5);
    });

    test('create_entity importance 超范围自动截断', () async {
      const delta = FactsDelta(
        action: FactAction.createEntity,
        entityType: 'character',
        primaryName: '测试',
        confidence: 5,
        importance: 99,
      );
      final result =
          await applier.applyDeltas('s1', [delta], 1, const FactualConfig());

      expect(result.length, 1);
      expect(repo.createdEntities.single.importance, 5);
    });

    test('create_entity 相似名既有实体 → 只告警，照常创建', () async {
      // 既有"庄园"，新实体"边境庄园"为包含关系：不自动转换、不拒绝，
      // 归并决策交给记忆查看器手动合并或导演模式 merge_entities 工具
      repo.entitiesById['ent_loc1'] = FactualEntity(
        entityId: 'ent_loc1',
        sessionId: 's1',
        type: FactualEntityType.location,
        primaryName: '庄园',
        aliases: const [],
        importance: 3,
        createdTurn: 1,
        createdAt: t,
      );
      const delta = FactsDelta(
        action: FactAction.createEntity,
        entityType: 'location',
        primaryName: '边境庄园',
        confidence: 4,
      );
      final result =
          await applier.applyDeltas('s1', [delta], 2, const FactualConfig());

      expect(result.length, 1);
      expect(repo.createdEntities.single.primaryName, '边境庄园');
      expect(repo.createdEntities, hasLength(1));
    });

    test('isNameContainmentSimilar 包含关系判定规则', () {
      const similar = FactApplier.isNameContainmentSimilar;
      // 双向包含命中
      expect(similar('边境庄园', '庄园'), isTrue);
      expect(similar('庄园', '边境庄园'), isTrue);
      // 完全相同不算相似（精确查重已处理）
      expect(similar('庄园', '庄园'), isFalse);
      // 单字符短名无区分价值
      expect(similar('断水剑', '剑'), isFalse);
      expect(similar('剑', '断水剑'), isFalse);
      // 无包含关系
      expect(similar('李逍遥', '林月如'), isFalse);
      // 空串防护
      expect(similar('', '庄园'), isFalse);
      expect(similar('庄园', ''), isFalse);
    });

    test('create_entity 带属性初始化', () async {
      const delta = FactsDelta(
        action: FactAction.createEntity,
        entityType: 'character',
        primaryName: '李逍遥',
        attrKey: 'species',
        value: '人族',
        confidence: 5,
      );
      final result =
          await applier.applyDeltas('s1', [delta], 1, const FactualConfig());

      expect(result.length, 1);
      expect(repo.createdAttributes.single.attrKey, 'species');
      expect(repo.createdAttributes.single.value, '人族');
    });

    test('primaryName 与已有实体主名相同 → 视为重复创建，不写入新别名（DOC-11 §10.3）', () async {
      // 当前实现：findByName 命中后转 addAlias，但 addAlias 检查
      // "别名与主名相同"会跳过。等价于"已存在相同主名实体，无变更"。
      repo.entitiesById = {'ent_001': characterEntity()};
      const delta = FactsDelta(
        action: FactAction.createEntity,
        entityType: 'character',
        primaryName: '李逍遥',
        confidence: 4,
      );
      final result =
          await applier.applyDeltas('s1', [delta], 3, const FactualConfig());

      expect(result.length, 0);
      expect(repo.createdEntities, isEmpty);
      expect(repo.updatedAliases, isEmpty);
    });

    test('entityType 缺失 → 跳过（必填字段校验）', () async {
      const delta = FactsDelta(
        action: FactAction.createEntity,
        primaryName: '李逍遥',
        confidence: 5,
      );
      expect(
        (await applier.applyDeltas('s1', [delta], 1, const FactualConfig()))
            .length,
        0,
      );
    });
  });

  group('create_entity value 兜底落属性（导演模式裸实体修复，2026-08-23）', () {
    FactualEntity locationEntity({
      String id = 'ent_l1',
      String name = '史家庄园',
    }) =>
        FactualEntity(
          entityId: id,
          sessionId: 's1',
          type: FactualEntityType.location,
          primaryName: name,
          aliases: const [],
          importance: 2,
          createdTurn: 1,
          createdAt: t,
        );

    test('带 value 无 attr_key（location）→ 默认落 description，不再静默丢弃', () async {
      const delta = FactsDelta(
        action: FactAction.createEntity,
        entityType: 'location',
        primaryName: '史家庄园',
        value: '史鹤鸣与钟嫣的住所，郊区大型庄园',
        confidence: 4,
      );
      final result =
          await applier.applyDeltas('s1', [delta], 1, const FactualConfig());

      expect(result.length, 1);
      expect(repo.createdEntities.single.primaryName, '史家庄园');
      expect(repo.createdAttributes.single.attrKey, 'description');
      expect(
        repo.createdAttributes.single.value,
        '史鹤鸣与钟嫣的住所，郊区大型庄园',
      );
    });

    test('带 value 无 attr_key（character）→ 默认落 background', () async {
      const delta = FactsDelta(
        action: FactAction.createEntity,
        entityType: 'character',
        primaryName: '李逍遥',
        value: '客栈伙计，梦想成为侠客',
        confidence: 4,
      );
      final result =
          await applier.applyDeltas('s1', [delta], 1, const FactualConfig());

      expect(result.length, 1);
      expect(repo.createdAttributes.single.attrKey, 'background');
      expect(repo.createdAttributes.single.value, '客栈伙计，梦想成为侠客');
    });

    test('无 value 无 attr_key → 保持不建属性', () async {
      const delta = FactsDelta(
        action: FactAction.createEntity,
        entityType: 'location',
        primaryName: '荒庙',
        confidence: 4,
      );
      await applier.applyDeltas('s1', [delta], 1, const FactualConfig());

      expect(repo.createdEntities, hasLength(1));
      expect(repo.createdAttributes, isEmpty);
    });

    test('已存在同名实体 + value 无 attr_key → 转 update_attr 补 description，不丢 value',
        () async {
      repo.entitiesById = {'ent_l1': locationEntity()};
      const delta = FactsDelta(
        action: FactAction.createEntity,
        entityType: 'location',
        primaryName: '史家庄园',
        value: '主宅年久失修，庭院荒废',
        confidence: 5,
      );
      final result =
          await applier.applyDeltas('s1', [delta], 3, const FactualConfig());

      expect(result.length, 1);
      expect(result.single.action, FactAction.updateAttr);
      expect(repo.createdEntities, isEmpty); // 不重复建实体
      expect(repo.createdAttributes.single.entityId, 'ent_l1');
      expect(repo.createdAttributes.single.attrKey, 'description');
      expect(repo.createdAttributes.single.value, '主宅年久失修，庭院荒废');
    });
  });

  group('按 primary_name 解析实体（entityId 缺失兜底）', () {
    test('update_attr 用 primary_name 代替 entity_id → 按名解析成功', () async {
      repo.entitiesById = {'ent_001': characterEntity()};
      const delta = FactsDelta(
        action: FactAction.updateAttr,
        primaryName: '李逍遥',
        attrKey: 'personality',
        value: '开朗热血',
        confidence: 5,
      );
      final result =
          await applier.applyDeltas('s1', [delta], 2, const FactualConfig());

      expect(result.length, 1);
      expect(repo.createdAttributes.single.entityId, 'ent_001');
      expect(repo.createdAttributes.single.attrKey, 'personality');
      expect(repo.createdAttributes.single.value, '开朗热血');
    });

    test('primary_name 未命中任何实体 → 跳过', () async {
      repo.entitiesById = {'ent_001': characterEntity()};
      const delta = FactsDelta(
        action: FactAction.updateAttr,
        primaryName: '不存在的人',
        attrKey: 'personality',
        value: '开朗',
        confidence: 5,
      );
      final result =
          await applier.applyDeltas('s1', [delta], 2, const FactualConfig());

      expect(result, isEmpty);
      expect(repo.createdAttributes, isEmpty);
    });

    test('primary_name 命中多个实体（歧义）→ 跳过不误伤', () async {
      repo.entitiesById = {
        'ent_001': characterEntity(),
        'ent_002': characterEntity(
          id: 'ent_002',
          name: '赵灵儿',
          aliases: ['李逍遥'],
        ),
      };
      const delta = FactsDelta(
        action: FactAction.updateAttr,
        primaryName: '李逍遥',
        attrKey: 'personality',
        value: '开朗',
        confidence: 5,
      );
      final result =
          await applier.applyDeltas('s1', [delta], 2, const FactualConfig());

      expect(result, isEmpty);
      expect(repo.createdAttributes, isEmpty);
    });
  });

  group('update_attr 三重防护', () {
    test('正常更新 + 审计日志记录新旧值', () async {
      repo
        ..entitiesById = {'ent_001': characterEntity()}
        ..attributesByKey = {
          ('ent_001', 'personality'): [singleAttr()],
        };
      const delta = FactsDelta(
        action: FactAction.updateAttr,
        entityId: 'ent_001',
        attrKey: 'personality',
        value: '沉稳',
        reason: '剧情成长',
        confidence: 5,
      );
      final result =
          await applier.applyDeltas('s1', [delta], 3, const FactualConfig());

      expect(result.length, 1);
      expect(result.single.action, FactAction.updateAttr);
      expect(result.single.oldValue, '开朗');
      expect(result.single.newValue, '沉稳');
      expect(repo.updatedAttributes['attr_001'], '沉稳');
      expect(repo.histories.single.oldValue, '开朗');
      expect(repo.histories.single.newValue, '沉稳');
    });

    test('防护1：实体不存在 → 跳过', () async {
      const delta = FactsDelta(
        action: FactAction.updateAttr,
        entityId: 'ent_999',
        attrKey: 'personality',
        value: '沉稳',
        reason: 'x',
        confidence: 5,
      );
      expect(
        (await applier.applyDeltas('s1', [delta], 1, const FactualConfig()))
            .length,
        0,
      );
    });

    test('防护2：值未变 → 跳过', () async {
      repo
        ..entitiesById = {'ent_001': characterEntity()}
        ..attributesByKey = {
          ('ent_001', 'personality'): [singleAttr()],
        };
      const delta = FactsDelta(
        action: FactAction.updateAttr,
        entityId: 'ent_001',
        attrKey: 'personality',
        value: '开朗',
        reason: 'x',
        confidence: 5,
      );
      expect(
        (await applier.applyDeltas('s1', [delta], 3, const FactualConfig()))
            .length,
        0,
      );
    });

    test('防护3：关键属性（species, importance=5）低置信度被拒', () async {
      repo
        ..entitiesById = {'ent_001': characterEntity()}
        ..attributesByKey = {
          ('ent_001', 'species'): [
            singleAttr(
              attrId: 'attr_002',
              key: 'species',
              value: '人族',
              importance: 5,
            ),
          ],
        };
      const delta = FactsDelta(
        action: FactAction.updateAttr,
        entityId: 'ent_001',
        attrKey: 'species',
        value: '魔族',
        reason: '剧情反转',
        confidence: 2,
      );
      expect(
        (await applier.applyDeltas('s1', [delta], 3, const FactualConfig()))
            .length,
        0,
      );
      expect(repo.updatedAttributes, isEmpty);
    });

    test('防护3：关键属性高置信度允许修改', () async {
      repo
        ..entitiesById = {'ent_001': characterEntity()}
        ..attributesByKey = {
          ('ent_001', 'species'): [
            singleAttr(
              attrId: 'attr_002',
              key: 'species',
              value: '人族',
              importance: 5,
            ),
          ],
        };
      const delta = FactsDelta(
        action: FactAction.updateAttr,
        entityId: 'ent_001',
        attrKey: 'species',
        value: '魔族',
        reason: '剧情反转',
        confidence: 5,
      );
      expect(
        (await applier.applyDeltas('s1', [delta], 3, const FactualConfig()))
            .length,
        1,
      );
      expect(repo.updatedAttributes['attr_002'], '魔族');
    });

    test('schema 白名单：attrKey 不在白名单 -> 跳过', () async {
      // 使用 location 类型（严格白名单），character 允许自定义属性
      final location = FactualEntity(
        entityId: 'ent_l1',
        sessionId: 's1',
        type: FactualEntityType.location,
        primaryName: '村口',
        aliases: const [],
        importance: 2,
        createdTurn: 1,
        createdAt: t,
      );
      repo.entitiesById = {'ent_l1': location};
      const delta = FactsDelta(
        action: FactAction.updateAttr,
        entityId: 'ent_l1',
        attrKey: 'invalid_key',
        value: 'x',
        reason: 'x',
        confidence: 5,
      );
      expect(
        (await applier.applyDeltas('s1', [delta], 3, const FactualConfig()))
            .length,
        0,
      );
    });

    test('属性值超长 → 跳过', () async {
      repo.entitiesById = {'ent_001': characterEntity()};
      final longValue = 'a' * 100;
      final delta = FactsDelta(
        action: FactAction.updateAttr,
        entityId: 'ent_001',
        attrKey: 'background',
        value: longValue,
        reason: 'x',
        confidence: 5,
      );
      expect(
        (await applier.applyDeltas(
          's1',
          [delta],
          3,
          const FactualConfig(maxAttrValueLength: 10),
        ))
            .length,
        0,
      );
    });

    test('更新频率超限 → 跳过', () async {
      repo
        ..entitiesById = {'ent_001': characterEntity()}
        ..attributesByKey = {
          ('ent_001', 'personality'): [singleAttr()],
        }
        ..recentUpdateCounts = {'ent_001': 2};
      const delta = FactsDelta(
        action: FactAction.updateAttr,
        entityId: 'ent_001',
        attrKey: 'personality',
        value: '沉稳',
        reason: 'x',
        confidence: 5,
      );
      expect(
        (await applier.applyDeltas(
          's1',
          [delta],
          3,
          const FactualConfig(maxUpdatesPer3Turns: 2),
        ))
            .length,
        0,
      );
    });
  });

  group('append_list', () {
    test('正常追加新值', () async {
      repo
        ..entitiesById = {'ent_001': characterEntity()}
        ..attributesByKey = {
          ('ent_001', 'skills'): [listAttr()],
        };
      const delta = FactsDelta(
        action: FactAction.appendList,
        entityId: 'ent_001',
        attrKey: 'skills',
        value: '天雷破', // 与"御剑术"完全无字符重叠，编辑距离=3
        confidence: 5,
      );
      final result =
          await applier.applyDeltas('s1', [delta], 3, const FactualConfig());

      expect(result.length, 1);
      expect(result.single.action, FactAction.appendList);
      expect(result.single.newValue, '天雷破');
      final updated = repo.updatedAttributes['attr_003']!;
      expect((jsonDecode(updated) as List).cast<String>(), ['御剑术', '天雷破']);
    });

    test('精确去重：已存在值跳过', () async {
      repo
        ..entitiesById = {'ent_001': characterEntity()}
        ..attributesByKey = {
          ('ent_001', 'skills'): [listAttr()],
        };
      const delta = FactsDelta(
        action: FactAction.appendList,
        entityId: 'ent_001',
        attrKey: 'skills',
        value: '御剑术',
        confidence: 5,
      );
      expect(
        (await applier.applyDeltas('s1', [delta], 3, const FactualConfig()))
            .length,
        0,
      );
    });

    test('编辑距离相近的不同值不再判重：御剑数 与 御剑术 均保留', () async {
      repo
        ..entitiesById = {'ent_001': characterEntity()}
        ..attributesByKey = {
          ('ent_001', 'skills'): [listAttr()],
        };
      const delta = FactsDelta(
        action: FactAction.appendList,
        entityId: 'ent_001',
        attrKey: 'skills',
        value: '御剑数', // 编辑距离 1，但含义不同，应保存
        confidence: 5,
      );
      final result =
          await applier.applyDeltas('s1', [delta], 3, const FactualConfig());
      expect(result.length, 1);
      final updated = repo.updatedAttributes['attr_003']!;
      expect((jsonDecode(updated) as List).cast<String>(), ['御剑术', '御剑数']);
    });

    test('不同短值不判重：火球术 与 冰球术 均保存', () async {
      repo
        ..entitiesById = {'ent_001': characterEntity()}
        ..attributesByKey = {
          ('ent_001', 'skills'): [
            listAttr(value: '["火球术"]'),
          ],
        };
      const delta = FactsDelta(
        action: FactAction.appendList,
        entityId: 'ent_001',
        attrKey: 'skills',
        value: '冰球术',
        confidence: 5,
      );
      final result =
          await applier.applyDeltas('s1', [delta], 3, const FactualConfig());
      expect(result.length, 1);
      expect(repo.updatedAttributes['attr_003'], '["火球术","冰球术"]');
    });

    test('长值包含旧值不判重：御剑飞行 vs 含额外能力的长描述', () async {
      repo
        ..entitiesById = {'ent_001': characterEntity()}
        ..attributesByKey = {
          ('ent_001', 'skills'): [
            listAttr(value: '["御剑飞行"]'),
          ],
        };
      const delta = FactsDelta(
        action: FactAction.appendList,
        entityId: 'ent_001',
        attrKey: 'skills',
        value: '御剑飞行（可携带一名同伴）',
        confidence: 5,
      );
      final result =
          await applier.applyDeltas('s1', [delta], 3, const FactualConfig());
      expect(result.length, 1, reason: '包含关系不是重复，额外信息优先保留');
    });

    test('首尾空白变体去重：仅空格差异判为重复', () async {
      repo
        ..entitiesById = {'ent_001': characterEntity()}
        ..attributesByKey = {
          ('ent_001', 'skills'): [
            listAttr(value: '["火球术"]'),
          ],
        };
      const delta = FactsDelta(
        action: FactAction.appendList,
        entityId: 'ent_001',
        attrKey: 'skills',
        value: ' 火球术 ',
        confidence: 5,
      );
      final result =
          await applier.applyDeltas('s1', [delta], 3, const FactualConfig());
      expect(result, isEmpty);
      expect(repo.updatedAttributes, isEmpty);
    });

    test('single 类型收到 append_list → 转为 update_attr', () async {
      repo
        ..entitiesById = {'ent_001': characterEntity()}
        ..attributesByKey = {
          ('ent_001', 'personality'): [singleAttr()],
        };
      const delta = FactsDelta(
        action: FactAction.appendList,
        entityId: 'ent_001',
        attrKey: 'personality',
        value: '沉稳',
        confidence: 5,
      );
      expect(
        (await applier.applyDeltas('s1', [delta], 3, const FactualConfig()))
            .length,
        1,
      );
      expect(repo.updatedAttributes['attr_001'], '沉稳');
    });
  });

  group('改名转别名统一（不分 source）', () {
    test('auto 实体 update_attr(name) 转为 add_alias，主名不变', () async {
      repo.entitiesById = {
        'ent_001': characterEntity(aliases: const ['逍遥']),
      };
      const delta = FactsDelta(
        action: FactAction.updateAttr,
        entityId: 'ent_001',
        attrKey: 'name',
        value: '李掌门',
        reason: '用户明确改名',
        confidence: 5,
      );
      final result =
          await applier.applyDeltas('s1', [delta], 5, const FactualConfig());

      // 转为别名追加：旧主名不丢、新称呼可检索（注入侧自动合并）
      expect(result.single.action, FactAction.addAlias);
      expect(result.single.newValue, '李掌门');
      expect(repo.updatedAliases['ent_001'], ['逍遥', '李掌门']);
      // 主名不被改写（不再出现 update_attr 落属性行的旧路径）
      expect(
        repo.attributesByKey[('ent_001', 'name')],
        isNull,
        reason: '主名改写不落属性行（原缺陷：双源分叉）',
      );
    });

    test('auto 实体已有别名与新名重复 → 幂等跳过', () async {
      repo.entitiesById = {
        'ent_001': characterEntity(aliases: const ['李掌门']),
      };
      const delta = FactsDelta(
        action: FactAction.updateAttr,
        entityId: 'ent_001',
        attrKey: 'name',
        value: '李掌门',
        reason: '用户明确改名',
        confidence: 5,
      );
      final result =
          await applier.applyDeltas('s1', [delta], 5, const FactualConfig());
      expect(result.length, 0, reason: '别名已存在，无需重复追加');
    });
  });

  group('add_alias', () {
    test('正常追加别名', () async {
      repo.entitiesById = {
        'ent_001': characterEntity(aliases: const ['逍遥']),
      };
      const delta = FactsDelta(
        action: FactAction.addAlias,
        entityId: 'ent_001',
        value: '李少侠',
        confidence: 5,
      );
      final result =
          await applier.applyDeltas('s1', [delta], 3, const FactualConfig());
      expect(result.length, 1);
      expect(result.single.action, FactAction.addAlias);
      expect(result.single.newValue, '李少侠');
      expect(repo.updatedAliases['ent_001'], ['逍遥', '李少侠']);
    });

    test('别名与主名相同 → 跳过', () async {
      repo.entitiesById = {'ent_001': characterEntity()};
      const delta = FactsDelta(
        action: FactAction.addAlias,
        entityId: 'ent_001',
        value: '李逍遥',
        confidence: 5,
      );
      expect(
        (await applier.applyDeltas('s1', [delta], 3, const FactualConfig()))
            .length,
        0,
      );
    });

    test('空白别名（trim 后为空）→ 跳过且不入别名表', () async {
      repo.entitiesById = {'ent_001': characterEntity()};
      const delta = FactsDelta(
        action: FactAction.addAlias,
        entityId: 'ent_001',
        value: '   ',
        confidence: 5,
      );
      expect(
        (await applier.applyDeltas('s1', [delta], 3, const FactualConfig()))
            .length,
        0,
      );
      expect(repo.updatedAliases.containsKey('ent_001'), isFalse);
    });

    test('别名带首尾空白 → trim 后落库', () async {
      repo.entitiesById = {'ent_001': characterEntity()};
      const delta = FactsDelta(
        action: FactAction.addAlias,
        entityId: 'ent_001',
        value: '  李少侠  ',
        confidence: 5,
      );
      final result =
          await applier.applyDeltas('s1', [delta], 3, const FactualConfig());
      expect(result.length, 1);
      expect(result.single.newValue, '李少侠');
      expect(repo.updatedAliases['ent_001'], ['李少侠']);
    });

    test('超长别名（超 maxAttrValueLength）→ 拒绝', () async {
      repo.entitiesById = {'ent_001': characterEntity()};
      final delta = FactsDelta(
        action: FactAction.addAlias,
        entityId: 'ent_001',
        value: '长' * 501,
        confidence: 5,
      );
      expect(
        (await applier.applyDeltas('s1', [delta], 3, const FactualConfig()))
            .length,
        0,
      );
      expect(repo.updatedAliases.containsKey('ent_001'), isFalse);
    });

    test('别名达到数量上限后拒绝继续追加', () async {
      final aliases = List.generate(10, (i) => '别名$i');
      repo.entitiesById = {'ent_001': characterEntity(aliases: aliases)};
      const delta = FactsDelta(
        action: FactAction.addAlias,
        entityId: 'ent_001',
        value: '第十一条',
        confidence: 5,
      );
      expect(
        (await applier.applyDeltas('s1', [delta], 3, const FactualConfig()))
            .length,
        0,
      );
      expect(repo.updatedAliases.containsKey('ent_001'), isFalse);
    });
  });

  group('archive_entity', () {
    test('正常归档', () async {
      repo.entitiesById = {'ent_001': characterEntity()};
      const delta = FactsDelta(
        action: FactAction.archiveEntity,
        entityId: 'ent_001',
        reason: '角色死亡',
        confidence: 5,
      );
      final result =
          await applier.applyDeltas('s1', [delta], 10, const FactualConfig());
      expect(result.length, 1);
      expect(result.single.action, FactAction.archiveEntity);
      expect(repo.archivedEntities['ent_001'], '角色死亡');
    });

    test('已归档再次归档 → 跳过', () async {
      repo.entitiesById = {
        'ent_001': characterEntity(archived: true, updatedTurn: 5),
      };
      const delta = FactsDelta(
        action: FactAction.archiveEntity,
        entityId: 'ent_001',
        reason: '再次归档',
        confidence: 5,
      );
      expect(
        (await applier.applyDeltas('s1', [delta], 10, const FactualConfig()))
            .length,
        0,
      );
    });
  });

  group('deleteFactsByTurns', () {
    test('正确委托到 repository', () async {
      await applier.deleteFactsByTurns(sessionId: 's1', fromTurn: 5);
      expect(repo.deletedFactsByTurnsCalls, hasLength(1));
      expect(repo.deletedFactsByTurnsCalls.first.sessionId, 's1');
      expect(repo.deletedFactsByTurnsCalls.first.fromTurn, 5);
    });

    test('多次调用均被记录', () async {
      await applier.deleteFactsByTurns(sessionId: 's1', fromTurn: 3);
      await applier.deleteFactsByTurns(sessionId: 's2', fromTurn: 7);
      expect(repo.deletedFactsByTurnsCalls, hasLength(2));
      expect(repo.deletedFactsByTurnsCalls[0].fromTurn, 3);
      expect(repo.deletedFactsByTurnsCalls[1].sessionId, 's2');
    });
  });

  group('normalizeAttrKey 模型适配兼容（DOC-11 §7.4.2 修订，2026-07-26）', () {
    // 本组测试覆盖：某些模型（如 agnes-2.0-flash）不严格遵守 schema 白名单，
    // 使用 description 等非标准字段描述角色/NPC。FactApplier 应自动将其
    // 映射到标准字段（character/npc → background，pet → personality）。

    test('NPC 的 background 属性可正常写入（schema 白名单已包含）', () async {
      repo.entitiesById = {'ent_n1': npcEntity()};
      const delta = FactsDelta(
        action: FactAction.updateAttr,
        entityId: 'ent_n1',
        attrKey: 'background',
        value: '来自北方的旅人',
        reason: '用户明确陈述 NPC 背景',
        confidence: 5,
      );
      expect(
        (await applier.applyDeltas('s1', [delta], 3, const FactualConfig()))
            .length,
        1,
      );
      // 应创建新属性（属性不存在）
      expect(repo.createdAttributes, hasLength(1));
      expect(repo.createdAttributes.first.attrKey, 'background');
      expect(repo.createdAttributes.first.value, '来自北方的旅人');
    });

    test('LLM 用 description 给 character → 自动映射到 background', () async {
      repo.entitiesById = {'ent_001': characterEntity()};
      const delta = FactsDelta(
        action: FactAction.updateAttr,
        entityId: 'ent_001',
        attrKey: 'description',
        value: '少年剑客，来自余杭镇',
        reason: 'LLM 用 description 描述角色背景',
        confidence: 5,
      );
      expect(
        (await applier.applyDeltas('s1', [delta], 3, const FactualConfig()))
            .length,
        1,
      );
      // 应映射到 background 字段
      expect(repo.createdAttributes, hasLength(1));
      expect(repo.createdAttributes.first.attrKey, 'background');
      expect(repo.createdAttributes.first.value, '少年剑客，来自余杭镇');
    });

    test('LLM 用 description 给 npc → 自动映射到 background', () async {
      repo.entitiesById = {'ent_n1': npcEntity()};
      const delta = FactsDelta(
        action: FactAction.updateAttr,
        entityId: 'ent_n1',
        attrKey: 'description',
        value: '神秘的旅法师',
        reason: 'LLM 用 description 描述 NPC 背景',
        confidence: 5,
      );
      expect(
        (await applier.applyDeltas('s1', [delta], 3, const FactualConfig()))
            .length,
        1,
      );
      expect(repo.createdAttributes, hasLength(1));
      expect(repo.createdAttributes.first.attrKey, 'background');
      expect(repo.createdAttributes.first.value, '神秘的旅法师');
    });

    test('LLM 用 description 给 pet（现为 character）-> 自动映射到 background', () async {
      repo.entitiesById = {'ent_p1': petEntity()};
      const delta = FactsDelta(
        action: FactAction.updateAttr,
        entityId: 'ent_p1',
        attrKey: 'description',
        value: '毛色金黄，活泼好动',
        reason: 'LLM 用 description 描述宠物',
        confidence: 5,
      );
      expect(
        (await applier.applyDeltas('s1', [delta], 3, const FactualConfig()))
            .length,
        1,
      );
      // pet 已合并到 character，description 映射到 background
      expect(repo.createdAttributes, hasLength(1));
      expect(repo.createdAttributes.first.attrKey, 'background');
      expect(repo.createdAttributes.first.value, '毛色金黄，活泼好动');
    });

    test('create_entity 携带 description（非标准字段）→ 自动映射并初始化属性', () async {
      // 模拟 LLM 创建 NPC 时用 description 而非 background
      const delta = FactsDelta(
        action: FactAction.createEntity,
        entityType: 'npc',
        primaryName: 'Lyra',
        attrKey: 'description',
        value: '来自南方群岛的吟游诗人',
        confidence: 5,
      );
      expect(
        (await applier.applyDeltas('s1', [delta], 1, const FactualConfig()))
            .length,
        1,
      );
      // 应创建实体
      expect(repo.createdEntities, hasLength(1));
      expect(repo.createdEntities.first.primaryName, 'Lyra');
      expect(repo.createdEntities.first.type, FactualEntityType.character);
      // 应同时创建属性，且 attrKey 被映射为 background
      expect(repo.createdAttributes, hasLength(1));
      expect(repo.createdAttributes.first.attrKey, 'background');
      expect(repo.createdAttributes.first.value, '来自南方群岛的吟游诗人');
    });

    test('LLM 用未知 attrKey（非别名）-> 仍被 schema 白名单拒绝', () async {
      // 使用 location 类型（严格白名单），character 允许自定义属性不会拒绝
      final location = FactualEntity(
        entityId: 'ent_l1',
        sessionId: 's1',
        type: FactualEntityType.location,
        primaryName: '村口',
        aliases: const [],
        importance: 2,
        createdTurn: 1,
        createdAt: t,
      );
      repo.entitiesById = {'ent_l1': location};
      const delta = FactsDelta(
        action: FactAction.updateAttr,
        entityId: 'ent_l1',
        attrKey: 'completely_unknown_field',
        value: 'x',
        reason: '未知字段',
        confidence: 5,
      );
      // 未知字段不在别名映射中，应被拒绝
      expect(
        (await applier.applyDeltas('s1', [delta], 3, const FactualConfig()))
            .length,
        0,
      );
      expect(repo.createdAttributes, isEmpty);
    });
  });

  group('只读基线语义（DOC-15 §8.1，2026-09-14 只读语义 2.0）', () {
    FactualEntity worldbookEntity() => FactualEntity(
          entityId: 'ent_w1',
          sessionId: 's1',
          type: FactualEntityType.lore,
          primaryName: '货币汇率',
          aliases: const [],
          importance: 5,
          createdTurn: 0,
          createdAt: t,
          source: FactualSource.worldbook,
          sourceRef: 'book_1',
        );

    FactualEntity cardEntity() => FactualEntity(
          entityId: 'ent_c1',
          sessionId: 's1',
          type: FactualEntityType.character,
          primaryName: '女主',
          aliases: const [],
          importance: 5,
          createdTurn: 0,
          createdAt: t,
          source: FactualSource.card,
          sourceRef: 'card_1',
        );

    FactualAttribute worldbookDescriptionBaseline({
      String value = '1 金币 = 100 银币',
    }) =>
        FactualAttribute(
          attributeId: 'attr_w_base',
          entityId: 'ent_w1',
          sessionId: 's1',
          attrKey: 'description',
          value: value,
          importance: 4,
          createdAt: t,
          source: FactualSource.worldbook,
        );

    test('worldbook 基线：update_attr 重定向到 auto 行，基线不覆盖', () async {
      repo
        ..entitiesById = {'ent_w1': worldbookEntity()}
        ..seedAttribute(worldbookDescriptionBaseline());

      const delta = FactsDelta(
        action: FactAction.updateAttr,
        entityId: 'ent_w1',
        attrKey: 'description',
        value: '战后贬值，1 金币 = 80 银币',
        reason: '剧情演变',
        confidence: 5,
      );
      final result =
          await applier.applyDeltas('s1', [delta], 3, const FactualConfig());

      expect(result.length, 1);
      // 基线未被覆盖
      final rows = repo.attributesByKey[('ent_w1', 'description')]!;
      expect(
        rows.where((a) => a.source.isReadOnly).single.value,
        '1 金币 = 100 银币',
      );
      // 新增 auto 行承载演变
      expect(repo.createdAttributes.single.source, FactualSource.auto);
      expect(repo.createdAttributes.single.value, '战后贬值，1 金币 = 80 银币');
      // history 落库
      expect(repo.histories.single.action, FactAction.updateAttr);
    });

    test('worldbook 基线：append_list 重定向（single→update_attr 语义）', () async {
      // 基线 description 为 single 类型 → append_list 重定向为 update_attr，
      // 演变值落新建 auto 行，不触碰基线
      repo
        ..entitiesById = {'ent_w1': worldbookEntity()}
        ..seedAttribute(worldbookDescriptionBaseline());

      const delta = FactsDelta(
        action: FactAction.appendList,
        entityId: 'ent_w1',
        attrKey: 'description',
        value: '战后汇率崩坏',
        confidence: 5,
      );
      final result =
          await applier.applyDeltas('s1', [delta], 3, const FactualConfig());

      expect(result.length, 1);
      expect(result.single.action, FactAction.updateAttr);
      expect(repo.createdAttributes.single.source, FactualSource.auto);
      expect(repo.createdAttributes.single.value, '战后汇率崩坏');
      expect(repo.updatedAttributes, isEmpty);
    });

    test('worldbook 实体：add_alias 追加成功', () async {
      repo.entitiesById = {'ent_w1': worldbookEntity()};
      const delta = FactsDelta(
        action: FactAction.addAlias,
        entityId: 'ent_w1',
        value: '汇率设定',
        confidence: 5,
      );
      final result =
          await applier.applyDeltas('s1', [delta], 3, const FactualConfig());

      expect(result.length, 1);
      expect(result.single.action, FactAction.addAlias);
      expect(result.single.newValue, '汇率设定');
      expect(repo.updatedAliases['ent_w1'], ['汇率设定']);
    });

    test('worldbook 实体：archive_entity 允许', () async {
      repo.entitiesById = {'ent_w1': worldbookEntity()};
      const delta = FactsDelta(
        action: FactAction.archiveEntity,
        entityId: 'ent_w1',
        reason: '设定失效',
        confidence: 5,
      );
      final result =
          await applier.applyDeltas('s1', [delta], 3, const FactualConfig());

      expect(result.length, 1);
      expect(result.single.action, FactAction.archiveEntity);
      expect(repo.archivedEntities['ent_w1'], '设定失效');
    });

    test('card 实体基线：update_attr 重定向到 auto 行，基线不覆盖', () async {
      final baseline = FactualAttribute(
        attributeId: 'attr_base',
        entityId: 'ent_c1',
        sessionId: 's1',
        attrKey: 'personality',
        value: '内向',
        importance: 4,
        createdAt: t,
        source: FactualSource.card,
      );
      repo
        ..entitiesById = {'ent_c1': cardEntity()}
        ..seedAttribute(baseline);

      const delta = FactsDelta(
        action: FactAction.updateAttr,
        entityId: 'ent_c1',
        attrKey: 'personality',
        value: '因经历变开朗',
        reason: '剧情转变',
        confidence: 5,
      );
      final result =
          await applier.applyDeltas('s1', [delta], 3, const FactualConfig());

      expect(result.length, 1);
      // 基线未被覆盖
      final rows = repo.attributesByKey[('ent_c1', 'personality')]!;
      expect(rows.where((a) => a.source.isReadOnly).single.value, '内向');
      // 新增 auto 行承载演变
      expect(repo.createdAttributes.single.source, FactualSource.auto);
      expect(repo.createdAttributes.single.value, '因经历变开朗');
    });

    test('card 实体基线：值未变（等于基线）→ 跳过，不重复建 auto 行', () async {
      final baseline = FactualAttribute(
        attributeId: 'attr_base',
        entityId: 'ent_c1',
        sessionId: 's1',
        attrKey: 'personality',
        value: '内向',
        importance: 4,
        createdAt: t,
        source: FactualSource.card,
      );
      repo
        ..entitiesById = {'ent_c1': cardEntity()}
        ..seedAttribute(baseline);

      const delta = FactsDelta(
        action: FactAction.updateAttr,
        entityId: 'ent_c1',
        attrKey: 'personality',
        value: '内向',
        reason: '无变化',
        confidence: 5,
      );
      final result =
          await applier.applyDeltas('s1', [delta], 3, const FactualConfig());
      expect(result, isEmpty);
      expect(repo.createdAttributes, isEmpty);
    });

    test('worldbook 基线：update_attr 新值==基线 → 跳过、无 auto 行', () async {
      repo
        ..entitiesById = {'ent_w1': worldbookEntity()}
        ..seedAttribute(worldbookDescriptionBaseline());

      const delta = FactsDelta(
        action: FactAction.updateAttr,
        entityId: 'ent_w1',
        attrKey: 'description',
        value: '1 金币 = 100 银币',
        reason: '无变化',
        confidence: 5,
      );
      final result =
          await applier.applyDeltas('s1', [delta], 3, const FactualConfig());

      expect(result, isEmpty);
      expect(repo.createdAttributes, isEmpty);
    });

    test('worldbook 实体：update_attr 新 attrKey（lore 放宽）→ 新建 auto 属性', () async {
      // lore 对齐 character 放宽自定义键（状态/下落/归属等）
      repo.entitiesById = {'ent_w1': worldbookEntity()};
      const delta = FactsDelta(
        action: FactAction.updateAttr,
        entityId: 'ent_w1',
        attrKey: 'status',
        value: '金本位已废除',
        reason: '剧情演变',
        confidence: 5,
      );
      final result =
          await applier.applyDeltas('s1', [delta], 3, const FactualConfig());

      expect(result.length, 1);
      expect(repo.createdAttributes.single.attrKey, 'status');
      expect(repo.createdAttributes.single.source, FactualSource.auto);
      expect(repo.createdAttributes.single.value, '金本位已废除');
    });

    test('worldbook 实体：update_attr attrKey=name → 转 add_alias，主名不变', () async {
      // 导入实体主名是种子身份标识，改名意图转别名追加
      repo.entitiesById = {'ent_w1': worldbookEntity()};
      const delta = FactsDelta(
        action: FactAction.updateAttr,
        entityId: 'ent_w1',
        attrKey: 'name',
        value: '货币制度',
        reason: '模型试图改名',
        confidence: 5,
      );
      final result =
          await applier.applyDeltas('s1', [delta], 3, const FactualConfig());

      expect(result.length, 1);
      expect(result.single.action, FactAction.addAlias);
      expect(repo.updatedAliases['ent_w1'], ['货币制度']);
      expect(repo.entitiesById['ent_w1']!.primaryName, '货币汇率');
      expect(repo.createdAttributes, isEmpty);
      expect(repo.updatedAttributes, isEmpty);
    });

    test('card 实体：update_attr attrKey=name → 同样转 add_alias', () async {
      // 行为收紧断言：card 实体改名同样被拦截转别名（与 worldbook 同口径）
      repo.entitiesById = {'ent_c1': cardEntity()};
      const delta = FactsDelta(
        action: FactAction.updateAttr,
        entityId: 'ent_c1',
        attrKey: 'name',
        value: '新名字',
        reason: '模型试图改名',
        confidence: 5,
      );
      final result =
          await applier.applyDeltas('s1', [delta], 3, const FactualConfig());

      expect(result.length, 1);
      expect(result.single.action, FactAction.addAlias);
      expect(repo.updatedAliases['ent_c1'], ['新名字']);
      expect(repo.createdAttributes, isEmpty);
      expect(repo.updatedAttributes, isEmpty);
    });

    test('worldbook 实体：create_entity 撞名带 value → 转 update_attr 落演变行', () async {
      repo
        ..entitiesById = {'ent_w1': worldbookEntity()}
        ..seedAttribute(worldbookDescriptionBaseline());

      const delta = FactsDelta(
        action: FactAction.createEntity,
        entityType: 'lore',
        primaryName: '货币汇率',
        value: '战后通胀严重',
        confidence: 5,
      );
      final result =
          await applier.applyDeltas('s1', [delta], 3, const FactualConfig());

      expect(result.length, 1);
      expect(result.single.action, FactAction.updateAttr);
      expect(repo.createdEntities, isEmpty); // 不重复建实体
      expect(repo.createdAttributes.single.source, FactualSource.auto);
      expect(repo.createdAttributes.single.attrKey, 'description');
      expect(repo.createdAttributes.single.value, '战后通胀严重');
    });

    test('worldbook 实体：create_entity 撞名不带 value → 走统一转换，无冻结丢弃', () async {
      // 撞名无 value 走 add_alias 转换；转换目标名按定义已在实体名集内，
      // 被 add_alias 查重拦下——观察结果与旧冻结行为一致，但不再有
      // 实体级早退（worldbook 与 auto/card 同路径）。
      repo.entitiesById = {'ent_w1': worldbookEntity()};
      const delta = FactsDelta(
        action: FactAction.createEntity,
        entityType: 'lore',
        primaryName: '货币汇率',
        confidence: 5,
      );
      final result =
          await applier.applyDeltas('s1', [delta], 3, const FactualConfig());

      expect(result, isEmpty);
      expect(repo.createdEntities, isEmpty);
      expect(repo.updatedAliases, isEmpty);
      expect(repo.createdAttributes, isEmpty);
    });

    test('worldbook 实体：remove_from_list 无 auto 行 → 跳过（基线保留）', () async {
      // 基线 list 行天然不可移除：无 auto 行时 remove_from_list 直接跳过
      final baselineList = FactualAttribute(
        attributeId: 'attr_w_list',
        entityId: 'ent_w1',
        sessionId: 's1',
        attrKey: 'affected_kingdoms',
        value: '["A 国", "B 国"]',
        valueType: AttributeValueType.list,
        importance: 3,
        createdAt: t,
        source: FactualSource.worldbook,
      );
      repo
        ..entitiesById = {'ent_w1': worldbookEntity()}
        ..seedAttribute(baselineList);

      const delta = FactsDelta(
        action: FactAction.removeFromList,
        entityId: 'ent_w1',
        attrKey: 'affected_kingdoms',
        value: 'A 国',
        reason: '模型试图删基线',
        confidence: 5,
      );
      final result =
          await applier.applyDeltas('s1', [delta], 3, const FactualConfig());

      expect(result, isEmpty);
      expect(repo.updatedAttributes, isEmpty); // 基线行未被触碰
    });

    test('worldbook 实体：remove_from_list 有 auto 行 → 删 auto 行值、基线保留', () async {
      final baselineList = FactualAttribute(
        attributeId: 'attr_w_list',
        entityId: 'ent_w1',
        sessionId: 's1',
        attrKey: 'affected_kingdoms',
        value: '["A 国", "B 国"]',
        valueType: AttributeValueType.list,
        importance: 3,
        createdAt: t,
        source: FactualSource.worldbook,
      );
      // auto 演变行（source 缺省即 auto）
      final autoList = FactualAttribute(
        attributeId: 'attr_w_auto',
        entityId: 'ent_w1',
        sessionId: 's1',
        attrKey: 'affected_kingdoms',
        value: '["C 国"]',
        valueType: AttributeValueType.list,
        importance: 3,
        createdAt: t,
      );
      repo
        ..entitiesById = {'ent_w1': worldbookEntity()}
        ..seedAttribute(baselineList)
        ..seedAttribute(autoList);

      const delta = FactsDelta(
        action: FactAction.removeFromList,
        entityId: 'ent_w1',
        attrKey: 'affected_kingdoms',
        value: 'C 国',
        reason: '剧情演变',
        confidence: 5,
      );
      final result =
          await applier.applyDeltas('s1', [delta], 3, const FactualConfig());

      expect(result.length, 1);
      // 只改 auto 行，基线行保留
      expect(repo.updatedAttributes['attr_w_auto'], '[]');
      expect(repo.updatedAttributes.containsKey('attr_w_list'), isFalse);
    });

    test('worldbook 实体：update_attr(description) 无基线行 → FTS 重建取 auto 行',
        () async {
      // 投影时内容为空的世界书词条：无基线 description 行，新建 auto 行成为
      // 首条 description 行，FTS 重建后取其值（rebuilder putIfAbsent 首行口径）
      repo.entitiesById = {'ent_w1': worldbookEntity()};
      repo.factualFtsEntries
          .add((entityId: 'ent_w1', primaryName: '货币汇率', description: ''));

      const delta = FactsDelta(
        action: FactAction.updateAttr,
        entityId: 'ent_w1',
        attrKey: 'description',
        value: '战后通胀严重',
        reason: '剧情演变',
        confidence: 5,
      );
      final result =
          await applier.applyDeltas('s1', [delta], 3, const FactualConfig());

      expect(result.length, 1);
      // 先删后插
      expect(repo.deletedFactualFtsEntityIds, ['ent_w1']);
      final entry = repo.factualFtsEntries.single;
      expect(entry.entityId, 'ent_w1');
      expect(entry.primaryName, '货币汇率');
      expect(entry.description, '战后通胀严重');
    });

    test('worldbook 实体：update_attr(description) 有基线行 → FTS 重建取基线（rebuilder 口径）',
        () async {
      repo
        ..entitiesById = {'ent_w1': worldbookEntity()}
        ..seedAttribute(worldbookDescriptionBaseline());
      repo.factualFtsEntries.add(
        (
          entityId: 'ent_w1',
          primaryName: '货币汇率',
          description: '1 金币 = 100 银币',
        ),
      );

      const delta = FactsDelta(
        action: FactAction.updateAttr,
        entityId: 'ent_w1',
        attrKey: 'description',
        value: '战后贬值',
        reason: '剧情演变',
        confidence: 5,
      );
      final result =
          await applier.applyDeltas('s1', [delta], 3, const FactualConfig());

      expect(result.length, 1);
      // 重建发生（先删后插），description 按首行口径仍取基线行
      expect(repo.deletedFactualFtsEntityIds, ['ent_w1']);
      expect(repo.factualFtsEntries.single.entityId, 'ent_w1');
      expect(repo.factualFtsEntries.single.description, '1 金币 = 100 银币');
    });

    test('worldbook 实体：update_attr 非 description 键 → 不触 FTS', () async {
      repo.entitiesById = {'ent_w1': worldbookEntity()};
      repo.factualFtsEntries
          .add((entityId: 'ent_w1', primaryName: '货币汇率', description: ''));

      const delta = FactsDelta(
        action: FactAction.updateAttr,
        entityId: 'ent_w1',
        attrKey: 'status',
        value: '金本位已废除',
        reason: '剧情演变',
        confidence: 5,
      );
      final result =
          await applier.applyDeltas('s1', [delta], 3, const FactualConfig());

      expect(result.length, 1);
      expect(repo.deletedFactualFtsEntityIds, isEmpty); // 无重建
      expect(repo.factualFtsEntries, hasLength(1)); // 原行未动
    });

    test('update_attr 改已有演变 description 行 → FTS 同步新值', () async {
      // 原地更新路径（既有 auto 行被改值）此前不走 FTS 同步，索引留旧值，
      // lore 触发按已改掉的文本召回。
      final evolvedRow = FactualAttribute(
        attributeId: 'attr_w_auto',
        entityId: 'ent_w1',
        sessionId: 's1',
        attrKey: 'description',
        value: '战后通胀严重',
        importance: 3,
        createdAt: t,
      );
      repo
        ..entitiesById = {'ent_w1': worldbookEntity()}
        ..seedAttribute(evolvedRow);
      repo.factualFtsEntries.add(
        (
          entityId: 'ent_w1',
          primaryName: '货币汇率',
          description: '战后通胀严重',
        ),
      );

      const delta = FactsDelta(
        action: FactAction.updateAttr,
        entityId: 'ent_w1',
        attrKey: 'description',
        value: '战后恶性通胀，金币贬值过半',
        reason: '剧情演变',
        confidence: 5,
      );
      final result =
          await applier.applyDeltas('s1', [delta], 3, const FactualConfig());

      expect(result.length, 1);
      expect(repo.deletedFactualFtsEntityIds, ['ent_w1']);
      expect(repo.factualFtsEntries.single.description, '战后恶性通胀，金币贬值过半');
    });
  });

  group('整理型写入通道（isCuration）', () {
    test('频率守卫豁免：更新配额耗尽后 curation 搬移仍可落库', () async {
      repo
        ..entitiesById = {'ent_001': characterEntity()}
        ..seedAttribute(singleAttr());
      // fake 的 countRecentUpdates 走 recentUpdateCounts 播种（不看
      // histories），直接置满配额模拟"最近 3 轮已 4 次修改"
      repo.recentUpdateCounts['ent_001'] = 4;

      // 演化型写入被频率守卫拦截
      final evolutionary = await applier.applyDeltas(
        's1',
        [
          const FactsDelta(
            action: FactAction.updateAttr,
            entityId: 'ent_001',
            attrKey: 'personality',
            value: '演化更新',
            confidence: 5,
          ),
        ],
        3,
        const FactualConfig(),
      );
      expect(evolutionary, isEmpty, reason: '配额耗尽后演化型 update_attr 应被跳过');

      // 整理型（归并搬移）豁免守卫，照常落库
      final curational = await applier.applyDeltas(
        's1',
        [
          const FactsDelta(
            action: FactAction.updateAttr,
            entityId: 'ent_001',
            attrKey: 'personality',
            value: '归并搬移值',
            confidence: 5,
            isCuration: true,
          ),
        ],
        3,
        const FactualConfig(),
      );
      expect(curational, hasLength(1));
      expect(repo.updatedAttributes.values.last, '归并搬移值');
    });

    test('置信度门豁免：关键属性低置信度 curation 搬移可落库', () async {
      repo
        ..entitiesById = {'ent_001': characterEntity()}
        ..seedAttribute(singleAttr()); // importance=4 → 关键属性

      final result = await applier.applyDeltas(
        's1',
        [
          const FactsDelta(
            action: FactAction.updateAttr,
            entityId: 'ent_001',
            attrKey: 'personality',
            value: '归并合并描述',
            confidence: 3, // 低于 modifyConfidenceThreshold(4)
            isCuration: true,
          ),
        ],
        1,
        const FactualConfig(),
      );
      expect(result, hasLength(1));
      expect(repo.updatedAttributes.values.last, '归并合并描述');
    });

    test('schema 白名单豁免：跨类型归并搬移非目标类型键可落库', () async {
      // location 实体 + character 的键（personality 不在 location 白名单）
      final location = FactualEntity(
        entityId: 'ent_loc',
        sessionId: 's1',
        type: FactualEntityType.location,
        primaryName: '边境庄园',
        aliases: const [],
        importance: 3,
        createdTurn: 1,
        createdAt: t,
      );
      repo.entitiesById = {'ent_loc': location};

      final curational = await applier.applyDeltas(
        's1',
        [
          const FactsDelta(
            action: FactAction.updateAttr,
            entityId: 'ent_loc',
            attrKey: 'personality',
            value: '从角色实体搬来的描述',
            confidence: 4,
            isCuration: true,
          ),
        ],
        2,
        const FactualConfig(),
      );
      expect(curational, hasLength(1), reason: 'curation 搬移豁免白名单，键来自源实体既有行');

      // 对照：演化型写入同键仍被白名单拦截
      final evolutionary = await applier.applyDeltas(
        's1',
        [
          const FactsDelta(
            action: FactAction.updateAttr,
            entityId: 'ent_loc',
            attrKey: 'personality',
            value: '演化写入',
            confidence: 5,
          ),
        ],
        2,
        const FactualConfig(),
      );
      expect(evolutionary, isEmpty);
    });
  });

  group('set_importance 与 skipFrequencyGuard', () {
    test('FactsDelta JSON 往返兼容 set_importance 与 skipFrequencyGuard', () {
      const delta = FactsDelta(
        action: FactAction.setImportance,
        entityId: 'ent_001',
        importance: 5,
        reason: '成为关键队友',
        confidence: 4,
        skipFrequencyGuard: true,
      );
      final encoded = delta.toJson();
      expect(encoded['action'], 'set_importance');
      expect(encoded['skipFrequencyGuard'], isTrue);

      final decoded = FactsDelta.fromJson(encoded);
      expect(decoded.action, FactAction.setImportance);
      expect(decoded.importance, 5);
      expect(decoded.skipFrequencyGuard, isTrue);

      final defaultDelta = FactsDelta.fromJson(const {
        'action': 'update_attr',
        'confidence': 4,
      });
      expect(defaultDelta.skipFrequencyGuard, isFalse);
      expect(defaultDelta.toJson().containsKey('skipFrequencyGuard'), isFalse);
    });

    test('set_importance 同时放行 auto 与 worldbook/card 导入实体并写审计', () async {
      final cardEntity = FactualEntity(
        entityId: 'ent_card',
        sessionId: 's1',
        type: FactualEntityType.character,
        primaryName: '苏婉',
        aliases: const [],
        importance: 2,
        createdTurn: 0,
        createdAt: t,
        source: FactualSource.card,
      );
      repo.entitiesById = {
        'ent_001': characterEntity(),
        'ent_card': cardEntity,
      };

      final result = await applier.applyDeltasWithResult(
        's1',
        const [
          FactsDelta(
            action: FactAction.setImportance,
            entityId: 'ent_001',
            importance: 3,
            reason: '阶段退场',
            confidence: 4,
          ),
          FactsDelta(
            action: FactAction.setImportance,
            entityId: 'ent_card',
            importance: 5,
            reason: '晋升核心同伴',
            confidence: 5,
          ),
        ],
        8,
        const FactualConfig(),
      );

      expect(result.factWriteFailureCount, 0);
      expect(result.factsChanges, hasLength(2));
      expect(result.factsChanges[0].action, FactAction.setImportance);
      expect(result.factsChanges[0].oldValue, '5');
      expect(result.factsChanges[0].newValue, '3');
      expect(result.factsChanges[1].entityId, 'ent_card');
      expect(result.factsChanges[1].oldValue, '2');
      expect(result.factsChanges[1].newValue, '5');

      expect(repo.entitiesById['ent_001']!.importance, 3);
      expect(repo.entitiesById['ent_001']!.updatedTurn, 8);
      expect(repo.entitiesById['ent_card']!.importance, 5);
      expect(repo.entitiesById['ent_card']!.primaryName, '苏婉');
      expect(repo.histories, hasLength(2));
      expect(repo.histories[1].action, FactAction.setImportance);
      expect(repo.histories[1].oldValue, '2');
      expect(repo.histories[1].newValue, '5');
    });

    test('set_importance 同值或越界被跳过', () async {
      repo.entitiesById = {'ent_001': characterEntity(importance: 3)};
      final result = await applier.applyDeltasWithResult(
        's1',
        const [
          FactsDelta(
            action: FactAction.setImportance,
            entityId: 'ent_001',
            importance: 3,
            confidence: 5,
          ),
          FactsDelta(
            action: FactAction.setImportance,
            entityId: 'ent_001',
            importance: 7,
            confidence: 5,
          ),
        ],
        4,
        const FactualConfig(),
      );
      expect(result.factsChanges, isEmpty);
      expect(repo.histories, isEmpty);
      expect(repo.entitiesById['ent_001']!.importance, 3);
    });

    test('skipFrequencyGuard 绕过 3 轮频控但不绕过非角色/设定实体的白名单', () async {
      final location = FactualEntity(
        entityId: 'ent_loc',
        sessionId: 's1',
        type: FactualEntityType.location,
        primaryName: '边境庄园',
        aliases: const [],
        importance: 3,
        createdTurn: 1,
        createdAt: t,
      );
      repo
        ..entitiesById = {
          'ent_001': characterEntity(),
          'ent_loc': location,
        }
        ..seedAttribute(singleAttr())
        ..recentUpdateCounts['ent_001'] = 4
        ..recentUpdateCounts['ent_loc'] = 4;

      final result = await applier.applyDeltasWithResult(
        's1',
        const [
          FactsDelta(
            action: FactAction.updateAttr,
            entityId: 'ent_001',
            attrKey: 'personality',
            value: '沉稳老练',
            confidence: 5,
            skipFrequencyGuard: true,
          ),
          FactsDelta(
            action: FactAction.updateAttr,
            entityId: 'ent_loc',
            attrKey: 'personality',
            value: '非白名单键',
            confidence: 5,
            skipFrequencyGuard: true,
          ),
        ],
        10,
        const FactualConfig(),
      );

      expect(result.factsChanges, hasLength(1));
      expect(result.factsChanges.single.entityId, 'ent_001');
      expect(result.factsChanges.single.newValue, '沉稳老练');
    });
  });
}
