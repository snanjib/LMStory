import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/memory/data/repositories/factual_repository_impl.dart';
import 'package:lmstory/features/memory/domain/entities/factual_attribute.dart';
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
import 'package:lmstory/features/memory/domain/entities/factual_source.dart';
import 'package:lmstory/features/memory/domain/services/memory_query.dart';

/// searchEntitiesByText 主表子串检索（FF1/FF13）
///
/// 覆盖用户报告的「记忆库有一字不差的实体，查证设定却未命中」：
/// 关键词通道此前只查 factual_fts（世界书词条专用索引），auto/角色卡/
/// 手动实体永无索引行。本方法直接扫主表，保证库里可见即可召回。
void main() {
  late AppDatabase db;
  late FactualRepositoryImpl repo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = FactualRepositoryImpl(database: db);
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> seedEntity({
    required String id,
    required String name,
    String sessionId = 's1',
    List<String> aliases = const [],
    int importance = 3,
    bool isArchived = false,
    FactualSource source = FactualSource.auto,
    FactualEntityType type = FactualEntityType.character,
  }) async {
    await repo.createEntity(
      FactualEntity(
        entityId: id,
        sessionId: sessionId,
        type: type,
        primaryName: name,
        aliases: aliases,
        importance: importance,
        createdTurn: 1,
        createdAt: DateTime(2026),
        isArchived: isArchived,
        source: source,
      ),
    );
  }

  Future<void> seedAttr({
    required String attributeId,
    required String entityId,
    required String value,
    String sessionId = 's1',
  }) async {
    await repo.createAttribute(
      FactualAttribute(
        attributeId: attributeId,
        entityId: entityId,
        sessionId: sessionId,
        attrKey: '描述',
        value: value,
        importance: 3,
        createdAt: DateTime(2026),
      ),
    );
  }

  test('auto 实体（无 FTS 行）按主名子串命中——此前关键词通道恒空', () async {
    await seedEntity(id: 'ent_1', name: '旧书店');

    // 关键词通道（世界书 FTS）确实查不到
    expect(await repo.searchWorldFacts('s1', ['旧书店']), isEmpty);

    // 主表子串兜底命中
    final hits = await repo.searchEntitiesByText('s1', ['旧书店']);
    expect(hits.map((e) => e.primaryName), ['旧书店']);
  });

  test('双字/单字短词也能命中（子串不受 trigram 限制）', () async {
    await seedEntity(id: 'ent_1', name: '老人');

    expect(
      (await repo.searchEntitiesByText('s1', ['老人'])).single.entityId,
      'ent_1',
    );
    expect(
      (await repo.searchEntitiesByText('s1', ['老'])).single.entityId,
      'ent_1',
    );
  });

  test('别名与属性值同样命中', () async {
    await seedEntity(id: 'ent_1', name: '旧书店', aliases: ['老书铺']);
    await seedAttr(attributeId: 'a1', entityId: 'ent_1', value: '深处藏着一间密室');

    expect(
      (await repo.searchEntitiesByText('s1', ['老书铺'])).single.entityId,
      'ent_1',
    );
    expect(
      (await repo.searchEntitiesByText('s1', ['密室'])).single.entityId,
      'ent_1',
    );
  });

  test('多词 OR：任一命中即返回，且不重复', () async {
    await seedEntity(id: 'ent_1', name: '旧书店');
    await seedEntity(id: 'ent_2', name: '荒庙');

    final hits = await repo.searchEntitiesByText('s1', ['旧书店', '荒庙']);
    expect(hits.map((e) => e.entityId).toSet(), {'ent_1', 'ent_2'});
  });

  test('归档实体默认排除，includeArchived 时可探测到', () async {
    await seedEntity(id: 'ent_1', name: '旧书店', isArchived: true);

    expect(await repo.searchEntitiesByText('s1', ['旧书店']), isEmpty);
    final all = await repo.searchEntitiesByText(
      's1',
      ['旧书店'],
      includeArchived: true,
    );
    expect(all.single.entityId, 'ent_1');
  });

  test('会话隔离：别会话同名实体不返回（FF13 同类）', () async {
    await seedEntity(id: 'ent_other', name: '旧书店', sessionId: 's2');

    expect(await repo.searchEntitiesByText('s1', ['旧书店']), isEmpty);
    expect(
      (await repo.searchEntitiesByText('s2', ['旧书店'])).single.entityId,
      'ent_other',
    );
  });

  test('LIKE 通配符按字面匹配（% 不误当通配）', () async {
    await seedEntity(id: 'ent_1', name: '旧书店');
    await seedEntity(id: 'ent_2', name: '荒庙');

    expect(await repo.searchEntitiesByText('s1', ['%']), isEmpty);
    expect(
      (await repo.searchEntitiesByText('s1', [MemoryQuery.escapeLike('旧书')]))
          .single
          .entityId,
      'ent_1',
    );
  });

  test('排序：importance 降序', () async {
    await seedEntity(id: 'ent_low', name: '旧书店', importance: 2);
    await seedEntity(id: 'ent_high', name: '旧书店分店', importance: 5);

    final hits = await repo.searchEntitiesByText('s1', ['旧书店']);
    expect(hits.map((e) => e.entityId).toList(), ['ent_high', 'ent_low']);
  });

  test('空词元列表返回空（不构造空 SQL）', () async {
    await seedEntity(id: 'ent_1', name: '旧书店');
    expect(await repo.searchEntitiesByText('s1', const []), isEmpty);
    expect(await repo.searchEntitiesByText('s1', const ['  ']), isEmpty);
  });

  test('worldbook 实体补 FTS 行后关键词与子串两路都能召回', () async {
    await seedEntity(
      id: 'ent_wb',
      name: '禁书区',
      source: FactualSource.worldbook,
    );
    await repo.insertFactualFts(
      entityId: 'ent_wb',
      sessionId: 's1',
      primaryName: '禁书区',
      aliases: const [],
      description: '图书馆地下的禁地',
    );

    expect(
      (await repo.searchWorldFacts('s1', ['禁书区'])).single.entityId,
      'ent_wb',
    );
    expect(
      (await repo.searchEntitiesByText('s1', ['禁书'])).single.entityId,
      'ent_wb',
    );
  });

  test('FF13：searchWorldFacts 最终实体查询带 session 过滤（索引串会话不泄漏）', () async {
    // 故意制造不一致：实体属 s2、FTS 行写成 s1（导入/维护异常形态）
    await seedEntity(
      id: 'ent_wb',
      name: '禁书区',
      sessionId: 's2',
      source: FactualSource.worldbook,
    );
    await repo.insertFactualFts(
      entityId: 'ent_wb',
      sessionId: 's1',
      primaryName: '禁书区',
      aliases: const [],
      description: '图书馆地下的禁地',
    );

    // s1 的 FTS 行命中了 id，但实体属于 s2 → 最终查询必须拦住
    expect(await repo.searchWorldFacts('s1', ['禁书区']), isEmpty);
  });

  test('FF2：updateEntityBasic 改名同步 factual_fts（旧名不再召回）', () async {
    await seedEntity(id: 'ent_1', name: '旧书店');
    await repo.insertFactualFts(
      entityId: 'ent_1',
      sessionId: 's1',
      primaryName: '旧书店',
      aliases: const [],
      description: '一条街角的小店',
    );

    await repo.updateEntityBasic(entityId: 'ent_1', primaryName: '新书店');

    expect(await repo.searchWorldFacts('s1', ['旧书店']), isEmpty);
    expect(
      (await repo.searchWorldFacts('s1', ['新书店'])).single.entityId,
      'ent_1',
    );
  });

  test('FF3：deleteFactsByTurns 删除实体时同步清 FTS 行（不变量锚定）', () async {
    await seedEntity(id: 'ent_1', name: '旧书店');
    await repo.insertFactualFts(
      entityId: 'ent_1',
      sessionId: 's1',
      primaryName: '旧书店',
      aliases: const [],
      description: '一条街角的小店',
    );

    await repo.deleteFactsByTurns(sessionId: 's1', fromTurn: 1);

    final rows =
        await db.customSelect('SELECT entity_id FROM factual_fts').get();
    expect(rows, isEmpty, reason: '实体已删，索引行不得残留');
  });
}
