import 'package:lmstory/core/exceptions/app_exceptions.dart';
import 'package:lmstory/features/memory/domain/entities/factual_attribute.dart';
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
import 'package:lmstory/features/memory/domain/entities/factual_source.dart';
import 'package:lmstory/features/memory/domain/entities/force_inject_target.dart';
import 'package:lmstory/features/memory/domain/repositories/factual_repository.dart';
import 'package:lmstory/features/resource_library/domain/entities/normalized_world_entry.dart';
import 'package:lmstory/features/resource_library/domain/entities/parsed_character_card.dart';
import 'package:uuid/uuid.dart';

/// 资源投影服务（DOC-15 §9.2 / §8 只读语义）
///
/// 把解析后的角色卡/世界书「投影」到会话事实层，生成只读实体/属性：
/// - 角色卡 → `character` 实体（source=card，sourceRef=cardId）+ 基线属性（source=card），
///   实体 importance 默认 3（与 AI 建档同级，不占关键实体常驻配额）
/// - 世界书词条 → `lore` 实体（source=worldbook，sourceRef=bookId），
///   实体 importance 固定 2（constant 由 forceInject=world 表达）
///
/// 只读约束（DOC-15 §8）：
/// - 投影实体 `createdTurn=0`（会话预置，非对话产生，避免被 deleteFactsByTurns 误删）
/// - 基线属性**不写历史**（满足 §8.2 只读完整性，回滚按 history 判定）
/// - 整卡/整书在事务内投影（§9.3 全投影或全不）
class ResourceProjectionService {
  ResourceProjectionService({
    required FactualRepository repository,
    Uuid? uuid,
  })  : _repository = repository,
        _uuid = uuid ?? const Uuid();

  final FactualRepository _repository;
  final Uuid _uuid;

  /// 取消应用：按投影来源成组移除种子实体（F1 修复 2026-08-23）
  ///
  /// "种子不是门票"的另一半——用户此前只能应用不能移除，删除资源库文件
  /// 后实体仍活在所有会话里。实体携带的 auto 演变行随实体一并删除
  /// （种子离开，其上的生长随之而去）。返回删除的实体数。
  Future<int> unapply({
    required String sessionId,
    required String sourceRef,
  }) {
    return _repository.deleteEntitiesBySourceRef(sessionId, sourceRef);
  }

  /// 应用角色卡：投影 character 实体 + 基线属性 + 内嵌世界书词条。
  ///
  /// 角色实体默认 importance=3：与 AI 对话建档同级，进「已知实体」
  /// 候选而不占关键实体（>= keyEntityImportanceThreshold，默认 5）
  /// 常驻配额；被剧情提及时经检索命中注入（focusEntityIds 全保留），
  /// 不会重复建档。仅影响未来导入，不批量下调存量、不动手动设定值。
  ///
  /// 遇同名实体抛 [ResourceApplyException]（DOC-15 §9.4 #2：拒绝应用）。
  /// 返回投影的实体数（含内嵌世界书词条）。
  Future<int> applyCharacterCard({
    required String sessionId,
    required String cardId,
    required ParsedCharacterCard card,
    required String defaultCharacterName,
    required String duplicateErrorMessage,
    String? defaultSettingName,
  }) {
    return _repository.runInTransaction(() async {
      final primaryName =
          card.name.trim().isNotEmpty ? card.name.trim() : defaultCharacterName;

      // 去重：同名【活跃】实体已存在 → 拒绝（DOC-15 §9.4 #2）。
      // （根治）：主名唯一索引已改 partial（WHERE is_archived=0），
      // 归档让名——撞归档名正常创建，仅活跃同名仍拒绝。
      final occupiedNames = await _loadOccupiedNames(sessionId);
      if (occupiedNames.contains(primaryName)) {
        throw ResourceApplyException(duplicateErrorMessage);
      }

      var count = 0;
      final entity = FactualEntity(
        entityId: 'ent_${_uuid.v4()}',
        sessionId: sessionId,
        type: FactualEntityType.character,
        primaryName: primaryName,
        aliases: const [],
        // 默认 3 分（见方法注释）：导入即关键实体（旧值 5）会挤占
        // 常驻配额且绕过「剧情提及才注入」的检索语义
        importance: 3,
        createdTurn: 0,
        createdAt: DateTime.now(),
        source: FactualSource.card,
        sourceRef: cardId,
      );
      await _repository.createEntity(entity);
      count++;

      // 基线属性是实体的附属投影，不计数——
      // 此前「已应用 3 个实体」实际只有 1 个实体，与取消应用的计数不对称
      if (card.description.isNotEmpty) {
        await _createBaselineAttr(
          entityId: entity.entityId,
          sessionId: sessionId,
          attrKey: 'background',
          value: card.description,
          source: FactualSource.card,
        );
      }
      if (card.personality.isNotEmpty) {
        await _createBaselineAttr(
          entityId: entity.entityId,
          sessionId: sessionId,
          attrKey: 'personality',
          value: card.personality,
          source: FactualSource.card,
        );
      }

      occupiedNames.add(primaryName);

      // 内嵌世界书 → lore 实体（source=worldbook，sourceRef=cardId）
      for (final entry in card.embeddedEntries) {
        if (!entry.enabled) continue;
        if (await _projectWorldEntry(
          sessionId: sessionId,
          sourceRef: cardId,
          entry: entry,
          occupiedNames: occupiedNames,
          defaultSettingName: defaultSettingName ?? defaultCharacterName,
        )) {
          count++;
        }
      }

      return count;
    });
  }

  /// 应用世界书：投影若干 lore 实体。
  ///
  /// 返回投影的实体数（停用词条与同名重复词条跳过）。
  Future<int> applyWorldbook({
    required String sessionId,
    required String bookId,
    required List<NormalizedWorldEntry> entries,
    required String defaultSettingName,
  }) {
    return _repository.runInTransaction(() async {
      var count = 0;
      // 占用名称一次加载（仅活跃实体），逐词条判断避免每词条全表拉取
      final occupiedNames = await _loadOccupiedNames(sessionId);
      for (final entry in entries) {
        if (!entry.enabled) continue;
        if (await _projectWorldEntry(
          sessionId: sessionId,
          sourceRef: bookId,
          entry: entry,
          occupiedNames: occupiedNames,
          defaultSettingName: defaultSettingName,
        )) {
          count++;
        }
      }
      return count;
    });
  }

  /// 会话内已占用的名称集合（主名 + 别名，仅【活跃】实体）。
  ///
  /// （根治）：主名唯一索引改 partial（WHERE is_archived=0），
  /// 语义统一「归档让名」——撞归档名正常创建，仅活跃同名视为占用
  ///（沿用  的防裸异常目标，占用口径收窄到活跃行）。
  Future<Set<String>> _loadOccupiedNames(String sessionId) async {
    final entities = await _repository.getEntities(sessionId);
    return {
      for (final e in entities) ...[e.primaryName, ...e.aliases],
    };
  }

  /// 投影单条世界书词条为 lore 只读实体。同名已存在则跳过（返回 false）。
  Future<bool> _projectWorldEntry({
    required String sessionId,
    required String sourceRef,
    required NormalizedWorldEntry entry,
    required Set<String> occupiedNames,
    required String defaultSettingName,
  }) async {
    final primaryName = entry.keys.isNotEmpty
        ? entry.keys.first
        : (entry.comment.isNotEmpty ? entry.comment : defaultSettingName);

    // 去重：同名（主名或别名，活跃实体）已存在 → 跳过（不重复创建）；
    // 撞归档名不跳过（归档让名）
    if (occupiedNames.contains(primaryName)) return false;

    final entity = FactualEntity(
      entityId: 'ent_${_uuid.v4()}',
      sessionId: sessionId,
      type: FactualEntityType.lore,
      primaryName: primaryName,
      aliases: [...entry.keys.skip(1), ...entry.secondaryKeys],
      importance: 2,
      forceInject:
          entry.constant ? ForceInjectTarget.world : ForceInjectTarget.none,
      createdTurn: 0,
      createdAt: DateTime.now(),
      source: FactualSource.worldbook,
      sourceRef: sourceRef,
    );
    await _repository.createEntity(entity);

    if (entry.content.isNotEmpty) {
      await _createBaselineAttr(
        entityId: entity.entityId,
        sessionId: sessionId,
        attrKey: 'description',
        value: entry.content,
        source: FactualSource.worldbook,
      );
    }

    // 全文索引（世界书词条检索，DOC-15 §7.3）
    await _repository.insertFactualFts(
      entityId: entity.entityId,
      sessionId: sessionId,
      primaryName: entity.primaryName,
      aliases: entity.aliases,
      description: entry.content,
    );
    // 新投影的名称（主名+别名）即刻计入占用集，防同书内重复词条
    occupiedNames
      ..add(entity.primaryName)
      ..addAll(entity.aliases);
    return true;
  }

  /// 创建只读基线属性（single，source 区分，不写历史）
  Future<void> _createBaselineAttr({
    required String entityId,
    required String sessionId,
    required String attrKey,
    required String value,
    required FactualSource source,
  }) async {
    final attr = FactualAttribute(
      attributeId: 'attr_${_uuid.v4()}',
      entityId: entityId,
      sessionId: sessionId,
      attrKey: attrKey,
      value: value,
      importance: _baselineImportance(attrKey),
      createdAt: DateTime.now(),
      source: source,
    );
    await _repository.createAttribute(attr);
  }

  /// 描述性基线属性重要性（personality/background/description = 4）
  int _baselineImportance(String attrKey) {
    switch (attrKey) {
      case 'personality':
      case 'background':
      case 'description':
        return 4;
      default:
        return 3;
    }
  }
}
