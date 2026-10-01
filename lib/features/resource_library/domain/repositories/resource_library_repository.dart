import 'package:lmstory/features/resource_library/domain/entities/character_card.dart';
import 'package:lmstory/features/resource_library/domain/entities/worldbook.dart';

/// 资源库仓库接口（角色卡 + 世界书，DOC-15 §9.1）
///
/// 全局资源库：存完整原始 JSON（无损），供详情展示 + 投影到会话事实层。
abstract class ResourceLibraryRepository {
  // ─── 角色卡 ──────────────────────────────────────────────────────────

  Future<List<CharacterCard>> getAllCharacterCards();

  Future<CharacterCard?> getCharacterCard(String cardId);

  Future<CharacterCard> createCharacterCard({
    required String name,
    required String rawJson,
    String? sourceFormat,
  });

  /// 覆盖保存：写 name/rawJson/updatedAt，**id 不变**（不弄断会话已应用引用）。
  Future<void> updateCharacterCard({
    required String cardId,
    required String name,
    required String rawJson,
  });

  Future<void> deleteCharacterCard(String cardId);

  // ─── 世界书 ──────────────────────────────────────────────────────────

  Future<List<Worldbook>> getAllWorldbooks();

  Future<Worldbook?> getWorldbook(String bookId);

  Future<Worldbook> createWorldbook({
    required String name,
    required String rawJson,
  });

  /// 覆盖保存：写 name/rawJson/updatedAt，**id 不变**（同卡）。
  Future<void> updateWorldbook({
    required String bookId,
    required String name,
    required String rawJson,
  });

  Future<void> deleteWorldbook(String bookId);
}
