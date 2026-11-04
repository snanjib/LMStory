import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/exceptions/app_exceptions.dart';
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
import 'package:lmstory/features/memory/domain/entities/factual_source.dart';
import 'package:lmstory/features/memory/domain/entities/force_inject_target.dart';
import 'package:lmstory/features/resource_library/domain/entities/normalized_world_entry.dart';
import 'package:lmstory/features/resource_library/domain/entities/parsed_character_card.dart';
import 'package:lmstory/features/resource_library/domain/services/resource_projection_service.dart';

import '../../../../helpers/fake_factual_repository.dart';

/// ResourceProjectionService 单元测试（DOC-15 §9.2 / §8 只读语义）
void main() {
  late FakeFactualRepository repo;
  late ResourceProjectionService service;

  setUp(() {
    repo = FakeFactualRepository();
    service = ResourceProjectionService(repository: repo);
  });

  NormalizedWorldEntry entry({
    List<String> keys = const ['货币汇率'],
    String content = '1金币=100银币',
    bool constant = false,
    bool enabled = true,
  }) =>
      NormalizedWorldEntry(
        keys: keys,
        secondaryKeys: const [],
        comment: '',
        content: content,
        constant: constant,
        enabled: enabled,
        vectorized: false,
      );

  ParsedCharacterCard card({
    String name = '女主',
    String description = '孤女',
    String personality = '内向',
    List<NormalizedWorldEntry> embedded = const [],
  }) =>
      ParsedCharacterCard(
        name: name,
        description: description,
        personality: personality,
        specVersion: 'v3',
        embeddedEntries: embedded,
      );

  group('applyCharacterCard', () {
    test('投影 character 实体 + 基线属性 + 内嵌世界书（只读、不写历史）', () async {
      final count = await service.applyCharacterCard(
        sessionId: 's1',
        cardId: 'card_1',
        defaultCharacterName: '未命名角色',
        duplicateErrorMessage: '已存在同名角色',
        card: card(embedded: [entry()]),
      );

      // 计数只含实体（1 character + 1 lore）；
      // 基线属性是实体的附属投影，不计数（与取消应用计数口径对称）
      expect(count, 2);

      final character = repo.entitiesById.values.firstWhere(
        (e) => e.type == FactualEntityType.character,
      );
      expect(character.primaryName, '女主');
      expect(character.source, FactualSource.card);
      expect(character.sourceRef, 'card_1');
      expect(character.createdTurn, 0);
      expect(character.importance, 5);

      final lore = repo.entitiesById.values.firstWhere(
        (e) => e.type == FactualEntityType.lore,
      );
      expect(lore.primaryName, '货币汇率');
      expect(lore.source, FactualSource.worldbook);
      expect(lore.importance, 2);
      expect(lore.createdTurn, 0);

      // 基线属性 source=card，不写历史（只读完整性）
      final baselines =
          repo.createdAttributes.where((a) => a.source == FactualSource.card);
      expect(baselines, hasLength(2)); // background + personality
      expect(repo.histories, isEmpty);
    });

    test('同名实体已存在 → 抛 ResourceApplyException', () async {
      repo.entitiesById = {
        'ent_exist': FactualEntity(
          entityId: 'ent_exist',
          sessionId: 's1',
          type: FactualEntityType.character,
          primaryName: '女主',
          aliases: const [],
          importance: 3,
          createdTurn: 1,
          createdAt: DateTime.now(),
        ),
      };
      expect(
        () => service.applyCharacterCard(
          sessionId: 's1',
          cardId: 'card_1',
          defaultCharacterName: '未命名角色',
          duplicateErrorMessage: '已存在同名角色',
          card: card(),
        ),
        throwsA(isA<ResourceApplyException>()),
      );
    });

    test('空名卡同名检测：二次应用空名卡对齐 defaultCharacterName 判定重复并拒绝', () async {
      repo.entitiesById = {
        'ent_unnamed': FactualEntity(
          entityId: 'ent_unnamed',
          sessionId: 's1',
          type: FactualEntityType.character,
          primaryName: '未命名角色',
          aliases: const [],
          importance: 3,
          createdTurn: 1,
          createdAt: DateTime.now(),
        ),
      };
      expect(
        () => service.applyCharacterCard(
          sessionId: 's1',
          cardId: 'card_empty_2',
          defaultCharacterName: '未命名角色',
          duplicateErrorMessage: '已存在同名角色「未命名角色」，应用被拒绝',
          card: card(name: '   '),
        ),
        throwsA(
          isA<ResourceApplyException>().having(
            (e) => e.message,
            'message',
            '已存在同名角色「未命名角色」，应用被拒绝',
          ),
        ),
      );
    });

    test('空名卡内嵌词条：同名词条对齐 primaryName 去重跳过不重复创建', () async {
      final count = await service.applyCharacterCard(
        sessionId: 's1',
        cardId: 'card_with_embedded',
        defaultCharacterName: '未命名角色',
        duplicateErrorMessage: '已存在同名角色',
        card: card(
          name: '',
          embedded: [
            entry(keys: const ['未命名角色']),
          ],
        ),
      );
      // 角色实体 1 个，内嵌同名词条跳过，总数 1
      expect(count, 1);
    });
  });

  group('applyWorldbook', () {
    test('投影 lore 实体：constant→forceInject=world，停用词条跳过', () async {
      final count = await service.applyWorldbook(
        sessionId: 's1',
        bookId: 'book_1',
        defaultSettingName: '未命名设定',
        entries: [
          entry(keys: const ['a'], constant: true),
          entry(keys: const ['b'], enabled: false), // 停用
        ],
      );
      expect(count, 1);
      final lore = repo.entitiesById.values.single;
      expect(lore.source, FactualSource.worldbook);
      expect(lore.sourceRef, 'book_1');
      expect(lore.importance, 2); // constant 不再映射 importance=5
      expect(lore.forceInject, ForceInjectTarget.world);
      expect(lore.createdTurn, 0);
    });

    test('非 constant 词条 → forceInject=none + importance=2', () async {
      await service.applyWorldbook(
        sessionId: 's1',
        bookId: 'book_1',
        defaultSettingName: '未命名设定',
        entries: [entry()],
      );
      final lore = repo.entitiesById.values.single;
      expect(lore.importance, 2);
      expect(lore.forceInject, ForceInjectTarget.none);
    });

    test('同名词条去重：第二个同名词条跳过', () async {
      final count = await service.applyWorldbook(
        sessionId: 's1',
        bookId: 'book_1',
        defaultSettingName: '未命名设定',
        entries: [
          entry(),
          entry(content: '另一条'),
        ],
      );
      expect(count, 1);
      expect(repo.entitiesById, hasLength(1));
    });

    test('B11 归档让名：撞已归档同名实体 → 正常投影（不再跳过）', () async {
      //  根治：主名唯一索引改 partial（is_archived=0），
      // 归档实体释放主名——撞归档名的词条照常创建（时代的
      // 「跳过保整书」降级语义退役）；撞活跃同名仍跳过。
      repo.entitiesById = {
        'ent_archived': FactualEntity(
          entityId: 'ent_archived',
          sessionId: 's1',
          type: FactualEntityType.character,
          primaryName: '魔法',
          aliases: const [],
          importance: 3,
          createdTurn: 1,
          createdAt: DateTime.now(),
          isArchived: true,
        ),
      };
      final count = await service.applyWorldbook(
        sessionId: 's1',
        bookId: 'book_1',
        defaultSettingName: '未命名设定',
        entries: [
          entry(keys: const ['魔法']), // 撞归档名 → 正常投影
          entry(keys: const ['王国']), // 正常投影
        ],
      );
      expect(count, 2, reason: '归档名不占用，两条词条都投影');
      expect(
        repo.entitiesById.values.where((e) => e.primaryName == '魔法'),
        hasLength(2),
        reason: '归档行 + 新活跃行同名并存（partial 索引允许）',
      );
    });

    test('撞活跃同名词条 → 仍跳过（活跃互斥不变）', () async {
      repo.entitiesById = {
        'ent_active': FactualEntity(
          entityId: 'ent_active',
          sessionId: 's1',
          type: FactualEntityType.lore,
          primaryName: '魔法',
          aliases: const [],
          importance: 3,
          createdTurn: 1,
          createdAt: DateTime.now(),
        ),
      };
      final count = await service.applyWorldbook(
        sessionId: 's1',
        bookId: 'book_1',
        defaultSettingName: '未命名设定',
        entries: [
          entry(keys: const ['魔法']), // 撞活跃名 → 跳过
          entry(keys: const ['王国']), // 正常投影
        ],
      );
      expect(count, 1);
    });

    test('B11 归档让名：卡主名撞已归档实体 → 正常应用（不再拒绝）', () async {
      repo.entitiesById = {
        'ent_archived': FactualEntity(
          entityId: 'ent_archived',
          sessionId: 's1',
          type: FactualEntityType.character,
          primaryName: '女主',
          aliases: const [],
          importance: 3,
          createdTurn: 1,
          createdAt: DateTime.now(),
          isArchived: true,
        ),
      };
      final count = await service.applyCharacterCard(
        sessionId: 's1',
        cardId: 'card_1',
        defaultCharacterName: '未命名角色',
        duplicateErrorMessage: '已存在同名角色',
        card: card(),
      );
      expect(count, 1, reason: '归档名不占用，卡片照常投影');
    });
  });
}
