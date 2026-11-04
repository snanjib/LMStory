import 'package:lmstory/features/memory/domain/entities/factual_attribute.dart';
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
import 'package:lmstory/features/memory/domain/services/fact_applier.dart';

// =============================================================================
// 从 factual_memory_tab.dart 拆出的纯计算辅助（逐字符搬运，不重构）：
// 列表过滤排序与相似实体聚类。放最底层共享文件，主文件与子件共用；
// 子文件之间单向依赖，禁止回 import 主文件。
// =============================================================================

/// 过滤 + 排序（原 _FactualMemoryTabState._filteredEntities getter 主体）。
///
/// 步骤：搜索（实体名/别名/分类/属性键值）→ 类型单选 → 重要性单选 →
/// 归档状态单选 → 排序（0=重要性降序，1=名称升序，2=创建时间降序）。
/// 各筛选参数取值口径见 State 字段注释。
List<FactualEntity> factualFilterAndSortEntities({
  required List<FactualEntity> allEntities,
  required String searchQuery,
  required int typeFilter,
  required int importanceFilter,
  required int archiveFilter,
  required int sortBy,
  required Map<String, List<FactualAttribute>> attributesByEntity,
}) {
  var entities = allEntities;

  // 1. 搜索过滤（实体名 + 别名 + 分类 + 属性键/值）
  if (searchQuery.isNotEmpty) {
    final query = searchQuery.toLowerCase();
    entities = entities.where((e) {
      if (e.primaryName.toLowerCase().contains(query)) return true;
      if (e.aliases.any((a) => a.toLowerCase().contains(query))) return true;
      if (e.category?.toLowerCase().contains(query) ?? false) return true;
      // 搜索属性值
      final attrs = attributesByEntity[e.entityId] ?? const [];
      for (final attr in attrs) {
        if (attr.attrKey.toLowerCase().contains(query)) return true;
        if (attr.value.toLowerCase().contains(query)) return true;
      }
      return false;
    }).toList();
  }

  // 2. 实体类型筛选（单选）
  if (typeFilter > 0) {
    const typeMap = {
      1: FactualEntityType.character,
      2: FactualEntityType.location,
      3: FactualEntityType.item,
      4: FactualEntityType.lore,
      5: FactualEntityType.organization,
      6: FactualEntityType.misc,
    };
    final selectedType = typeMap[typeFilter]!;
    entities = entities.where((e) => e.type == selectedType).toList();
  }

  // 3. 重要性筛选（单选）
  if (importanceFilter == 1) {
    // 关键（importance >= 4）
    entities = entities.where((e) => e.importance >= 4).toList();
  } else if (importanceFilter == 2) {
    // 普通（importance <= 3）
    entities = entities.where((e) => e.importance <= 3).toList();
  }

  // 4. 归档状态筛选（单选）
  if (archiveFilter == 1) {
    // 活跃
    entities = entities.where((e) => !e.isArchived).toList();
  } else if (archiveFilter == 2) {
    // 已归档
    entities = entities.where((e) => e.isArchived).toList();
  }

  // 5. 排序
  switch (sortBy) {
    case 1:
      // 按名称升序
      entities.sort(
        (a, b) =>
            a.primaryName.toLowerCase().compareTo(b.primaryName.toLowerCase()),
      );
    case 2:
      // 按创建时间降序
      entities.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    default:
      // 0：按重要性降序（默认）
      entities.sort((a, b) => b.importance.compareTo(a.importance));
  }

  return entities;
}

/// 活跃实体按 isNameContainmentSimilar 两两包含聚成连通分量（原
/// _FactualMemoryTabState._similarClusters，纯客户端，O(n²) 只在点击时
/// 执行；口径与 applier 创建侧疑似重复警告一致）
List<List<FactualEntity>> factualSimilarClusters(
  List<FactualEntity> allEntities,
) {
  final entities =
      allEntities.where((e) => !e.isArchived).toList(growable: false);
  final parent = List<int>.generate(entities.length, (i) => i);

  int find(int i) {
    var root = i;
    while (parent[root] != root) {
      parent[root] = parent[parent[root]];
      root = parent[root];
    }
    return root;
  }

  void union(int a, int b) {
    final ra = find(a);
    final rb = find(b);
    if (ra != rb) parent[ra] = rb;
  }

  for (var i = 0; i < entities.length; i++) {
    for (var j = i + 1; j < entities.length; j++) {
      if (FactApplier.isNameContainmentSimilar(
        entities[i].primaryName,
        entities[j].primaryName,
      )) {
        union(i, j);
      }
    }
  }

  final byRoot = <int, List<FactualEntity>>{};
  for (var i = 0; i < entities.length; i++) {
    byRoot.putIfAbsent(find(i), () => []).add(entities[i]);
  }
  return byRoot.values.where((g) => g.length >= 2).toList()
    ..sort((a, b) => b.length.compareTo(a.length));
}
