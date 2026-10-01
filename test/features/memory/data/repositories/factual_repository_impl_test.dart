import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/memory/data/repositories/factual_repository_impl.dart';
import 'package:lmstory/features/memory/domain/entities/facts_delta.dart';
import 'package:lmstory/features/memory/domain/entities/factual_attribute.dart';
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
import 'package:lmstory/features/memory/domain/entities/factual_source.dart';
import 'package:lmstory/features/memory/domain/entities/force_inject_target.dart';
import 'package:lmstory/features/memory/domain/services/fact_applier.dart';

/// FactualRepositoryImpl 数据层集成测试（真实 drift 内存库）
///
/// 覆盖 deleteFactsByTurns 对「角色卡基线 + 单次 delta」的回滚（DOC-15 §8.2，
/// 审查 #1：delta 行历史须回填真实 attributeId 才能被 _rollbackSurvivingEntities 回滚）。
void main() {
  late AppDatabase db;
  late FactualRepositoryImpl repo;
  late FactApplier applier;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = FactualRepositoryImpl(database: db);
    applier = FactApplier(repository: repo);
  });

  tearDown(() async {
    await db.close();
  });

  test('B8-3：getKeyEntities includeForceInject 让低重要度常驻实体入选', () async {
    // 低重要度 + forceInject=world（世界书 constant 投影形态）
    await repo.createEntity(
      FactualEntity(
        entityId: 'ent_w1',
        sessionId: 's-fi',
        type: FactualEntityType.lore,
        primaryName: '常驻设定',
        aliases: const [],
        importance: 2,
        forceInject: ForceInjectTarget.world,
        createdTurn: 0,
        createdAt: DateTime.now(),
        source: FactualSource.worldbook,
      ),
    );
    // 低重要度、无常驻标记（不应入选）
    await repo.createEntity(
      FactualEntity(
        entityId: 'ent_p1',
        sessionId: 's-fi',
        type: FactualEntityType.lore,
        primaryName: '普通背景',
        aliases: const [],
        importance: 2,
        createdTurn: 0,
        createdAt: DateTime.now(),
        source: FactualSource.worldbook,
      ),
    );

    // 旧口径（默认）：只看重要度 → 两者皆不入选
    expect(await repo.getKeyEntities('s-fi', 5), isEmpty);
    // coreBlocks 口径 → 常驻实体破格入选
    final entities =
        await repo.getKeyEntities('s-fi', 5, includeForceInject: true);
    expect(entities.map((e) => e.primaryName), ['常驻设定']);
  });

  test('ST7-1 = WA7-1：excludeInjectionDisabled 在查询层剔除停用词条（三取数路径）', () async {
    final now = DateTime.now();
    Future<void> seedEntity(
      String id,
      String name, {
      int importance = 5,
      bool injectionDisabled = false,
      List<String> aliases = const [],
      FactualEntityType type = FactualEntityType.character,
    }) =>
        repo.createEntity(
          FactualEntity(
            entityId: id,
            sessionId: 's7',
            type: type,
            primaryName: name,
            aliases: aliases,
            importance: importance,
            createdTurn: 0,
            createdAt: now,
            injectionDisabled: injectionDisabled,
          ),
        );

    await seedEntity(
      'ent_off',
      '停用主角',
      injectionDisabled: true,
      aliases: const ['凑酱'],
    );
    await seedEntity('ent_on', '活跃主角');
    // 低重要度停用世界书词条（仅 FTS description 可召回）
    await seedEntity(
      'ent_lore',
      '隐秘仪式',
      importance: 2,
      injectionDisabled: true,
      type: FactualEntityType.lore,
    );
    await repo.insertFactualFts(
      entityId: 'ent_lore',
      sessionId: 's7',
      primaryName: '隐秘仪式',
      aliases: const [],
      description: '禁忌仪式的细节',
    );

    // getKeyEntities：默认口径含停用关键实体；注入面口径剔除
    expect(
      (await repo.getKeyEntities('s7', 5)).map((e) => e.entityId),
      containsAll(['ent_off', 'ent_on']),
    );
    expect(
      (await repo.getKeyEntities('s7', 5, excludeInjectionDisabled: true))
          .map((e) => e.entityId),
      ['ent_on'],
    );

    // findByName：主名与别名命中默认都返回；注入面口径剔除（含别名派生）
    expect(
      (await repo.findByName('s7', ['停用主角'])).map((e) => e.entityId),
      ['ent_off'],
    );
    expect(
      (await repo.findByName('s7', ['凑酱'])).map((e) => e.entityId),
      ['ent_off'],
      reason: '默认口径：别名命中照常返回（检索/写入面不受影响）',
    );
    expect(
      await repo.findByName(
        's7',
        ['停用主角', '凑酱'],
        excludeInjectionDisabled: true,
      ),
      isEmpty,
      reason: '注入面：主名与别名命中均剔除',
    );
    expect(
      (await repo.findByName(
        's7',
        ['活跃主角'],
        excludeInjectionDisabled: true,
      ))
          .map((e) => e.entityId),
      ['ent_on'],
      reason: '正常词条不受影响',
    );

    // searchWorldFacts：FTS 命中默认返回；注入面口径剔除
    expect(
      (await repo.searchWorldFacts('s7', ['禁忌'])).map((e) => e.entityId),
      ['ent_lore'],
    );
    expect(
      await repo.searchWorldFacts(
        's7',
        ['禁忌'],
        excludeInjectionDisabled: true,
      ),
      isEmpty,
    );
  });

  test('DK8-3：getKeyEntities 组合口径——includeForceInject 破格不豁免停用词条', () async {
    final now = DateTime.now();
    Future<void> seedResident(
      String id,
      String name, {
      required bool injectionDisabled,
    }) =>
        repo.createEntity(
          FactualEntity(
            entityId: id,
            sessionId: 's8',
            type: FactualEntityType.lore,
            primaryName: name,
            aliases: const [],
            importance: 2,
            forceInject: ForceInjectTarget.world,
            createdTurn: 0,
            createdAt: now,
            injectionDisabled: injectionDisabled,
            source: FactualSource.worldbook,
          ),
        );

    await seedResident('ent_off_w', '停用的常驻设定', injectionDisabled: true);
    await seedResident('ent_on_w', '活跃的常驻设定', injectionDisabled: false);

    // 组合口径（导演 coreBlocks 实际取数形态）：破格入选只给
    // 未停用的常驻词条——停用词条不进任何注入桶
    expect(
      (await repo.getKeyEntities(
        's8',
        5,
        includeForceInject: true,
        excludeInjectionDisabled: true,
      ))
          .map((e) => e.entityId),
      ['ent_on_w'],
    );
    // 仅 includeForceInject（修复前 runner 的取数形态）：停用常驻
    // 词条仍被带出——即缺陷面
    expect(
      (await repo.getKeyEntities('s8', 5, includeForceInject: true))
          .map((e) => e.entityId),
      containsAll(['ent_off_w', 'ent_on_w']),
    );
  });

  test('deleteFactsByTurns 回滚卡基线单次 delta，不误删基线', () async {
    final now = DateTime.now();

    // 投影卡实体（source=card，createdTurn=0）+ 只读基线 personality
    await repo.createEntity(
      FactualEntity(
        entityId: 'ent_c1',
        sessionId: 's1',
        type: FactualEntityType.character,
        primaryName: '女主',
        aliases: const [],
        importance: 5,
        createdTurn: 0,
        createdAt: now,
        source: FactualSource.card,
        sourceRef: 'card_1',
      ),
    );
    await repo.createAttribute(
      FactualAttribute(
        attributeId: 'attr_base',
        entityId: 'ent_c1',
        sessionId: 's1',
        attrKey: 'personality',
        value: '内向',
        importance: 4,
        createdAt: now,
        source: FactualSource.card,
      ),
    );

    // 演化：第 3 轮 update_attr(personality=开朗) → 重定向创建 auto delta 行
    const delta = FactsDelta(
      action: FactAction.updateAttr,
      entityId: 'ent_c1',
      attrKey: 'personality',
      value: '开朗',
      reason: '剧情转变',
      confidence: 5,
    );
    await applier.applyDeltas('s1', [delta], 3, const FactualConfig());

    // 演化后：基线 + delta 两行
    final before = await repo.getAttributesByKey('ent_c1', 'personality');
    expect(before, hasLength(2));

    // 覆盖式重写：从第 3 轮起重写 → 应回滚 delta，保留基线
    await applier.deleteFactsByTurns(sessionId: 's1', fromTurn: 3);

    final after = await repo.getAttributesByKey('ent_c1', 'personality');
    expect(after, hasLength(1));
    expect(after.single.source, FactualSource.card);
    expect(after.single.value, '内向');
  });

  group('forceInject 迁移回填（v37）', () {
    test('回填：worldbook 且 importance=5 → forceInject=world + importance=2',
        () async {
      final now = DateTime.now();
      // 模拟 v36 遗留数据：worldbook constant 词条（importance=5）
      await repo.createEntity(
        FactualEntity(
          entityId: 'ent_w1',
          sessionId: 's1',
          type: FactualEntityType.lore,
          primaryName: '货币汇率',
          aliases: const [],
          importance: 5,
          createdTurn: 0,
          createdAt: now,
          source: FactualSource.worldbook,
          sourceRef: 'book_1',
        ),
      );
      // 直接触发 v37 回填（幂等）
      await db.migrateForceInjectForTest();
      final migrated = await repo.getEntityById('ent_w1');
      expect(migrated!.forceInject, ForceInjectTarget.world);
      expect(migrated.importance, 2);
    });
  });

  group('forceInject 读写', () {
    test('updateEntityForceInject 只改 forceInject，豁免只读守卫', () async {
      final now = DateTime.now();
      await repo.createEntity(
        FactualEntity(
          entityId: 'ent_w1',
          sessionId: 's1',
          type: FactualEntityType.lore,
          primaryName: '货币汇率',
          aliases: const [],
          importance: 2,
          createdTurn: 0,
          createdAt: now,
          source: FactualSource.worldbook,
          sourceRef: 'book_1',
        ),
      );
      // worldbook 是只读实体，但强制注入开关应可改（纯检索偏好）
      await repo.updateEntityForceInject('ent_w1', ForceInjectTarget.directive);
      final e = await repo.getEntityById('ent_w1');
      expect(e!.forceInject, ForceInjectTarget.directive);
      expect(e.importance, 2); // 内容字段不被触碰
    });

    test('batchUpdateForceInject 批量生效', () async {
      final now = DateTime.now();
      await repo.createEntity(
        FactualEntity(
          entityId: 'ent_1',
          sessionId: 's1',
          type: FactualEntityType.lore,
          primaryName: 'A',
          aliases: const [],
          importance: 2,
          createdTurn: 0,
          createdAt: now,
        ),
      );
      await repo.createEntity(
        FactualEntity(
          entityId: 'ent_2',
          sessionId: 's1',
          type: FactualEntityType.lore,
          primaryName: 'B',
          aliases: const [],
          importance: 2,
          createdTurn: 0,
          createdAt: now,
        ),
      );
      await repo.batchUpdateForceInject(
        const ['ent_1', 'ent_2'],
        ForceInjectTarget.world,
      );
      expect(
        (await repo.getEntityById('ent_1'))!.forceInject,
        ForceInjectTarget.world,
      );
      expect(
        (await repo.getEntityById('ent_2'))!.forceInject,
        ForceInjectTarget.world,
      );
    });
  });

  // F2 修复：中文短触发词（<3 字符）trigram 无法召回，
  // 短词改走 LIKE 子串匹配，长词照旧 FTS，两路合并去重。
  group('searchWorldFacts 短词 LIKE 兜底（F2）', () {
    test('单字触发词命中名称/别名/描述含该字的词条', () async {
      final now = DateTime.now();
      // 名称含"剑"的实体 + FTS 行
      await repo.createEntity(
        FactualEntity(
          entityId: 'ent_sword',
          sessionId: 'sF2',
          type: FactualEntityType.lore,
          primaryName: '剑冢',
          aliases: const ['古剑埋葬地'],
          importance: 4,
          createdTurn: 0,
          createdAt: now,
          source: FactualSource.worldbook,
          sourceRef: 'wb_1',
        ),
      );
      await repo.insertFactualFts(
        entityId: 'ent_sword',
        sessionId: 'sF2',
        primaryName: '剑冢',
        aliases: const ['古剑埋葬地'],
        description: '历代战剑封存之地，剑气终年不散。',
      );
      // 干扰项：不含触发词
      await repo.createEntity(
        FactualEntity(
          entityId: 'ent_other',
          sessionId: 'sF2',
          type: FactualEntityType.lore,
          primaryName: '海图',
          aliases: const [],
          importance: 2,
          createdTurn: 0,
          createdAt: now,
        ),
      );
      await repo.insertFactualFts(
        entityId: 'ent_other',
        sessionId: 'sF2',
        primaryName: '海图',
        aliases: const [],
        description: '通往新大陆的航线记录。',
      );

      // 单字"剑"：trigram 不可用 → LIKE 应命中剑冢（名称与描述两处）
      final hits = await repo.searchWorldFacts('sF2', const ['剑']);
      expect(hits.map((e) => e.entityId), contains('ent_sword'));
      expect(hits.map((e) => e.entityId), isNot(contains('ent_other')));

      // 双字词"精灵"命中别名/描述；三字以上走 FTS 照旧
      final long = await repo.searchWorldFacts('sF2', const ['埋葬地']);
      expect(long.map((e) => e.entityId), contains('ent_sword'));

      // 短词含 LIKE 通配符时不误当通配符（"%"按字面匹配 → 无命中）
      final wildcard = await repo.searchWorldFacts('sF2', const ['%']);
      expect(wildcard, isEmpty);
    });

    test('混合长短词两路合并去重', () async {
      final now = DateTime.now();
      await repo.createEntity(
        FactualEntity(
          entityId: 'ent_m',
          sessionId: 'sF3',
          type: FactualEntityType.item,
          primaryName: '龙鳞剑',
          aliases: const [],
          importance: 3,
          createdTurn: 0,
          createdAt: now,
        ),
      );
      await repo.insertFactualFts(
        entityId: 'ent_m',
        sessionId: 'sF3',
        primaryName: '龙鳞剑',
        aliases: const [],
        description: '以龙鳞锻造的剑。',
      );

      // "剑"（LIKE 路）与"龙鳞剑"（FTS 路）命中同一实体 → 去重后仅一条
      final hits = await repo.searchWorldFacts('sF3', const ['剑', '龙鳞剑']);
      expect(hits.where((e) => e.entityId == 'ent_m').length, 1);
    });
  });

  group('deleteFactsByTurns 回滚 append_list', () {
    // 注意避开语义去重（编辑距离 <= 2 即拦截）：测试值两两差异须足够大
    const turns = {1: '御剑飞行术', 2: '炼丹之术', 3: '奇门遁甲阵法'};

    FactsDelta appendDelta(String item) => FactsDelta(
          action: FactAction.appendList,
          entityId: 'ent_a1',
          attrKey: 'skills',
          value: item,
          confidence: 4,
        );

    test('回滚后列表恢复为全量 JSON 而非裸字符串', () async {
      final now = DateTime.now();
      await repo.createEntity(
        FactualEntity(
          entityId: 'ent_a1',
          sessionId: 'sR',
          type: FactualEntityType.character,
          primaryName: '主角',
          aliases: const [],
          importance: 3,
          createdTurn: 1,
          createdAt: now,
        ),
      );

      // 轮 1/2/3 各追加一项（审计行 newValue 只存单项）
      for (final turn in turns.keys) {
        await repo.runInTransaction(
          () async => applier.applyDeltas(
            'sR',
            [appendDelta(turns[turn]!)],
            turn,
            const FactualConfig(),
          ),
        );
      }

      // 回滚轮 3：skills 应恢复为轮 2 后的全量
      await repo.runInTransaction(
        () async => repo.deleteFactsByTurns(sessionId: 'sR', fromTurn: 3),
      );

      final attrs = await repo.getAttributes('sR', ['ent_a1']);
      final skills = attrs.singleWhere((a) => a.attrKey == 'skills');
      expect(
        skills.listValue,
        ['御剑飞行术', '炼丹之术'],
        reason: '修复前恢复值取审计行 newValue（单项），列表被写坏成裸字符串、listValue 退化为空表',
      );
    });

    test('连续回滚多轮：列表逐轮恢复，归并大量 append 后重生成不丢内容', () async {
      final now = DateTime.now();
      await repo.createEntity(
        FactualEntity(
          entityId: 'ent_a1',
          sessionId: 'sR2',
          type: FactualEntityType.character,
          primaryName: '主角',
          aliases: const [],
          importance: 3,
          createdTurn: 1,
          createdAt: now,
        ),
      );
      for (final turn in turns.keys) {
        await repo.runInTransaction(
          () async => applier.applyDeltas(
            'sR2',
            [appendDelta(turns[turn]!)],
            turn,
            const FactualConfig(),
          ),
        );
      }

      // 回滚轮 2+3（归并重生成场景）
      await repo.runInTransaction(
        () async => repo.deleteFactsByTurns(sessionId: 'sR2', fromTurn: 2),
      );

      final attrs = await repo.getAttributes('sR2', ['ent_a1']);
      final skills = attrs.singleWhere((a) => a.attrKey == 'skills');
      expect(skills.listValue, ['御剑飞行术']);
    });
  });

  group('演变 description 行的 factual_fts 同步', () {
    Future<void> seedWorldbook(String sessionId) async {
      await repo.createEntity(
        FactualEntity(
          entityId: 'ent_w_$sessionId',
          sessionId: sessionId,
          type: FactualEntityType.lore,
          primaryName: '边境庄园',
          aliases: const [],
          importance: 5,
          createdTurn: 0,
          createdAt: DateTime.now(),
          source: FactualSource.worldbook,
          sourceRef: 'book_1',
        ),
      );
    }

    test('基线+演变并存时两者都可召回（全行进索引）', () async {
      await seedWorldbook('sFTS3');

      // 基线行（worldbook 投影）
      await repo.createAttribute(
        FactualAttribute(
          attributeId: 'attr_w_base_sFTS3',
          entityId: 'ent_w_sFTS3',
          sessionId: 'sFTS3',
          attrKey: 'description',
          value: '和平年代汇率稳定，金币坚挺',
          importance: 4,
          createdAt: DateTime.now(),
          source: FactualSource.worldbook,
        ),
      );

      // 演变行（auto）与基线并存
      await repo.runInTransaction(
        () async => applier.applyDeltas(
          'sFTS3',
          [
            const FactsDelta(
              action: FactAction.updateAttr,
              entityId: 'ent_w_sFTS3',
              attrKey: 'description',
              value: '战后汇率崩坏，金币贬值',
              reason: '剧情演变',
              confidence: 5,
            ),
          ],
          3,
          const FactualConfig(),
        ),
      );

      // 基线词（旧文本）与演变词（新文本）都命中——修复前只取首行
      //（基线），演变值检索不到
      expect(
        (await repo.searchWorldFacts('sFTS3', ['坚挺'])).map((e) => e.entityId),
        ['ent_w_sFTS3'],
        reason: '基线文本保持可召回',
      );
      expect(
        (await repo.searchWorldFacts('sFTS3', ['崩坏'])).map((e) => e.entityId),
        ['ent_w_sFTS3'],
        reason: '演变文本也应召回（MM12-2 拍板：新旧都进索引）',
      );
    });

    test('演变 description 行原地更新后 FTS 跟随新值（旧值不再召回）', () async {
      await seedWorldbook('sFTS1');

      // 轮 3 建演变行（无基线，投影内容为空的词条），轮 4 原地改值
      await repo.runInTransaction(
        () async => applier.applyDeltas(
          'sFTS1',
          [
            const FactsDelta(
              action: FactAction.updateAttr,
              entityId: 'ent_w_sFTS1',
              attrKey: 'description',
              value: '庄园地下室藏有青铜镜',
              reason: '剧情演变',
              confidence: 5,
            ),
          ],
          3,
          const FactualConfig(),
        ),
      );
      await repo.runInTransaction(
        () async => applier.applyDeltas(
          'sFTS1',
          [
            const FactsDelta(
              action: FactAction.updateAttr,
              entityId: 'ent_w_sFTS1',
              attrKey: 'description',
              value: '庄园花园埋着星图残片',
              reason: '剧情演变',
              confidence: 5,
            ),
          ],
          4,
          const FactualConfig(),
        ),
      );

      expect(
        (await repo.searchWorldFacts('sFTS1', ['星图'])).map((e) => e.entityId),
        ['ent_w_sFTS1'],
        reason: 'FTS 必须跟随新值（修复前留旧值，lore 触发按已改掉文本召回）',
      );
      expect(
        await repo.searchWorldFacts('sFTS1', ['青铜镜']),
        isEmpty,
        reason: '旧值不再召回',
      );
    });

    test('重生成回滚删除演变 description 行后 FTS 无幽灵召回', () async {
      await seedWorldbook('sFTS2');

      // 轮 3 建演变行（投影空内容词条）
      await repo.runInTransaction(
        () async => applier.applyDeltas(
          'sFTS2',
          [
            const FactsDelta(
              action: FactAction.updateAttr,
              entityId: 'ent_w_sFTS2',
              attrKey: 'description',
              value: '地下室藏有青铜镜',
              reason: '剧情演变',
              confidence: 5,
            ),
          ],
          3,
          const FactualConfig(),
        ),
      );
      expect(
        (await repo.searchWorldFacts('sFTS2', ['青铜镜'])).map((e) => e.entityId),
        ['ent_w_sFTS2'],
      );

      // 重生成回滚轮 3：演变行被删，FTS 行必须随之消失
      await repo.runInTransaction(
        () async => repo.deleteFactsByTurns(sessionId: 'sFTS2', fromTurn: 3),
      );

      expect(
        await repo.searchWorldFacts('sFTS2', ['青铜镜']),
        isEmpty,
        reason: '修复前 FTS 残留已删文本（幽灵召回），实体未归档仍注入世界设定',
      );
    });
  });
}
