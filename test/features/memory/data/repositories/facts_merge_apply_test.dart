import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/exceptions/app_exceptions.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/memory/data/repositories/factual_repository_impl.dart';
import 'package:lmstory/features/memory/domain/entities/facts_delta.dart';
import 'package:lmstory/features/memory/domain/entities/factual_attribute.dart';
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
import 'package:lmstory/features/memory/domain/entities/factual_memory_history.dart';
import 'package:lmstory/features/memory/domain/entities/factual_source.dart';

/// 记忆查看器手动归并的落库集成测试（真实 drift 内存库）
///
/// 复现 FactualMemoryTab._applyMergePlan 的写序列（组合既有标准动作），
/// 验证终态与审计历史可读（FactAction.fromString 不会因自定义动作串崩溃）。
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

  test('手动归并落库：目标更新 + 被吸收条目归档 + 审计可读', () async {
    final now = DateTime(2026, 8, 24);

    // 种子：target（边境庄园，含 auto description 行）+ absorbed（庄园）
    await repo.createEntity(
      FactualEntity(
        entityId: 'e-target',
        sessionId: 's1',
        type: FactualEntityType.location,
        primaryName: '边境庄园',
        aliases: const [],
        importance: 3,
        createdTurn: 1,
        createdAt: now,
      ),
    );
    await repo.createAttribute(
      FactualAttribute(
        attributeId: 'attr-t-desc',
        entityId: 'e-target',
        sessionId: 's1',
        attrKey: 'description',
        value: '位于边境',
        importance: 2,
        createdAt: now,
      ),
    );
    await repo.createEntity(
      FactualEntity(
        entityId: 'e-src',
        sessionId: 's1',
        type: FactualEntityType.location,
        primaryName: '庄园',
        aliases: const ['老宅'],
        importance: 2,
        createdTurn: 1,
        createdAt: now,
      ),
    );

    // ── 模拟 _applyMergePlan 的写序列 ──
    await repo.updateEntityBasic(
      entityId: 'e-target',
      primaryName: '边境庄园',
      importance: 4,
      updatedTurn: 1,
    );
    await repo.runInTransaction(() async {
      await repo.updateEntityAliases('e-target', ['老宅', '庄园'], 1);
      await repo.insertHistory(
        FactualMemoryHistory(
          entityId: 'e-target',
          action: FactAction.addAlias,
          newValue: '老宅,庄园',
          reason: '记忆查看器手动归并',
          turnNumber: 1,
          createdAt: now,
        ),
      );

      await repo.updateAttributeValue(
        'attr-t-desc',
        '边境的老庄园，有护城河',
        1,
        '记忆查看器手动归并',
      );
      final created = await repo.createAttribute(
        FactualAttribute(
          attributeId: 'attr-t-features',
          entityId: 'e-target',
          sessionId: 's1',
          attrKey: 'features',
          value: '["护城河"]',
          valueType: AttributeValueType.list,
          importance: 2,
          createdAt: now,
          updatedTurn: 1,
          updateReason: '记忆查看器手动归并',
        ),
      );
      await repo.insertHistory(
        FactualMemoryHistory(
          entityId: 'e-target',
          attributeId: created.attributeId,
          action: FactAction.updateAttr,
          newValue: created.value,
          reason: '记忆查看器手动归并',
          turnNumber: 1,
          createdAt: now,
        ),
      );

      await repo.archiveEntity('e-src', '记忆查看器手动归并', 1);
      await repo.insertHistory(
        FactualMemoryHistory(
          entityId: 'e-src',
          action: FactAction.archiveEntity,
          newValue: '记忆查看器手动归并',
          reason: '记忆查看器手动归并',
          turnNumber: 1,
          createdAt: now,
        ),
      );
    });

    // ── 终态断言 ──
    final active = await repo.getEntities('s1');
    expect(active.map((e) => e.primaryName), ['边境庄园']);
    expect(active.single.importance, 4);
    expect(active.single.aliases, containsAll(['老宅', '庄园']));

    final archived = await repo.getEntities('s1', includeArchived: true);
    expect(
      archived.where((e) => e.entityId == 'e-src').single.isArchived,
      isTrue,
    );

    final attrs = await repo.getAttributes('s1', ['e-target']);
    final description = attrs.firstWhere((a) => a.attrKey == 'description');
    expect(description.value, '边境的老庄园，有护城河');
    expect(attrs.any((a) => a.attrKey == 'features'), isTrue);

    // 审计历史可读（标准动作串，fromString 不抛 ArgumentError）
    final targetHistory = await repo.getHistory('e-target');
    expect(targetHistory.map((h) => h.action), contains(FactAction.addAlias));
    final srcHistory = await repo.getHistory('e-src');
    expect(srcHistory.map((h) => h.action), contains(FactAction.archiveEntity));

    // 精确查重不再命中被吸收名（别名已并入 target，源已归档）
    final dupCheck = await repo.findByName('s1', ['庄园']);
    expect(dupCheck.map((e) => e.entityId), ['e-target']);
  });

  test('归并写序列在单事务内：中途失败零变更（WA-X1 原子性回归）', () async {
    final now = DateTime(2026, 8, 24);

    await repo.createEntity(
      FactualEntity(
        entityId: 'e-target',
        sessionId: 'sA',
        type: FactualEntityType.location,
        primaryName: '边境庄园',
        aliases: const [],
        importance: 3,
        createdTurn: 1,
        createdAt: now,
      ),
    );
    await repo.createEntity(
      FactualEntity(
        entityId: 'e-src',
        sessionId: 'sA',
        type: FactualEntityType.location,
        primaryName: '庄园',
        aliases: const [],
        importance: 2,
        createdTurn: 1,
        createdAt: now,
      ),
    );

    // 模拟 _applyMergePlan：改名与别名并入同事务，归档段抛异常
    await expectLater(
      repo.runInTransaction(() async {
        await repo.updateEntityBasic(
          entityId: 'e-target',
          primaryName: '边境庄园改',
          importance: 4,
          updatedTurn: 1,
        );
        await repo.updateEntityAliases('e-target', ['庄园'], 1);
        await repo.insertHistory(
          FactualMemoryHistory(
            entityId: 'e-target',
            action: FactAction.addAlias,
            newValue: '庄园',
            reason: '记忆查看器手动归并',
            turnNumber: 1,
            createdAt: now,
          ),
        );
        throw StateError('归档段失败');
      }),
      throwsStateError,
    );

    // 零部分终态：改名/重要度/别名/归档全部未生效
    final entities = await repo.getEntities('sA', includeArchived: true);
    final target = entities.firstWhere((e) => e.entityId == 'e-target');
    final src = entities.firstWhere((e) => e.entityId == 'e-src');
    expect(target.primaryName, '边境庄园');
    expect(target.importance, 3);
    expect(target.aliases, isEmpty);
    expect(src.isArchived, isFalse);
  });

  test('add_alias 审计行让归并别名可随回滚撤销（WA-X2 回归）', () async {
    final now = DateTime(2026, 8, 24);

    await repo.createEntity(
      FactualEntity(
        entityId: 'e-target',
        sessionId: 'sB',
        type: FactualEntityType.location,
        primaryName: '边境庄园',
        aliases: const [],
        importance: 3,
        createdTurn: 1,
        createdAt: now,
      ),
    );
    await repo.createEntity(
      FactualEntity(
        entityId: 'e-src',
        sessionId: 'sB',
        type: FactualEntityType.location,
        primaryName: '庄园',
        aliases: const [],
        importance: 2,
        createdTurn: 1,
        createdAt: now,
      ),
    );

    // 生产写序列：别名并入 + add_alias 审计行（turn 5）+ 源归档
    await repo.runInTransaction(() async {
      await repo.updateEntityAliases('e-target', ['庄园'], 5);
      await repo.insertHistory(
        FactualMemoryHistory(
          entityId: 'e-target',
          action: FactAction.addAlias,
          newValue: '庄园',
          reason: '记忆查看器手动归并',
          turnNumber: 5,
          createdAt: now,
        ),
      );
      await repo.archiveEntity('e-src', '记忆查看器手动归并', 5);
      await repo.insertHistory(
        FactualMemoryHistory(
          entityId: 'e-src',
          action: FactAction.archiveEntity,
          newValue: '记忆查看器手动归并',
          reason: '记忆查看器手动归并',
          turnNumber: 5,
          createdAt: now,
        ),
      );
    });

    // 轮 5 重生成回滚：别名撤销、源实体恢复活跃
    await repo.runInTransaction(
      () async => repo.deleteFactsByTurns(sessionId: 'sB', fromTurn: 5),
    );

    final entities = await repo.getEntities('sB', includeArchived: true);
    final target = entities.firstWhere((e) => e.entityId == 'e-target');
    final src = entities.firstWhere((e) => e.entityId == 'e-src');
    expect(target.aliases, isEmpty, reason: 'add_alias 审计行缺失时（修复前）回滚无法撤销并入的别名');
    expect(src.isArchived, isFalse);
  });

  test('WA-D1：多别名归并（逐别名审计行）回滚后别名全部撤销', () async {
    final now = DateTime(2026, 9);

    await repo.createEntity(
      FactualEntity(
        entityId: 'e-target',
        sessionId: 'sC',
        type: FactualEntityType.location,
        primaryName: '边境庄园',
        aliases: const [],
        importance: 3,
        createdTurn: 1,
        createdAt: now,
      ),
    );
    await repo.createEntity(
      FactualEntity(
        entityId: 'e-src',
        sessionId: 'sC',
        type: FactualEntityType.location,
        primaryName: '庄园',
        aliases: const ['老宅', '祖宅'], // 被吸收者主名+别名 = 3 个并入别名
        importance: 2,
        createdTurn: 1,
        createdAt: now,
      ),
    );

    // 生产写序列（修复后）：逐别名一行审计——旧实现 join(',')
    // 逗号并集与回滚端单值精确匹配脱节，多别名归并的回滚移除数恒为 0
    await repo.runInTransaction(() async {
      await repo.updateEntityAliases(
        'e-target',
        ['庄园', '老宅', '祖宅'],
        5,
      );
      for (final alias in ['庄园', '老宅', '祖宅']) {
        await repo.insertHistory(
          FactualMemoryHistory(
            entityId: 'e-target',
            action: FactAction.addAlias,
            newValue: alias,
            reason: '记忆查看器手动归并',
            turnNumber: 5,
            createdAt: now,
          ),
        );
      }
      await repo.archiveEntity('e-src', '记忆查看器手动归并', 5);
      await repo.insertHistory(
        FactualMemoryHistory(
          entityId: 'e-src',
          action: FactAction.archiveEntity,
          newValue: '记忆查看器手动归并',
          reason: '记忆查看器手动归并',
          turnNumber: 5,
          createdAt: now,
        ),
      );
    });

    // 轮 5 重生成回滚：三个并入别名全部撤销
    await repo.runInTransaction(
      () async => repo.deleteFactsByTurns(sessionId: 'sC', fromTurn: 5),
    );

    final entities = await repo.getEntities('sC', includeArchived: true);
    final target = entities.firstWhere((e) => e.entityId == 'e-target');
    expect(target.aliases, isEmpty, reason: '多别名归并回滚后并入的别名必须全部撤销（修复前逗号并集恒残留）');
  });

  test('WA-D1 兼容：旧逗号并集审计行回滚时按逗号拆分撤销', () async {
    final now = DateTime(2026, 9);

    await repo.createEntity(
      FactualEntity(
        entityId: 'e-target',
        sessionId: 'sD',
        type: FactualEntityType.location,
        primaryName: '边境庄园',
        aliases: const [],
        importance: 3,
        createdTurn: 1,
        createdAt: now,
      ),
    );

    // 历史遗留格式
    await repo.runInTransaction(() async {
      await repo.updateEntityAliases('e-target', ['庄园', '老宅'], 5);
      await repo.insertHistory(
        FactualMemoryHistory(
          entityId: 'e-target',
          action: FactAction.addAlias,
          newValue: '庄园,老宅',
          reason: '记忆查看器手动归并',
          turnNumber: 5,
          createdAt: now,
        ),
      );
    });

    await repo.runInTransaction(
      () async => repo.deleteFactsByTurns(sessionId: 'sD', fromTurn: 5),
    );

    final entities = await repo.getEntities('sD');
    final target = entities.firstWhere((e) => e.entityId == 'e-target');
    expect(target.aliases, isEmpty, reason: '旧逗号并集行回滚时按逗号拆分逐个匹配撤销');
  });

  // 只读保留者（角色卡）归并此前必然失败——
  // 落库第一步 updateEntityBasic 被 repo 只读守卫拦截。修复后该场景跳过
  // 改名/重要度写入，只并入别名与 auto 属性（卡名是种子身份标识）。
  test('WA6-1：卡片作为保留者——跳过改名、并入别名、整事务成功', () async {
    final now = DateTime(2026, 9, 6);

    // 种子：卡片实体（source=card）+ auto 重复建档
    await repo.createEntity(
      FactualEntity(
        entityId: 'e-card',
        sessionId: 'sE',
        type: FactualEntityType.character,
        primaryName: '沈青梧',
        aliases: const [],
        importance: 4,
        createdTurn: 0,
        createdAt: now,
        source: FactualSource.card,
      ),
    );
    await repo.createEntity(
      FactualEntity(
        entityId: 'e-dup',
        sessionId: 'sE',
        type: FactualEntityType.character,
        primaryName: '青梧',
        aliases: const ['沈姑娘'],
        importance: 2,
        createdTurn: 3,
        createdAt: now,
      ),
    );

    // ── 复现修复后 _applyMergePlan 对只读保留者的写序列 ──
    //（跳过 updateEntityBasic；别名并集剔除保留者现名；被吸收条目归档）
    await repo.runInTransaction(() async {
      const canonicalName = '沈青梧';
      final aliases = <String>{'沈姑娘', '青梧'}..remove(canonicalName);
      await repo.updateEntityAliases('e-card', aliases.toList(), 0);
      for (final alias in aliases) {
        await repo.insertHistory(
          FactualMemoryHistory(
            entityId: 'e-card',
            action: FactAction.addAlias,
            newValue: alias,
            reason: '记忆查看器手动归并',
            turnNumber: 0,
            createdAt: now,
          ),
        );
      }
      await repo.updateEntityBasic(
        entityId: 'e-dup',
        isArchived: true,
        updatedTurn: 4,
      );
      await repo.insertHistory(
        FactualMemoryHistory(
          entityId: 'e-dup',
          action: FactAction.archiveEntity,
          newValue: '记忆查看器手动归并',
          reason: '记忆查看器手动归并',
          turnNumber: 4,
          createdAt: now,
        ),
      );
    });

    final entities = await repo.getEntities('sE', includeArchived: true);
    final card = entities.firstWhere((e) => e.entityId == 'e-card');
    final dup = entities.firstWhere((e) => e.entityId == 'e-dup');

    // 卡片身份不动：规范名原样；别名并入且规范名不混入
    expect(card.primaryName, '沈青梧');
    expect(card.source, FactualSource.card);
    expect(card.aliases, containsAll(['沈姑娘', '青梧']));
    expect(card.aliases, isNot(contains('沈青梧')));
    // 被吸收条目归档
    expect(dup.isArchived, isTrue);
  });

  test('WA6-1 反证：对只读实体的内容字段调用 updateEntityBasic 仍被守卫拦截', () async {
    final now = DateTime(2026, 9, 6);
    await repo.createEntity(
      FactualEntity(
        entityId: 'e-card2',
        sessionId: 'sF',
        type: FactualEntityType.character,
        primaryName: '老周',
        aliases: const [],
        importance: 3,
        createdTurn: 0,
        createdAt: now,
        source: FactualSource.card,
      ),
    );

    // 守卫必须保持：只读实体的内容字段（主名/类型/重要度/分类）不开后门，
    // 组件层靠跳过调用规避（起守卫按字段收窄：仅内容字段拦截）
    await expectLater(
      repo.updateEntityBasic(entityId: 'e-card2', primaryName: '改名'),
      throwsA(isA<ResourceApplyException>()),
    );
    await expectLater(
      repo.updateEntityBasic(entityId: 'e-card2', importance: 5),
      throwsA(isA<ResourceApplyException>()),
    );
  });

  test('RO-1：只读实体仅 isArchived/updatedTurn 的调用放行（恢复可达）', () async {
    final now = DateTime(2026, 9, 14);
    await repo.createEntity(
      FactualEntity(
        entityId: 'e-card3',
        sessionId: 'sG',
        type: FactualEntityType.character,
        primaryName: '老周',
        aliases: const [],
        importance: 3,
        createdTurn: 0,
        createdAt: now,
        source: FactualSource.card,
      ),
    );

    // 归档=可逆状态标记。AI 可归档导入实体（fact_applier 放行），
    // 手动「恢复」（isArchived:false）必须同路可达，否则归档成死状态。
    await repo.updateEntityBasic(
      entityId: 'e-card3',
      isArchived: true,
      updatedTurn: 2,
    );
    final archived = await repo.getEntityById('e-card3');
    expect(archived, isNotNull);
    expect(archived!.isArchived, isTrue);

    await repo.updateEntityBasic(
      entityId: 'e-card3',
      isArchived: false,
      updatedTurn: 2,
    );
    final restored = await repo.getEntityById('e-card3');
    expect(restored!.isArchived, isFalse, reason: '归档的导入实体必须能从记忆库恢复，不能死在只读守卫里');
    expect(restored.primaryName, '老周', reason: '内容字段不被顺带触碰');
  });
}
