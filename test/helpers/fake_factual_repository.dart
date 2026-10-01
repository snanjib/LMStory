import 'package:lmstory/features/memory/domain/entities/factual_attribute.dart';
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
import 'package:lmstory/features/memory/domain/entities/factual_memory_history.dart';
import 'package:lmstory/features/memory/domain/entities/factual_source.dart';
import 'package:lmstory/features/memory/domain/entities/force_inject_target.dart';
import 'package:lmstory/features/memory/domain/repositories/factual_repository.dart';

/// 测试用 [FactualRepository] 内存实现（FactApplier / FactContextBuilder 共用）
///
/// 设计目标：
/// - 测试中无需 mockito codegen，直接 setFakeState 后即可断言
/// - 字段命名按"输入 vs 输出"区分：
///   - 输入字段（Fake 返回的数据）：`entitiesById` / `entitiesByName` /
///     `attributesByKey` / `recentUpdateCounts` / `keyEntitiesOverride`
///   - 输出字段（Fake 记录的调用）：`createdEntities` / `createdAttributes` /
///     `updatedAttributes` / `updatedAliases` / `archivedEntities` / `histories`
///
/// v36（DOC-15 §8.1）：`attributesByKey` 支持同 (entityId, attrKey) 多行
/// （只读基线 + auto 演变并存），值为 List<FactualAttribute>。
class FakeFactualRepository implements FactualRepository {
  // ─── 输入：测试预设状态 ────────────────────────────────────────────────
  Map<String, FactualEntity> entitiesById = {};
  List<FactualEntity> entitiesByName = const [];
  Map<(String, String), List<FactualAttribute>> attributesByKey = {};
  Map<String, int> recentUpdateCounts = {};
  List<FactualEntity>? keyEntitiesOverride;

  /// 控制是否在 getKeyEntities 时抛异常（用于测试失败降级）
  Exception? getKeyEntitiesException;

  // ─── 输出：调用记录 ────────────────────────────────────────────────────
  final List<FactualEntity> createdEntities = [];
  final List<FactualAttribute> createdAttributes = [];
  final Map<String, String> updatedAttributes = {}; // attrId → newValue
  final Map<String, List<String>> updatedAliases = {}; // entityId → aliases
  final Map<String, String> archivedEntities = {}; // entityId → reason
  final List<FactualMemoryHistory> histories = [];
  final List<({String sessionId, int fromTurn})> deletedFactsByTurnsCalls = [];
  final Map<String, ForceInjectTarget> forceInjectUpdates = {};

  /// searchEntitiesByText 调用记录（可达性兜底测试断言用）
  final List<({List<String> terms, bool includeArchived})> searchTextCalls = [];

  /// 便捷播种：追加一条属性到 attributesByKey（支持多行）
  void seedAttribute(FactualAttribute attr) {
    attributesByKey
        .putIfAbsent((attr.entityId, attr.attrKey), () => []).add(attr);
  }

  @override
  Future<int> countRecentUpdates(
    String entityId, {
    required int fromTurn,
  }) async =>
      recentUpdateCounts[entityId] ?? 0;

  @override
  Future<FactualEntity> createEntity(FactualEntity entity) async {
    createdEntities.add(entity);
    entitiesById[entity.entityId] = entity;
    return entity;
  }

  @override
  Future<FactualAttribute> createAttribute(FactualAttribute attribute) async {
    createdAttributes.add(attribute);
    seedAttribute(attribute);
    return attribute;
  }

  @override
  Future<void> archiveEntity(String entityId, String reason, int turn) async {
    archivedEntities[entityId] = reason;
  }

  @override
  Future<void> deleteAllFacts(String sessionId) async {}

  @override
  Future<void> deleteFactsByTurns({
    required String sessionId,
    required int fromTurn,
  }) async {
    deletedFactsByTurnsCalls.add((sessionId: sessionId, fromTurn: fromTurn));
  }

  @override
  Future<T> runInTransaction<T>(Future<T> Function() action) => action();

  // ─── FTS5 索引 ───────────────────────────────────────────────────────
  final List<({String entityId, String primaryName, String description})>
      factualFtsEntries = [];

  /// deleteFactualFts 调用记录（entityId 顺序；断言「先删后插」重建用）
  final List<String> deletedFactualFtsEntityIds = [];

  @override
  Future<void> insertFactualFts({
    required String entityId,
    required String sessionId,
    required String primaryName,
    required List<String> aliases,
    required String description,
  }) async {
    factualFtsEntries.add(
      (entityId: entityId, primaryName: primaryName, description: description),
    );
  }

  @override
  Future<void> deleteFactualFts(String entityId) async {
    deletedFactualFtsEntityIds.add(entityId);
    factualFtsEntries.removeWhere((e) => e.entityId == entityId);
  }

  @override
  Future<void> rebuildEntityFts(String entityId) async {
    // 与真实现同语义：先删后插；仅 worldbook 落索引；description 取
    // 首条（基线优先，attributesByKey 按插入序模拟 rowid 序）。
    await deleteFactualFts(entityId);
    final entity = entitiesById[entityId];
    if (entity == null || entity.source != FactualSource.worldbook) return;
    final rows = attributesByKey[(entityId, 'description')] ??
        const <FactualAttribute>[];
    factualFtsEntries.add(
      (
        entityId: entityId,
        primaryName: entity.primaryName,
        description: rows.isEmpty ? '' : rows.first.value,
      ),
    );
  }

  @override
  Future<void> deleteAllFactualFts(String sessionId) async {}

  @override
  Future<List<FactualEntity>> searchWorldFacts(
    String sessionId,
    List<String> terms, {
    int limit = 20,
    bool excludeInjectionDisabled = false,
  }) async {
    // 模拟 FTS：primaryName 或 description 命中 terms 即召回
    final matchedIds = factualFtsEntries
        .where(
          (e) => terms.any(
            (t) => e.primaryName.contains(t) || e.description.contains(t),
          ),
        )
        .map((e) => e.entityId)
        .toSet();
    var hits = entitiesById.values
        .where((e) => matchedIds.contains(e.entityId))
        .take(limit)
        .toList();
    if (excludeInjectionDisabled) {
      hits = hits.where((e) => !e.injectionDisabled).toList();
    }
    return hits;
  }

  @override
  Future<List<FactualEntity>> findByName(
    String sessionId,
    List<String> names, {
    bool excludeInjectionDisabled = false,
  }) async {
    final List<FactualEntity> matches;
    if (entitiesByName.isNotEmpty) {
      matches = entitiesByName
          .where(
            (e) =>
                names.contains(e.primaryName) || e.aliases.any(names.contains),
          )
          .toList();
    } else {
      // 默认从 entitiesById 查
      matches = entitiesById.values
          .where(
            (e) =>
                names.contains(e.primaryName) || e.aliases.any(names.contains),
          )
          .toList();
    }
    if (excludeInjectionDisabled) {
      return matches.where((e) => !e.injectionDisabled).toList();
    }
    return matches;
  }

  @override
  Future<List<FactualAttribute>> getAttributesByKey(
    String entityId,
    String attrKey,
  ) async =>
      attributesByKey[(entityId, attrKey)] ?? const [];

  @override
  Future<List<FactualEntity>> searchEntitiesByText(
    String sessionId,
    List<String> terms, {
    int limit = 10,
    bool includeArchived = false,
    bool excludeInjectionDisabled = false,
  }) async {
    searchTextCalls
        .add((terms: List.of(terms), includeArchived: includeArchived));
    if (terms.isEmpty) return const [];
    final hits = <FactualEntity>[];
    for (final entity in entitiesById.values) {
      if (!includeArchived && entity.isArchived) continue;
      if (excludeInjectionDisabled && entity.injectionDisabled) continue;
      final attrValues = attributesByKey.entries
          .where((e) => e.key.$1 == entity.entityId)
          .expand((e) => e.value)
          .map((a) => a.value);
      final haystack = <String>[
        entity.primaryName,
        ...entity.aliases,
        ...attrValues,
      ];
      if (terms.any((t) => haystack.any((v) => v.contains(t)))) {
        hits.add(entity);
      }
    }
    hits.sort((a, b) => b.importance.compareTo(a.importance));
    return hits.take(limit).toList();
  }

  @override
  Future<List<FactualAttribute>> getAttributes(
    String sessionId,
    List<String> entityIds,
  ) async =>
      attributesByKey.values
          .expand((list) => list)
          .where((a) => entityIds.contains(a.entityId))
          .toList();

  @override
  Future<List<FactualEntity>> getEntities(
    String sessionId, {
    bool includeArchived = false,
  }) async =>
      includeArchived
          ? entitiesById.values.toList()
          : entitiesById.values.where((e) => !e.isArchived).toList();

  @override
  Future<FactualEntity?> getEntityById(String entityId) async =>
      entitiesById[entityId];

  @override
  Future<List<FactualEntity>> getKeyEntities(
    String sessionId,
    int minImportance, {
    bool includeForceInject = false,
    bool excludeInjectionDisabled = false,
  }) async {
    if (getKeyEntitiesException != null) {
      await Future<void>.delayed(Duration.zero); // 模拟异步
      throw getKeyEntitiesException!;
    }
    final List<FactualEntity> result;
    if (keyEntitiesOverride != null) {
      result = keyEntitiesOverride!;
    } else {
      result = entitiesById.values
          .where((e) => !e.isArchived && e.importance >= minImportance)
          .toList();
    }
    if (excludeInjectionDisabled) {
      return result.where((e) => !e.injectionDisabled).toList();
    }
    return result;
  }

  @override
  Future<void> insertHistory(FactualMemoryHistory history) async {
    histories.add(history);
  }

  @override
  Future<void> updateAttributeValue(
    String attributeId,
    String newValue,
    int updatedTurn,
    String? updateReason,
  ) async {
    updatedAttributes[attributeId] = newValue;
    // 同步写回 attributesByKey：真实现落库后
    // rebuildEntityFts 从主表读新值，fake 必须同语义，否则重建取到旧值。
    for (final entry in attributesByKey.entries) {
      final list = entry.value;
      for (var i = 0; i < list.length; i++) {
        if (list[i].attributeId == attributeId) {
          final old = list[i];
          list[i] = FactualAttribute(
            attributeId: old.attributeId,
            entityId: old.entityId,
            sessionId: old.sessionId,
            attrKey: old.attrKey,
            value: newValue,
            valueType: old.valueType,
            importance: old.importance,
            createdAt: old.createdAt,
            source: old.source,
            updatedAt: old.updatedAt,
            updatedTurn: old.updatedTurn,
            updateReason: old.updateReason,
          );
          return;
        }
      }
    }
  }

  @override
  Future<void> updateEntityAliases(
    String entityId,
    List<String> aliases,
    int updatedTurn,
  ) async {
    updatedAliases[entityId] = aliases;
  }

  @override
  Future<List<FactualMemoryHistory>> getHistory(String entityId) async =>
      histories.where((h) => h.entityId == entityId).toList();

  // ─── 记忆查看器 CRUD（2026-07-22 新增）───────────────────────────────

  @override
  Future<void> deleteEntityById(String entityId) async {
    entitiesById.remove(entityId);
    attributesByKey.removeWhere((key, _) => key.$1 == entityId);
    histories.removeWhere((h) => h.entityId == entityId);
  }

  @override
  Future<int> deleteEntitiesBySourceRef(
    String sessionId,
    String sourceRef,
  ) async {
    final ids = entitiesById.values
        .where((e) => e.sessionId == sessionId && e.sourceRef == sourceRef)
        .map((e) => e.entityId)
        .toList();
    for (final id in ids) {
      await deleteEntityById(id);
    }
    return ids.length;
  }

  @override
  Future<void> deleteAttributeById(String attributeId) async {
    attributesByKey
      ..updateAll(
        (_, list) => list.where((a) => a.attributeId != attributeId).toList(),
      )
      ..removeWhere((_, list) => list.isEmpty);
  }

  @override
  Future<void> updateEntityBasic({
    required String entityId,
    String? primaryName,
    FactualEntityType? type,
    int? importance,
    String? category,
    bool? isArchived,
    int? updatedTurn,
  }) async {
    final entity = entitiesById[entityId];
    if (entity == null) return;
    entitiesById[entityId] = FactualEntity(
      entityId: entity.entityId,
      sessionId: entity.sessionId,
      type: type ?? entity.type,
      primaryName: primaryName ?? entity.primaryName,
      aliases: entity.aliases,
      importance: importance ?? entity.importance,
      createdTurn: entity.createdTurn,
      createdAt: entity.createdAt,
      category: category ?? entity.category,
      isArchived: isArchived ?? entity.isArchived,
      source: entity.source,
      sourceRef: entity.sourceRef,
      forceInject: entity.forceInject,
      updatedAt: DateTime.now(),
      updatedTurn: updatedTurn ?? entity.updatedTurn,
    );
  }

  @override
  Future<void> updateEntityForceInject(
    String entityId,
    ForceInjectTarget target,
  ) async {
    final entity = entitiesById[entityId];
    if (entity == null) return;
    entitiesById[entityId] = FactualEntity(
      entityId: entity.entityId,
      sessionId: entity.sessionId,
      type: entity.type,
      primaryName: entity.primaryName,
      aliases: entity.aliases,
      importance: entity.importance,
      createdTurn: entity.createdTurn,
      createdAt: entity.createdAt,
      category: entity.category,
      isArchived: entity.isArchived,
      source: entity.source,
      sourceRef: entity.sourceRef,
      forceInject: target,
      updatedAt: entity.updatedAt,
      updatedTurn: entity.updatedTurn,
    );
    forceInjectUpdates[entityId] = target;
  }

  @override
  Future<void> batchUpdateForceInject(
    List<String> entityIds,
    ForceInjectTarget target,
  ) async {
    for (final id in entityIds) {
      await updateEntityForceInject(id, target);
    }
  }

  @override
  Future<void> batchUpdateInjectionDisabled(
    List<String> entityIds, {
    required bool disabled,
  }) async {
    for (final id in entityIds) {
      final e = entitiesById[id];
      if (e != null) {
        entitiesById[id] = FactualEntity(
          entityId: e.entityId,
          sessionId: e.sessionId,
          type: e.type,
          primaryName: e.primaryName,
          aliases: e.aliases,
          importance: e.importance,
          createdTurn: e.createdTurn,
          createdAt: e.createdAt,
          category: e.category,
          isArchived: e.isArchived,
          source: e.source,
          sourceRef: e.sourceRef,
          forceInject: e.forceInject,
          injectionDisabled: disabled,
          updatedAt: e.updatedAt,
          updatedTurn: e.updatedTurn,
        );
      }
    }
  }
}
