import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/memory/data/repositories/factual_repository_impl.dart';
import 'package:lmstory/features/memory/domain/entities/facts_delta.dart';
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
import 'package:lmstory/features/memory/domain/entities/factual_source.dart';
import 'package:lmstory/features/memory/domain/services/fact_applier.dart';
import 'package:lmstory/features/resource_library/data/repositories/resource_library_repository_impl.dart';
import 'package:lmstory/features/resource_library/domain/entities/parsed_character_card.dart';
import 'package:lmstory/features/resource_library/domain/services/resource_apply_service.dart';
import 'package:lmstory/features/resource_library/domain/services/resource_projection_service.dart';

/// 世界资产数据层测试
///
/// 1. 删除资源级联清理投影：此前仅置空 sourceRef，投影实体成为永久孤儿
///    （unapply 不可见、记忆库只读守卫不可删、key 阈值实体每轮强制注入）
/// 2. 应用计数只计实体：此前 description/personality 基线属性也计数，
///    「已应用 3 个实体」实际只有 1 个实体
/// 3. 重生成回滚别名同步 FTS：F7 漂移在回滚路径复发
void main() {
  late AppDatabase db;
  late ResourceLibraryRepositoryImpl resourceRepo;
  late FactualRepositoryImpl factualRepo;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.customSelect('SELECT 1').get();
    resourceRepo = ResourceLibraryRepositoryImpl(database: db);
    factualRepo = FactualRepositoryImpl(database: db);
  });

  tearDown(() async {
    await db.close();
  });

  Future<int> count(String sql, [List<Object?> args = const []]) async {
    final rows = await db
        .customSelect(sql, variables: args.map(Variable.new).toList())
        .get();
    return rows.first.read<int>('c');
  }

  Future<void> projectCardTo(String cardId, String sessionId) async {
    final now = DateTime.now();
    await factualRepo.createEntity(
      FactualEntity(
        entityId: 'ent_$sessionId',
        sessionId: sessionId,
        type: FactualEntityType.character,
        primaryName: '角色',
        aliases: const [],
        importance: 5,
        createdTurn: 0,
        createdAt: now,
        source: FactualSource.card,
        sourceRef: cardId,
      ),
    );
    await db.customStatement(
      'INSERT INTO factual_fts (primary_name, aliases, description, '
      'entity_id, session_id) VALUES (?, ?, ?, ?, ?)',
      ['角色', '', '', 'ent_$sessionId', sessionId],
    );
  }

  test('删除角色卡级联清理所有会话的投影（不再只置空 sourceRef）', () async {
    final card = await resourceRepo.createCharacterCard(
      name: 'ReZero',
      rawJson: '{}',
      sourceFormat: 'v3',
    );
    await projectCardTo(card.cardId, 's1');
    await projectCardTo(card.cardId, 's2');

    await resourceRepo.deleteCharacterCard(card.cardId);

    expect(
      await count('SELECT COUNT(*) c FROM factual_entities'),
      0,
      reason: '投影实体必须随资源删除（否则永久孤儿）',
    );
    expect(await count('SELECT COUNT(*) c FROM factual_fts'), 0);
    // 无投影资源删除仍是干净的 no-op
    expect(await resourceRepo.getAllCharacterCards(), isEmpty);
  });

  test('删除世界书同样级联清理投影', () async {
    final book = await resourceRepo.createWorldbook(name: '书', rawJson: '{}');
    final now = DateTime.now();
    await factualRepo.createEntity(
      FactualEntity(
        entityId: 'ent_w1',
        sessionId: 's1',
        type: FactualEntityType.lore,
        primaryName: '设定',
        aliases: const [],
        importance: 2,
        createdTurn: 0,
        createdAt: now,
        source: FactualSource.worldbook,
        sourceRef: book.bookId,
      ),
    );

    await resourceRepo.deleteWorldbook(book.bookId);

    expect(await count('SELECT COUNT(*) c FROM factual_entities'), 0);
  });

  test('应用计数只计实体（基线属性不再计数）', () async {
    final service = ResourceProjectionService(repository: factualRepo);
    final card = await resourceRepo.createCharacterCard(
      name: 'ReZero',
      rawJson: '{}',
      sourceFormat: 'v3',
    );

    final count = await service.applyCharacterCard(
      sessionId: 's1',
      cardId: card.cardId,
      card: const ParsedCharacterCard(
        name: '爱蜜莉雅',
        description: '银发精灵',
        personality: '温柔',
        specVersion: 'v3',
        embeddedEntries: [],
      ),
    );

    expect(
      count,
      1,
      reason: '典型卡（description+personality 齐全）投影的是 1 个实体，与取消应用的计数口径对称',
    );
  });

  test('重生成回滚别名同步 factual_fts（F7 漂移不在回滚路径复发）', () async {
    final applier = FactApplier(repository: factualRepo);
    final now = DateTime.now();
    await factualRepo.createEntity(
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
    // 投影路径会显式建 FTS 行（insertFactualFts）
    await factualRepo.insertFactualFts(
      entityId: 'ent_c1',
      sessionId: 's1',
      primaryName: '女主',
      aliases: const [],
      description: '',
    );
    // 第 3 轮 AI 加别名 → 实体与 FTS 均已同步
    const delta = FactsDelta(
      action: FactAction.addAlias,
      entityId: 'ent_c1',
      value: '银发少女',
      reason: '称呼变化',
      confidence: 4,
    );
    await applier.applyDeltas('s1', [delta], 3, const FactualConfig());

    // 从第 3 轮起重写 → 别名回滚，FTS 不得残留
    await applier.deleteFactsByTurns(sessionId: 's1', fromTurn: 3);

    final ftsRow = await db
        .customSelect(
          "SELECT aliases FROM factual_fts WHERE entity_id = 'ent_c1'",
        )
        .get();
    expect(ftsRow, hasLength(1), reason: '实体存活（createdTurn=0），FTS 行应在');
    expect(
      ftsRow.first.read<String>('aliases'),
      isNot(contains('银发少女')),
      reason: '已回滚的别名不得继续可召回',
    );
  });

  test('F1 链路：投影 → 取消应用 → 实体/FTS/检索全部清空', () async {
    final projection = ResourceProjectionService(repository: factualRepo);
    final applyService = ResourceApplyService(
      resourceRepository: resourceRepo,
      projectionService: projection,
    );
    final card = await resourceRepo.createCharacterCard(
      name: 'ReZero',
      rawJson: '{"spec":"chara_card_v2","data":{"name":"ReZero"}}',
      sourceFormat: 'v2',
    );
    await applyService.applyCharacterCard(
      sessionId: 's1',
      cardId: card.cardId,
    );

    expect(
      await factualRepo.findByName('s1', const ['ReZero']),
      isNotEmpty,
      reason: '应用后实体可检索',
    );
    // 注：角色卡投影不建 factual_fts 行（FTS 是世界书词条召回通道）

    final removed = await applyService.unapplyResource(
      sessionId: 's1',
      sourceRef: card.cardId,
    );

    expect(removed, 1);
    expect(await factualRepo.findByName('s1', const ['ReZero']), isEmpty);
    expect(await count('SELECT COUNT(*) c FROM factual_entities'), 0);
    expect(await count('SELECT COUNT(*) c FROM factual_attributes'), 0);
    expect(await count('SELECT COUNT(*) c FROM factual_fts'), 0);
    expect(await count('SELECT COUNT(*) c FROM factual_memory_history'), 0);
  });
}
