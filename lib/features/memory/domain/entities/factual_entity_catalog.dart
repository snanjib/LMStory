import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
import 'package:meta/meta.dart';

/// 事实层目录分页条目（供 `list_facts` 等目录浏览消费）。
@immutable
class FactualEntityCatalogItem {
  const FactualEntityCatalogItem({
    required this.entity,
    required this.attributeCount,
  });

  final FactualEntity entity;

  /// 该实体在 `factual_attributes` 中的属性行数。
  final int attributeCount;

  /// 该实体的别名数量。
  int get aliasCount => entity.aliases.length;
}

/// 全会话事实库分布统计头（不随分页/过滤条件缩放）。
@immutable
class FactualEntityCatalogSummary {
  const FactualEntityCatalogSummary({
    required this.activeCount,
    required this.archivedCount,
    required this.dynamicCount,
    required this.staticWorldbookCount,
    required this.staticCardCount,
    required this.typeCounts,
  });

  /// 活跃实体总数（`!isArchived`）。
  final int activeCount;

  /// 已归档实体总数（`isArchived`）。
  final int archivedCount;

  /// 活跃动态实体数（`!isArchived && (source == auto || updatedTurn != null)`）。
  final int dynamicCount;

  /// 未演化的静态世界书导入实体数（`!isArchived && source == worldbook && updatedTurn == null`）。
  final int staticWorldbookCount;

  /// 未演化的静态角色卡导入实体数（`!isArchived && source == card && updatedTurn == null`）。
  final int staticCardCount;

  /// 活跃实体按 [FactualEntityType] 的分布计数。
  final Map<FactualEntityType, int> typeCounts;

  /// 全库实体总数（活跃 + 归档）。
  int get totalCount => activeCount + archivedCount;
}

/// `FactualRepository.listEntityCatalog` 的分页返回对象。
@immutable
class FactualEntityCatalogPage {
  const FactualEntityCatalogPage({
    required this.items,
    required this.totalMatched,
    required this.limit,
    required this.offset,
    required this.summary,
  });

  final List<FactualEntityCatalogItem> items;

  /// 符合当前筛选条件的总实体数（用于分页判断）。
  final int totalMatched;

  /// 实际生效的单页条数上限（已钳制在 `1..50`）。
  final int limit;

  /// 实际生效的偏移量。
  final int offset;

  /// 全会话紧凑统计头。
  final FactualEntityCatalogSummary summary;

  /// 是否还有下一页。
  bool get hasMore => offset + items.length < totalMatched;
}
