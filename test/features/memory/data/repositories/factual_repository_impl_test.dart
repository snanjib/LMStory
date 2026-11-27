import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/memory/data/repositories/factual_repository_impl.dart';
import 'package:lmstory/features/memory/domain/entities/facts_delta.dart';
import 'package:lmstory/features/memory/domain/entities/factual_attribute.dart';
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
import 'package:lmstory/features/memory/domain/entities/factual_memory_history.dart';
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

  test('= excludeInjectionDisabled 在查询层剔除停用词条（三取数路径）', () async {
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

  test('getKeyEntities 组合口径——includeForceInject 破格不豁免停用词条', () async {
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

  // 检索顺序/数量/过滤收口：此前 FTS/LIKE 两通道各取 limit 条、Set
  // 并集丢 rank 序、回表无 ORDER BY，归档/停用候选白白占用 limit 名额。
  group('searchWorldFacts 检索顺序与数量上限', () {
    Future<void> seedEntry(
      String entityId,
      String name,
      String description, {
      required String sessionId,
      int importance = 3,
      bool isArchived = false,
      bool injectionDisabled = false,
    }) async {
      await repo.createEntity(
        FactualEntity(
          entityId: entityId,
          sessionId: sessionId,
          type: FactualEntityType.lore,
          primaryName: name,
          aliases: const [],
          importance: importance,
          createdTurn: 0,
          createdAt: DateTime.now(),
          isArchived: isArchived,
          injectionDisabled: injectionDisabled,
          source: FactualSource.worldbook,
        ),
      );
      await repo.insertFactualFts(
        entityId: entityId,
        sessionId: sessionId,
        primaryName: name,
        aliases: const [],
        description: description,
      );
    }

    test('FTS 命中按 rank 相关度降序返回（回表不得丢序）', () async {
      // rank 较差者先插入且主键字典序更小——修复前回表查询无
      // ORDER BY，按表序返回，rank 序丢失
      await seedEntry(
        'aa_worse',
        '废铁铺',
        '角落里埋着一柄星陨剑。',
        sessionId: 'sRank',
      );
      await seedEntry(
        'zz_best',
        '星陨剑',
        '星陨剑剑鸣如龙，星陨剑饮血，星陨剑诛邪，星陨剑出，群星坠落。',
        sessionId: 'sRank',
      );

      final hits = await repo.searchWorldFacts('sRank', const ['星陨剑']);
      expect(
        hits.map((e) => e.entityId).toList(),
        ['zz_best', 'aa_worse'],
        reason: '命中多条时必须按 FTS rank 相关度排序，而非表存储序',
      );
    });

    test('长短词混合 limit=1 恰好返回一条（FTS 命中在前）', () async {
      // ent_fts 仅命中长词（FTS 路），ent_like 仅命中短词（LIKE 路），
      // 两通道互不重叠
      await seedEntry(
        'ent_fts',
        '龙脊山脉',
        '绵延千里的巍峨山脉。',
        sessionId: 'sMix',
      );
      await seedEntry(
        'ent_like',
        '古剑',
        '一柄锈蚀的古剑。',
        sessionId: 'sMix',
      );

      final hits = await repo.searchWorldFacts(
        'sMix',
        const ['龙脊山脉', '剑'],
        limit: 1,
      );
      expect(
        hits,
        hasLength(1),
        reason: '修复前两通道各取 limit 条再合并，limit=1 可能返回 2 条',
      );
      expect(
        hits.single.entityId,
        'ent_fts',
        reason: 'FTS rank 序候选在前，截断时优先保留',
      );
    });

    test('rank 最优项归档后 limit=1 沿候选序补足后续合法项', () async {
      // rank 最优者已归档：修复前 FTS 通道 LIMIT 1 只取到归档候选，
      // 回表过滤后返回空，尽管库中有合格后续候选
      await seedEntry(
        'ent_top',
        '星陨剑',
        '星陨剑剑鸣如龙，星陨剑饮血，星陨剑诛邪，星陨剑出，群星坠落。',
        sessionId: 'sArch',
        isArchived: true,
      );
      await seedEntry(
        'ent_next',
        '星陨剑谱',
        '记载锻造之法。',
        sessionId: 'sArch',
      );

      final hits = await repo.searchWorldFacts(
        'sArch',
        const ['星陨剑'],
        limit: 1,
      );
      expect(
        hits.map((e) => e.entityId).toList(),
        ['ent_next'],
        reason: '归档候选不占 limit 名额，应沿候选序补足后续合法项',
      );
    });

    test('短词 LIKE 命中按（importance DESC, primary_name ASC）稳定序', () async {
      // 低分者先插入且主键字典序更小——修复前 LIKE 通道与回表均无排序，
      // 按表序/主键序返回
      await seedEntry(
        'aa_lo',
        '玄铁剑',
        '沉重的玄铁剑。',
        sessionId: 'sLike',
        importance: 2,
      );
      await seedEntry(
        'zz_hi',
        '赤霄剑',
        '轻灵的赤霄剑。',
        sessionId: 'sLike',
        importance: 5,
      );

      final hits = await repo.searchWorldFacts('sLike', const ['剑']);
      expect(
        hits.map((e) => e.entityId).toList(),
        ['zz_hi', 'aa_lo'],
        reason: '短词无相关性分数，按重要度降序稳定排列，不按表序',
      );
    });
  });

  test('删轮按同一属性最早流水恢复旧值，保留手动删除', () async {
    const sessionId = 's-rollback-attributes';
    const config = FactualConfig(maxUpdatesPer3Turns: 20);
    Future<void> apply(int turn, List<FactsDelta> changes) async {
      final applied =
          await applier.applyDeltas(sessionId, changes, turn, config);
      expect(applied, hasLength(changes.length));
    }

    await apply(1, [
      for (final name in ['retained entity', 'manually edited entity'])
        FactsDelta(
          action: FactAction.createEntity,
          confidence: 5,
          primaryName: name,
          entityType: 'character',
          attrKey: 'background',
          value: 'early background',
        ),
    ]);
    final retained =
        (await repo.findByName(sessionId, ['retained entity'])).single;
    final edited =
        (await repo.findByName(sessionId, ['manually edited entity'])).single;
    final original =
        (await repo.getAttributes(sessionId, [retained.entityId])).single;
    final manuallyRemoved =
        (await repo.getAttributes(sessionId, [edited.entityId])).single;

    FactsDelta updateBackground(String entityId, String value) => FactsDelta(
          action: FactAction.updateAttr,
          confidence: 5,
          entityId: entityId,
          attrKey: 'background',
          value: value,
          reason: 'synthetic story change',
        );
    FactsDelta appendSkill(String value) => FactsDelta(
          action: FactAction.appendList,
          confidence: 5,
          entityId: retained.entityId,
          attrKey: 'skills',
          value: value,
        );
    await apply(2, [
      updateBackground(retained.entityId, 'intermediate background'),
      updateBackground(edited.entityId, 'intermediate background'),
      appendSkill('first skill'),
    ]);
    await apply(3, [
      updateBackground(retained.entityId, 'later disclosure'),
      appendSkill('another skill'),
    ]);
    await repo.deleteAttributeById(manuallyRemoved.attributeId);
    expect(
      (await repo.getAttributes(sessionId, [retained.entityId]))
          .map((attr) => attr.attrKey),
      unorderedEquals(['background', 'skills']),
    );

    await repo.runInTransaction(
      () => repo.deleteFactsByTurns(sessionId: sessionId, fromTurn: 2),
    );
    final attributes = await repo.getAttributes(
      sessionId,
      [retained.entityId, edited.entityId],
    );
    expect(attributes.single.attributeId, original.attributeId);
    expect(attributes.single.value, 'early background');
  });

  group('deleteFactsByTurns 回滚 append_list', () {
    // 注意避开语义去重（编辑距离 <= 2 即拦截）：测试值两两差异须足够大
    const turns = {1: '御剑飞行术', 2: '炼丹之术', 3: '奇门遁甲阵法'};
    const listSession = 's-list';
    const listId = 'attr-list';
    final createdAt = DateTime.utc(2026);

    FactsDelta appendDelta(String item) => FactsDelta(
          action: FactAction.appendList,
          entityId: 'ent_a1',
          attrKey: 'skills',
          value: item,
          confidence: 4,
        );

    Future<void> seedList(String value) async {
      await repo.createEntity(
        FactualEntity(
          entityId: 'ent_a1',
          sessionId: listSession,
          type: FactualEntityType.character,
          primaryName: '主角',
          aliases: const [],
          importance: 3,
          createdTurn: 1,
          createdAt: createdAt,
        ),
      );
      await repo.createAttribute(
        FactualAttribute(
          attributeId: listId,
          entityId: 'ent_a1',
          sessionId: listSession,
          attrKey: 'skills',
          value: value,
          valueType: AttributeValueType.list,
          importance: 3,
          createdAt: createdAt,
        ),
      );
    }

    Future<void> rollbackList() => repo.runInTransaction(
          () => repo.deleteFactsByTurns(sessionId: listSession, fromTurn: 3),
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

    test('回滚恢复实际的空列表，并保留该行', () async {
      await seedList('["御剑飞行术"]');
      await repo.insertHistory(
        FactualMemoryHistory(
          entityId: 'ent_a1',
          attributeId: listId,
          action: FactAction.appendList,
          newValue: '御剑飞行术',
          turnNumber: 1,
          createdAt: createdAt,
        ),
      );
      // 手动改值未追加审计。后一轮 append 的 oldValue 才是回退前的基线。
      await repo.updateAttributeValue(listId, '[]', 2, '手动清空列表');
      await repo.runInTransaction(
        () => applier.applyDeltas(
          listSession,
          [appendDelta('炼丹之术')],
          3,
          const FactualConfig(),
        ),
      );
      final current =
          (await repo.getAttributesByKey('ent_a1', 'skills')).single;
      expect(current.listValue, ['炼丹之术']);

      await rollbackList();

      final restored =
          (await repo.getAttributesByKey('ent_a1', 'skills')).single;
      expect(restored.attributeId, listId);
      expect(restored.value, '[]');
      expect(restored.updatedTurn, isNull);
    });

    test('旧列表流水缺少旧值时，按同轮最后一条存留流水恢复全量', () async {
      await seedList('["炼丹之术","奇门遁甲阵法"]');
      for (final (turn, action, before, item) in [
        (2, FactAction.appendList, null, '御剑飞行术'),
        (2, FactAction.appendList, '["御剑飞行术"]', '炼丹之术'),
        (2, FactAction.removeFromList, '["御剑飞行术","炼丹之术"]', '御剑飞行术'),
        (3, FactAction.appendList, null, '奇门遁甲阵法'),
      ]) {
        await repo.insertHistory(
          FactualMemoryHistory(
            entityId: 'ent_a1',
            attributeId: listId,
            action: action,
            oldValue: before,
            newValue: item,
            turnNumber: turn,
            createdAt: createdAt,
          ),
        );
      }

      await rollbackList();

      final restored =
          (await repo.getAttributesByKey('ent_a1', 'skills')).single;
      expect(restored.listValue, ['炼丹之术']);
      expect(restored.updatedTurn, 2);
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
        reason: '演变文本也应召回（新旧都进索引）',
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

  group('getEntitiesByIds / listEntityCatalog / set_importance 回滚', () {
    test('getEntitiesByIds 严格按 sessionId 隔离、包含已归档并保持去重输入序', () async {
      final now = DateTime.utc(2026);
      await repo.createEntity(
        FactualEntity(
          entityId: 'ent_1',
          sessionId: 'sA',
          type: FactualEntityType.character,
          primaryName: '林晚',
          aliases: const [],
          importance: 5,
          createdTurn: 1,
          createdAt: now,
        ),
      );
      await repo.createEntity(
        FactualEntity(
          entityId: 'ent_2',
          sessionId: 'sA',
          type: FactualEntityType.item,
          primaryName: '断剑',
          aliases: const [],
          importance: 2,
          isArchived: true,
          createdTurn: 2,
          createdAt: now,
        ),
      );
      await repo.createEntity(
        FactualEntity(
          entityId: 'ent_other',
          sessionId: 'sB',
          type: FactualEntityType.character,
          primaryName: '他会话角色',
          aliases: const [],
          importance: 5,
          createdTurn: 1,
          createdAt: now,
        ),
      );

      final result = await repo.getEntitiesByIds(
        'sA',
        ['ent_2', 'ent_other', 'ent_missing', 'ent_1', 'ent_2'],
      );
      expect(result.map((e) => e.entityId).toList(), ['ent_2', 'ent_1']);
      expect(result.first.isArchived, isTrue);
    });

    test('listEntityCatalog 动态过滤、全库汇总头、stale_first 排序与分页上限', () async {
      final base = DateTime.utc(2026);
      Future<void> seed({
        required String id,
        required FactualEntityType type,
        required String name,
        required int importance,
        required int createdTurn,
        int? updatedTurn,
        FactualSource source = FactualSource.auto,
        bool isArchived = false,
        bool injectionDisabled = false,
        List<String> aliases = const [],
        int attrCount = 0,
      }) async {
        await repo.createEntity(
          FactualEntity(
            entityId: id,
            sessionId: 'sCat',
            type: type,
            primaryName: name,
            aliases: aliases,
            importance: importance,
            createdTurn: createdTurn,
            createdAt: base.add(Duration(minutes: createdTurn)),
            source: source,
            isArchived: isArchived,
            injectionDisabled: injectionDisabled,
          ),
        );
        if (updatedTurn != null) {
          await repo.updateEntityImportance(id, importance, updatedTurn);
        }
        for (var i = 0; i < attrCount; i++) {
          await repo.createAttribute(
            FactualAttribute(
              attributeId: 'attr_${id}_$i',
              entityId: id,
              sessionId: 'sCat',
              attrKey: 'k$i',
              value: 'v$i',
              importance: 3,
              createdAt: base,
            ),
          );
        }
      }

      // 动态高重要度久未更新（stale_first 最靠前）
      await seed(
        id: 'ent_stale_high',
        type: FactualEntityType.character,
        name: '沈青梧',
        importance: 5,
        createdTurn: 2,
        updatedTurn: 4,
        aliases: const ['青梧'],
        attrCount: 2,
      );
      // 动态高重要度较近更新
      await seed(
        id: 'ent_fresh_high',
        type: FactualEntityType.character,
        name: '林晚',
        importance: 5,
        createdTurn: 1,
        updatedTurn: 20,
        attrCount: 1,
      );
      // 停用注入的动态实体应保留在目录中
      await seed(
        id: 'ent_disabled_dyn',
        type: FactualEntityType.lore,
        name: '旧盟约',
        importance: 3,
        createdTurn: 3,
        injectionDisabled: true,
        aliases: const ['盟约', '古约'],
      );
      // 演化过的 worldbook 实体属于 dynamic
      await seed(
        id: 'ent_evolved_wb',
        type: FactualEntityType.location,
        name: '青云山',
        importance: 4,
        createdTurn: 0,
        updatedTurn: 12,
        source: FactualSource.worldbook,
        attrCount: 3,
      );
      // 未演化静态 worldbook 与 card 不进入 dynamic
      await seed(
        id: 'ent_static_wb',
        type: FactualEntityType.lore,
        name: '世界法则',
        importance: 3,
        createdTurn: 0,
        source: FactualSource.worldbook,
      );
      await seed(
        id: 'ent_static_card',
        type: FactualEntityType.character,
        name: '初始导师',
        importance: 4,
        createdTurn: 0,
        source: FactualSource.card,
      );
      // 已归档实体
      await seed(
        id: 'ent_archived',
        type: FactualEntityType.item,
        name: '碎玉',
        importance: 2,
        createdTurn: 5,
        isArchived: true,
      );

      final page = await repo.listEntityCatalog('sCat', limit: 99);
      expect(page.limit, 50);
      expect(page.totalMatched, 4);
      expect(
        page.items.map((e) => e.entity.entityId).toList(),
        [
          'ent_stale_high',
          'ent_fresh_high',
          'ent_evolved_wb',
          'ent_disabled_dyn',
        ],
      );
      expect(page.items.first.attributeCount, 2);
      expect(page.items.first.aliasCount, 1);
      expect(page.items[2].attributeCount, 3);
      expect(page.items.last.entity.injectionDisabled, isTrue);
      expect(page.items.last.aliasCount, 2);

      // 全会话汇总头不随过滤变化
      expect(page.summary.activeCount, 6);
      expect(page.summary.archivedCount, 1);
      expect(page.summary.totalCount, 7);
      expect(page.summary.dynamicCount, 4);
      expect(page.summary.staticWorldbookCount, 1);
      expect(page.summary.staticCardCount, 1);
      expect(page.summary.typeCounts[FactualEntityType.character], 3);
      expect(page.summary.typeCounts[FactualEntityType.lore], 2);
      expect(page.summary.typeCounts[FactualEntityType.location], 1);

      // 过滤与其它排序方式
      final filteredPage = await repo.listEntityCatalog(
        'sCat',
        entityType: FactualEntityType.character,
        sourceFilter: 'all',
        sort: 'recently_updated',
        updatedAfterTurn: 1,
        limit: 1,
      );
      expect(filteredPage.totalMatched, 2);
      expect(filteredPage.hasMore, isTrue);
      expect(filteredPage.items.single.entity.entityId, 'ent_fresh_high');
      expect(filteredPage.summary.activeCount, 6);

      final staticWbPage = await repo.listEntityCatalog(
        'sCat',
        sourceFilter: 'worldbook',
        updatedBeforeTurn: 5,
      );
      expect(
        staticWbPage.items.map((e) => e.entity.entityId).toList(),
        ['ent_static_wb'],
      );

      final withArchived = await repo.listEntityCatalog(
        'sCat',
        sourceFilter: 'all',
        sort: 'created_desc',
        includeArchived: true,
      );
      expect(withArchived.totalMatched, 7);
      expect(withArchived.items.first.entity.entityId, 'ent_archived');
    });

    test(
        'updateEntityImportance 放行 worldbook/card 且 deleteFactsByTurns 完整回滚重要度与 updatedTurn',
        () async {
      final base = DateTime.utc(2026, 2);
      await repo.createEntity(
        FactualEntity(
          entityId: 'ent_wb_imp',
          sessionId: 'sImp',
          type: FactualEntityType.character,
          primaryName: '白衣剑客',
          aliases: const [],
          importance: 2,
          createdTurn: 0,
          createdAt: base,
          source: FactualSource.worldbook,
          sourceRef: 'wb_1',
        ),
      );
      await repo.createAttribute(
        FactualAttribute(
          attributeId: 'attr_wb_desc',
          entityId: 'ent_wb_imp',
          sessionId: 'sImp',
          attrKey: 'background',
          value: '只读基线背景',
          importance: 4,
          createdAt: base,
          source: FactualSource.worldbook,
        ),
      );

      // 轮 2: 2 -> 4；轮 4: 4 -> 5
      await repo.runInTransaction(
        () => applier.applyDeltasWithResult(
          'sImp',
          const [
            FactsDelta(
              action: FactAction.setImportance,
              entityId: 'ent_wb_imp',
              importance: 4,
              reason: '成为重要盟友',
              confidence: 5,
            ),
          ],
          2,
          const FactualConfig(),
        ),
      );
      await repo.runInTransaction(
        () => applier.applyDeltasWithResult(
          'sImp',
          const [
            FactsDelta(
              action: FactAction.setImportance,
              entityId: 'ent_wb_imp',
              importance: 5,
              reason: '成为主线核心',
              confidence: 5,
            ),
          ],
          4,
          const FactualConfig(),
        ),
      );

      var entity = (await repo.getEntityById('ent_wb_imp'))!;
      expect(entity.importance, 5);
      expect(entity.updatedTurn, 4);
      expect(entity.primaryName, '白衣剑客');
      expect(
        (await repo.getAttributes('sImp', ['ent_wb_imp'])).single.value,
        '只读基线背景',
      );

      // 回滚轮 4：恢复 importance=4, updatedTurn=2
      await repo.runInTransaction(
        () => repo.deleteFactsByTurns(sessionId: 'sImp', fromTurn: 4),
      );
      entity = (await repo.getEntityById('ent_wb_imp'))!;
      expect(entity.importance, 4);
      expect(entity.updatedTurn, 2);

      // 回滚轮 2：恢复初始 importance=2, updatedTurn=null（退回未演化静态状态）
      await repo.runInTransaction(
        () => repo.deleteFactsByTurns(sessionId: 'sImp', fromTurn: 2),
      );
      entity = (await repo.getEntityById('ent_wb_imp'))!;
      expect(entity.importance, 2);
      expect(entity.updatedTurn, isNull);
    });
  });
}
