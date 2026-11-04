import 'package:drift/drift.dart';
import 'package:lmstory/core/exceptions/app_exceptions.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/resource_library/domain/entities/character_card.dart';
import 'package:lmstory/features/resource_library/domain/entities/worldbook.dart';
import 'package:lmstory/features/resource_library/domain/repositories/resource_library_repository.dart';
import 'package:uuid/uuid.dart';

/// 资源库仓库实现（Data 层，DOC-15 §9.1）
///
/// 纯数据存取：角色卡/世界书资源的 CRUD。开自身事务（单表原子操作）。
class ResourceLibraryRepositoryImpl implements ResourceLibraryRepository {
  ResourceLibraryRepositoryImpl({required AppDatabase database})
      : _database = database;

  final AppDatabase _database;
  final _uuid = const Uuid();

  // ─── 角色卡 ──────────────────────────────────────────────────────────

  @override
  Future<List<CharacterCard>> getAllCharacterCards() async {
    try {
      final rows = await _database.select(_database.characterCardsTable).get();
      return rows.map(_cardFromTyped).toList();
    } catch (e) {
      throw QueryException('Failed to get all character cards: $e');
    }
  }

  @override
  Future<CharacterCard?> getCharacterCard(String cardId) async {
    try {
      final row = await (_database.select(_database.characterCardsTable)
            ..where((t) => t.cardId.equals(cardId)))
          .getSingleOrNull();
      return row == null ? null : _cardFromTyped(row);
    } catch (e) {
      throw QueryException('Failed to get character card: $e');
    }
  }

  @override
  Future<CharacterCard> createCharacterCard({
    required String name,
    required String rawJson,
    String? sourceFormat,
  }) async {
    try {
      final cardId = _uuid.v4();
      final now = DateTime.now();
      await _database.into(_database.characterCardsTable).insert(
            CharacterCardsTableCompanion.insert(
              cardId: cardId,
              name: name,
              rawJson: rawJson,
              sourceFormat: Value(sourceFormat),
              createdAt: Value(now),
              updatedAt: Value(now),
            ),
          );
      return CharacterCard(
        cardId: cardId,
        name: name,
        rawJson: rawJson,
        sourceFormat: sourceFormat,
        createdAt: now,
        updatedAt: now,
      );
    } catch (e) {
      throw QueryException('Failed to create character card: $e');
    }
  }

  @override
  Future<void> updateCharacterCard({
    required String cardId,
    required String name,
    required String rawJson,
  }) async {
    try {
      await (_database.update(_database.characterCardsTable)
            ..where((t) => t.cardId.equals(cardId)))
          .write(
        CharacterCardsTableCompanion(
          name: Value(name),
          rawJson: Value(rawJson),
          updatedAt: Value(DateTime.now()),
        ),
      );
    } catch (e) {
      throw QueryException('Failed to update character card: $e');
    }
  }

  @override
  Future<void> deleteCharacterCard(String cardId) async {
    try {
      await _database.transaction(() async {
        await (_database.delete(_database.characterCardsTable)
              ..where((t) => t.cardId.equals(cardId)))
            .go();
        // 级联清理所有会话的投影实体。
        // 此前仅置空 sourceRef（DOC-15 §9.4 #3 旧决策）——投影成为永久
        // 孤儿：取消应用分组不可见、记忆库只读守卫不可删，角色卡实体
        // importance=5 达 key 阈值会每轮强制注入直到会话删除。
        // 与 F1 的 deleteEntitiesBySourceRef 同口径（属性/历史/实体/FTS）。
        await _cascadeDeleteProjections(cardId);
      });
    } catch (e) {
      throw QueryException('Failed to delete character card: $e');
    }
  }

  // ─── 世界书 ──────────────────────────────────────────────────────────

  @override
  Future<List<Worldbook>> getAllWorldbooks() async {
    try {
      final rows = await _database.select(_database.worldbooksTable).get();
      return rows.map(_bookFromTyped).toList();
    } catch (e) {
      throw QueryException('Failed to get all worldbooks: $e');
    }
  }

  @override
  Future<Worldbook?> getWorldbook(String bookId) async {
    try {
      final row = await (_database.select(_database.worldbooksTable)
            ..where((t) => t.bookId.equals(bookId)))
          .getSingleOrNull();
      return row == null ? null : _bookFromTyped(row);
    } catch (e) {
      throw QueryException('Failed to get worldbook: $e');
    }
  }

  @override
  Future<Worldbook> createWorldbook({
    required String name,
    required String rawJson,
  }) async {
    try {
      final bookId = _uuid.v4();
      final now = DateTime.now();
      await _database.into(_database.worldbooksTable).insert(
            WorldbooksTableCompanion.insert(
              bookId: bookId,
              name: name,
              rawJson: rawJson,
              createdAt: Value(now),
              updatedAt: Value(now),
            ),
          );
      return Worldbook(
        bookId: bookId,
        name: name,
        rawJson: rawJson,
        createdAt: now,
        updatedAt: now,
      );
    } catch (e) {
      throw QueryException('Failed to create worldbook: $e');
    }
  }

  @override
  Future<void> updateWorldbook({
    required String bookId,
    required String name,
    required String rawJson,
  }) async {
    try {
      await (_database.update(_database.worldbooksTable)
            ..where((t) => t.bookId.equals(bookId)))
          .write(
        WorldbooksTableCompanion(
          name: Value(name),
          rawJson: Value(rawJson),
          updatedAt: Value(DateTime.now()),
        ),
      );
    } catch (e) {
      throw QueryException('Failed to update worldbook: $e');
    }
  }

  @override
  Future<void> deleteWorldbook(String bookId) async {
    try {
      await _database.transaction(() async {
        await (_database.delete(_database.worldbooksTable)
              ..where((t) => t.bookId.equals(bookId)))
            .go();
        // 同角色卡，级联清理投影
        await _cascadeDeleteProjections(bookId);
      });
    } catch (e) {
      throw QueryException('Failed to delete worldbook: $e');
    }
  }

  /// 级联删除某资源（卡/书）在所有会话的投影：属性 → 历史 → 实体 → FTS。
  ///
  /// 注：与 ChatRepositoryImpl.deleteSession 直删 agent_events 同属
  /// "数据层直删跨 feature 表"的既有取舍（避免 feature 间循环依赖）。
  Future<void> _cascadeDeleteProjections(String sourceRef) async {
    final entities = await (_database.select(_database.factualEntitiesTable)
          ..where((t) => t.sourceRef.equals(sourceRef)))
        .get();
    if (entities.isEmpty) return;
    final ids = entities.map((e) => e.entityId).toList();

    await (_database.delete(_database.factualAttributesTable)
          ..where((t) => t.entityId.isIn(ids)))
        .go();
    await (_database.delete(_database.factualMemoryHistoryTable)
          ..where((t) => t.entityId.isIn(ids)))
        .go();
    await (_database.delete(_database.factualEntitiesTable)
          ..where((t) => t.entityId.isIn(ids)))
        .go();
    for (final id in ids) {
      await _database.customStatement(
        'DELETE FROM factual_fts WHERE entity_id = ?',
        [id],
      );
    }
  }

  // ─── 映射辅助 ────────────────────────────────────────────────────────

  CharacterCard _cardFromTyped(CharacterCardsTableData row) => CharacterCard(
        cardId: row.cardId,
        name: row.name,
        rawJson: row.rawJson,
        sourceFormat: row.sourceFormat,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
      );

  Worldbook _bookFromTyped(WorldbooksTableData row) => Worldbook(
        bookId: row.bookId,
        name: row.name,
        rawJson: row.rawJson,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
      );
}
