import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:lmstory/core/exceptions/app_exceptions.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/memory/data/repositories/memory_fts_rebuilder.dart';
import 'package:lmstory/features/memory/domain/entities/facts_delta.dart';
import 'package:lmstory/features/memory/domain/entities/factual_attribute.dart';
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
import 'package:lmstory/features/memory/domain/entities/factual_memory_changes_snapshot.dart';
import 'package:lmstory/features/memory/domain/entities/factual_memory_history.dart';
import 'package:lmstory/features/memory/domain/entities/factual_source.dart';
import 'package:lmstory/features/memory/domain/entities/force_inject_target.dart';
import 'package:lmstory/features/memory/domain/repositories/factual_repository.dart';
import 'package:lmstory/features/memory/domain/services/memory_query.dart';
import 'package:lmstory/i18n/strings.g.dart';
import 'package:uuid/uuid.dart';

/// FactualRepository 实现（Data 层，DOC-11 §11.1）
///
/// 纯数据存取实现：CRUD + 审计日志写入 + 清理。**不包含**业务逻辑
/// （三重防护、5 层健康度防护、消歧等在 FactApplier 服务内）。
///
/// 所有写方法**不开自身事务**，供 FactApplier / StoryPersistenceService
/// 在外层 drift transaction 内调用以保证原子性（与经历层 persisting 同事务，
/// DOC-11 §8.2）。
///
/// 例外：[deleteAllFacts] 开自身事务（用于会话删除/重建场景）。
class FactualRepositoryImpl implements FactualRepository {
  FactualRepositoryImpl({required AppDatabase database}) : _database = database;

  final AppDatabase _database;
  final _uuid = const Uuid();
  final _logger = const Logger('FactualRepository');

  // ==================== 实体查询 ====================

  @override
  Future<List<FactualEntity>> getEntities(
    String sessionId, {
    bool includeArchived = false,
  }) async {
    final query = _database.select(_database.factualEntitiesTable)
      ..where((t) {
        var condition = t.sessionId.equals(sessionId);
        if (!includeArchived) {
          condition = condition & t.isArchived.equals(false);
        }
        return condition;
      })
      ..orderBy([
        (t) => OrderingTerm(expression: t.importance, mode: OrderingMode.desc),
        (t) => OrderingTerm(expression: t.createdAt),
      ]);
    final rows = await query.get();
    return rows.map(_entityFromTyped).toList();
  }

  @override
  Future<List<FactualEntity>> getKeyEntities(
    String sessionId,
    int minImportance, {
    bool includeForceInject = false,
    bool excludeInjectionDisabled = false,
  }) async {
    final query = _database.select(_database.factualEntitiesTable)
      ..where((t) {
        var condition = t.sessionId.equals(sessionId) &
            t.isArchived.equals(false) &
            (includeForceInject
                ? (t.importance.isBiggerOrEqualValue(minImportance) |
                    t.forceInject.equals('none').not())
                : t.importance.isBiggerOrEqualValue(minImportance));
        // （批 J-b 漏桶收口）：注入面剔除停用词条
        if (excludeInjectionDisabled) {
          condition = condition & t.injectionDisabled.equals(false);
        }
        return condition;
      })
      ..orderBy([
        (t) => OrderingTerm(expression: t.importance, mode: OrderingMode.desc),
        (t) => OrderingTerm(expression: t.createdAt),
      ]);
    final rows = await query.get();
    return rows.map(_entityFromTyped).toList();
  }

  @override
  Future<List<FactualEntity>> findByName(
    String sessionId,
    List<String> names, {
    bool excludeInjectionDisabled = false,
  }) async {
    if (names.isEmpty) return const [];

    // primaryName 精确匹配
    final primaryMatches = await (_database.select(
      _database.factualEntitiesTable,
    )..where(
            (t) {
              var condition = t.sessionId.equals(sessionId) &
                  t.primaryName.isIn(names) &
                  t.isArchived.equals(false);
              // （批 J-b 漏桶收口）：注入面剔除停用词条
              if (excludeInjectionDisabled) {
                condition = condition & t.injectionDisabled.equals(false);
              }
              return condition;
            },
          ))
        .get();

    // aliases 包含匹配（内存过滤，drift 不直接支持 JSON 数组查询）
    final allEntities = await (_database.select(_database.factualEntitiesTable)
          ..where(
            (t) {
              var condition =
                  t.sessionId.equals(sessionId) & t.isArchived.equals(false);
              // 停用词条的别名命中同样剔除（别名派生泄漏）
              if (excludeInjectionDisabled) {
                condition = condition & t.injectionDisabled.equals(false);
              }
              return condition;
            },
          ))
        .get();
    final aliasMatches = allEntities
        .where((row) {
          final aliases = _parseAliases(row.aliases);
          return aliases.any(names.contains);
        })
        .where(
          (row) => !primaryMatches.any((p) => p.entityId == row.entityId),
        )
        .toList();

    final allMatches = [...primaryMatches, ...aliasMatches];
    return allMatches.map(_entityFromTyped).toList();
  }

  @override
  Future<List<FactualEntity>> searchEntitiesByText(
    String sessionId,
    List<String> terms, {
    int limit = 10,
    bool includeArchived = false,
    bool excludeInjectionDisabled = false,
  }) async {
    // 去空去重保序（词元切分由调用方经 MemoryQuery 完成；此处防御裸传）
    final cleaned = <String>[];
    for (final term in terms) {
      final trimmed = term.trim();
      if (trimmed.isEmpty || cleaned.contains(trimmed)) continue;
      cleaned.add(trimmed);
    }
    if (cleaned.isEmpty) return const [];

    final query = _database.select(_database.factualEntitiesTable)
      ..where((t) {
        var condition = t.sessionId.equals(sessionId);
        if (!includeArchived) {
          condition = condition & t.isArchived.equals(false);
        }
        if (excludeInjectionDisabled) {
          condition = condition & t.injectionDisabled.equals(false);
        }
        Expression<bool>? anyTerm;
        for (final term in cleaned) {
          final pattern = Variable.withString(
            '%${MemoryQuery.escapeLike(term)}%',
          );
          Expression<bool> like(Expression<String> column) => column.likeExp(
                pattern,
                escape: const Constant<String>(r'\'),
              );
          final attrExists = existsQuery(
            _database.selectOnly(_database.factualAttributesTable)
              ..addColumns([_database.factualAttributesTable.attributeId])
              ..where(
                _database.factualAttributesTable.entityId
                        .equalsExp(t.entityId) &
                    like(_database.factualAttributesTable.value),
              ),
          );
          final match = like(t.primaryName) | like(t.aliases) | attrExists;
          anyTerm = anyTerm == null ? match : anyTerm | match;
        }
        return condition & anyTerm!;
      })
      ..orderBy([
        (t) => OrderingTerm(expression: t.importance, mode: OrderingMode.desc),
        // SQLite 视 NULL 为最小 → DESC 自动把未更新过的行排在后面
        (t) => OrderingTerm(expression: t.updatedAt, mode: OrderingMode.desc),
        (t) => OrderingTerm(expression: t.createdAt),
      ])
      ..limit(limit);
    final rows = await query.get();
    return rows.map(_entityFromTyped).toList();
  }

  @override
  Future<FactualEntity?> getEntityById(String entityId) async {
    final rows = await (_database.select(_database.factualEntitiesTable)
          ..where((t) => t.entityId.equals(entityId)))
        .get();
    return rows.isEmpty ? null : _entityFromTyped(rows.first);
  }

  @override
  Future<List<FactualEntity>> getEntitiesByIds(
    String sessionId,
    List<String> entityIds,
  ) async {
    if (entityIds.isEmpty) return const [];
    final seen = <String>{};
    final orderedIds = <String>[
      for (final id in entityIds)
        if (id.isNotEmpty && seen.add(id)) id,
    ];
    if (orderedIds.isEmpty) return const [];
    final rows = await (_database.select(_database.factualEntitiesTable)
          ..where(
            (t) => t.sessionId.equals(sessionId) & t.entityId.isIn(orderedIds),
          ))
        .get();
    final byId = {for (final row in rows) row.entityId: _entityFromTyped(row)};
    return [
      for (final id in orderedIds)
        if (byId[id] case final entity?) entity,
    ];
  }

  @override
  Future<FactualEntityCatalogPage> listEntityCatalog(
    String sessionId, {
    FactualEntityType? entityType,
    String sourceFilter = 'dynamic',
    String sort = 'stale_first',
    int? updatedBeforeTurn,
    int? updatedAfterTurn,
    bool includeArchived = false,
    int limit = 25,
    int offset = 0,
  }) async {
    if (sourceFilter != 'dynamic' &&
        sourceFilter != 'auto' &&
        sourceFilter != 'worldbook' &&
        sourceFilter != 'card' &&
        sourceFilter != 'all') {
      throw ArgumentError.value(
        sourceFilter,
        'sourceFilter',
        '未知的 sourceFilter，仅支持 dynamic/auto/worldbook/card/all',
      );
    }
    if (sort != 'stale_first' &&
        sort != 'recently_updated' &&
        sort != 'importance_desc' &&
        sort != 'created_desc') {
      throw ArgumentError.value(
        sort,
        'sort',
        '未知的 sort，仅支持 stale_first/recently_updated/importance_desc/created_desc',
      );
    }
    final effectiveLimit = limit.clamp(1, 50);
    final effectiveOffset = offset < 0 ? 0 : offset;

    return _database.transaction(() async {
      final entitiesTable = _database.factualEntitiesTable;
      final summaryRows = await (_database.selectOnly(entitiesTable)
            ..addColumns([
              entitiesTable.type,
              entitiesTable.isArchived,
              entitiesTable.source,
              entitiesTable.updatedTurn,
            ])
            ..where(entitiesTable.sessionId.equals(sessionId)))
          .get();

      var activeCount = 0;
      var archivedCount = 0;
      var dynamicCount = 0;
      var staticWorldbookCount = 0;
      var staticCardCount = 0;
      final typeCounts = <FactualEntityType, int>{
        for (final type in FactualEntityType.values) type: 0,
      };
      for (final row in summaryRows) {
        final isArchived = row.read(entitiesTable.isArchived) ?? false;
        if (isArchived) {
          archivedCount++;
          continue;
        }
        activeCount++;
        final type = FactualEntityType.fromString(
          row.read(entitiesTable.type) ?? '',
        );
        typeCounts[type] = (typeCounts[type] ?? 0) + 1;
        final source = FactualSource.fromString(
          row.read(entitiesTable.source) ?? 'auto',
        );
        final updatedTurn = row.read(entitiesTable.updatedTurn);
        if (source == FactualSource.auto || updatedTurn != null) {
          dynamicCount++;
        } else if (source == FactualSource.worldbook) {
          staticWorldbookCount++;
        } else if (source == FactualSource.card) {
          staticCardCount++;
        }
      }

      Expression<bool> buildCondition($FactualEntitiesTableTable t) {
        var condition = t.sessionId.equals(sessionId);
        if (!includeArchived) {
          condition = condition & t.isArchived.equals(false);
        }
        if (entityType != null) {
          condition = condition & t.type.equals(entityType.toDbString());
        }
        switch (sourceFilter) {
          case 'dynamic':
            condition = condition &
                (t.source.equals('auto') | t.updatedTurn.isNotNull());
          case 'auto':
            condition = condition & t.source.equals('auto');
          case 'worldbook':
            condition = condition & t.source.equals('worldbook');
          case 'card':
            condition = condition & t.source.equals('card');
          case 'all':
            break;
        }
        final effectiveTurn = coalesce<int>([t.updatedTurn, t.createdTurn]);
        if (updatedBeforeTurn != null) {
          condition =
              condition & effectiveTurn.isSmallerThanValue(updatedBeforeTurn);
        }
        if (updatedAfterTurn != null) {
          condition =
              condition & effectiveTurn.isBiggerThanValue(updatedAfterTurn);
        }
        return condition;
      }

      final countExpr = entitiesTable.entityId.count();
      final totalMatchedRow = await (_database.selectOnly(entitiesTable)
            ..addColumns([countExpr])
            ..where(buildCondition(entitiesTable)))
          .getSingle();
      final totalMatched = totalMatchedRow.read(countExpr) ?? 0;

      final pagedQuery = _database.select(entitiesTable)
        ..where(buildCondition)
        ..orderBy([
          (t) {
            final effectiveTurn = coalesce<int>([t.updatedTurn, t.createdTurn]);
            return switch (sort) {
              'recently_updated' => OrderingTerm(
                  expression: effectiveTurn,
                  mode: OrderingMode.desc,
                ),
              'created_desc' => OrderingTerm(
                  expression: t.createdTurn,
                  mode: OrderingMode.desc,
                ),
              _ => OrderingTerm(
                  expression: t.importance,
                  mode: OrderingMode.desc,
                ),
            };
          },
          (t) {
            final effectiveTurn = coalesce<int>([t.updatedTurn, t.createdTurn]);
            return switch (sort) {
              'stale_first' => OrderingTerm(expression: effectiveTurn),
              'recently_updated' => OrderingTerm(
                  expression: t.updatedAt,
                  mode: OrderingMode.desc,
                ),
              'importance_desc' => OrderingTerm(
                  expression: effectiveTurn,
                  mode: OrderingMode.desc,
                ),
              'created_desc' => OrderingTerm(
                  expression: t.createdAt,
                  mode: OrderingMode.desc,
                ),
              _ => OrderingTerm(expression: effectiveTurn),
            };
          },
          (t) => switch (sort) {
                'recently_updated' => OrderingTerm(
                    expression: t.createdAt,
                    mode: OrderingMode.desc,
                  ),
                'created_desc' => OrderingTerm(expression: t.entityId),
                _ => OrderingTerm(expression: t.createdAt),
              },
          (t) => OrderingTerm(expression: t.entityId),
        ])
        ..limit(effectiveLimit, offset: effectiveOffset);
      final pagedRows = await pagedQuery.get();

      final attributeCounts = <String, int>{};
      if (pagedRows.isNotEmpty) {
        final pagedIds = pagedRows.map((row) => row.entityId).toList();
        final attrTable = _database.factualAttributesTable;
        final attrCountExpr = attrTable.attributeId.count();
        final countRows = await (_database.selectOnly(attrTable)
              ..addColumns([attrTable.entityId, attrCountExpr])
              ..where(
                attrTable.sessionId.equals(sessionId) &
                    attrTable.entityId.isIn(pagedIds),
              )
              ..groupBy([attrTable.entityId]))
            .get();
        for (final row in countRows) {
          final entityId = row.read(attrTable.entityId);
          final count = row.read(attrCountExpr) ?? 0;
          if (entityId != null) {
            attributeCounts[entityId] = count;
          }
        }
      }

      return FactualEntityCatalogPage(
        items: [
          for (final row in pagedRows)
            FactualEntityCatalogItem(
              entity: _entityFromTyped(row),
              attributeCount: attributeCounts[row.entityId] ?? 0,
            ),
        ],
        totalMatched: totalMatched,
        limit: effectiveLimit,
        offset: effectiveOffset,
        summary: FactualEntityCatalogSummary(
          activeCount: activeCount,
          archivedCount: archivedCount,
          dynamicCount: dynamicCount,
          staticWorldbookCount: staticWorldbookCount,
          staticCardCount: staticCardCount,
          typeCounts: typeCounts,
        ),
      );
    });
  }

  @override
  Future<FactualEntityType?> getEntityTypeInSession(
    String sessionId,
    String entityId,
  ) async {
    final table = _database.factualEntitiesTable;
    final row = await (_database.selectOnly(table)
          ..addColumns([table.type])
          ..where(
            table.entityId.equals(entityId) & table.sessionId.equals(sessionId),
          ))
        .getSingleOrNull();
    return FactualEntityType.tryFromString(row?.read(table.type));
  }

  // ==================== 实体写入 ====================

  @override
  Future<FactualEntity> createEntity(FactualEntity entity) async {
    await _database.into(_database.factualEntitiesTable).insert(
          FactualEntitiesTableCompanion.insert(
            entityId: entity.entityId,
            sessionId: entity.sessionId,
            type: entity.type.toDbString(),
            primaryName: entity.primaryName,
            aliases: Value(jsonEncode(entity.aliases)),
            importance: Value(entity.importance),
            createdTurn: entity.createdTurn,
            createdAt: Value(entity.createdAt),
            category: Value(entity.category),
            isArchived: Value(entity.isArchived),
            source: Value(entity.source.toDbString()),
            sourceRef: Value(entity.sourceRef),
            // createEntity 此前漏写 forceInject（常走列默认 none），
            // 世界书 constant 投影的常驻标记从未真正入库
            forceInject: Value(entity.forceInject.toDbString()),
            injectionDisabled: Value(entity.injectionDisabled),
          ),
        );
    return entity;
  }

  @override
  Future<void> updateEntityAliases(
    String entityId,
    List<String> aliases,
    int updatedTurn,
  ) async {
    final now = DateTime.now();
    final affected = await (_database.update(_database.factualEntitiesTable)
          ..where((t) => t.entityId.equals(entityId)))
        .write(
      FactualEntitiesTableCompanion(
        aliases: Value(jsonEncode(aliases)),
        updatedAt: Value(now),
        updatedTurn: Value(updatedTurn),
      ),
    );
    if (affected == 0) {
      throw ModelNotFoundException(entityId);
    }
    // F7 修复：同步 FTS 索引——此前别名更新不写 factual_fts，
    // 索引与数据渐行漂移，按新别名检索越来越不准。primary_name 用子查询
    // 取实体表现值（本方法不改名，但保持单一事实源）。
    // 2026-09-09 审查（FF4）：无 FTS 行时（auto/card/手动实体）本语句是
    // 有意的 no-op——索引覆盖面仍限定世界书词条，非世界书实体的关键词
    // 可达性由 searchEntitiesByText 主表子串通道保证，不在此扩张索引。
    await _database.customStatement(
      'UPDATE factual_fts SET aliases = ?, '
      'primary_name = (SELECT primary_name FROM factual_entities '
      'WHERE entity_id = ?) '
      'WHERE entity_id = ?',
      [aliases.join(' '), entityId, entityId],
    );
  }

  @override
  Future<void> updateEntityImportance(
    String entityId,
    int importance,
    int updatedTurn,
  ) async {
    RangeError.checkValueInInterval(importance, 1, 5, 'importance');
    // 仅更新重要度与轮次/时间，放行 auto 与导入实体（与 updateEntityForceInject 同源）
    final now = DateTime.now();
    final affected = await (_database.update(_database.factualEntitiesTable)
          ..where((t) => t.entityId.equals(entityId)))
        .write(
      FactualEntitiesTableCompanion(
        importance: Value(importance),
        updatedAt: Value(now),
        updatedTurn: Value(updatedTurn),
      ),
    );
    if (affected == 0) {
      throw ModelNotFoundException(entityId);
    }
  }

  @override
  Future<void> archiveEntity(
    String entityId,
    String reason,
    int turnNumber,
  ) async {
    final now = DateTime.now();
    final affected = await (_database.update(_database.factualEntitiesTable)
          ..where((t) => t.entityId.equals(entityId)))
        .write(
      FactualEntitiesTableCompanion(
        isArchived: const Value(true),
        updatedAt: Value(now),
        updatedTurn: Value(turnNumber),
      ),
    );
    if (affected == 0) {
      throw ModelNotFoundException(entityId);
    }
    _logger.info(
      'Entity archived',
      detail: 'entityId=$entityId, reason=$reason, turn=$turnNumber',
    );
  }

  @override
  Future<void> updateEntityForceInject(
    String entityId,
    ForceInjectTarget target,
  ) async {
    // 注意：不设只读守卫（开关是纯检索偏好，世界书/角色卡实体可改）
    final affected = await (_database.update(_database.factualEntitiesTable)
          ..where((t) => t.entityId.equals(entityId)))
        .write(
      FactualEntitiesTableCompanion(
        forceInject: Value(target.toDbString()),
      ),
    );
    if (affected == 0) {
      throw ModelNotFoundException(entityId);
    }
  }

  @override
  Future<void> batchUpdateForceInject(
    List<String> entityIds,
    ForceInjectTarget target,
  ) async {
    if (entityIds.isEmpty) return;
    await _database.transaction(() async {
      await (_database.update(_database.factualEntitiesTable)
            ..where((t) => t.entityId.isIn(entityIds)))
          .write(
        FactualEntitiesTableCompanion(
          forceInject: Value(target.toDbString()),
        ),
      );
    });
  }

  /// 批 J-b：词条级注入停用/恢复（与
  /// [batchUpdateForceInject] 同口径：纯列写、无审计行——该开关属
  /// 用户即时偏好而非记忆事实变更，regenerate 回滚不触及）
  @override
  Future<void> batchUpdateInjectionDisabled(
    List<String> entityIds, {
    required bool disabled,
  }) async {
    if (entityIds.isEmpty) return;
    await _database.transaction(() async {
      await (_database.update(_database.factualEntitiesTable)
            ..where((t) => t.entityId.isIn(entityIds)))
          .write(
        FactualEntitiesTableCompanion(
          injectionDisabled: Value(disabled),
        ),
      );
    });
  }

  // ==================== 属性查询 ====================

  @override
  Future<List<FactualAttribute>> getAttributes(
    String sessionId,
    List<String> entityIds,
  ) async {
    if (entityIds.isEmpty) return const [];
    final rows = await (_database.select(_database.factualAttributesTable)
          ..where(
            (t) => t.sessionId.equals(sessionId) & t.entityId.isIn(entityIds),
          ))
        .get();
    return rows.map(_attributeFromTyped).toList();
  }

  @override
  Future<List<FactualAttribute>> getAttributesByKey(
    String entityId,
    String attrKey,
  ) async {
    final rows = await (_database.select(_database.factualAttributesTable)
          ..where(
            (t) => t.entityId.equals(entityId) & t.attrKey.equals(attrKey),
          )
          // 显式固化「首行=基线」口径——
          // 同键基线行+演变行并存时，投影先写基线行（rowid 更小），
          // 依赖 SQLite 自然行序在 VACUUM/引擎差异下不可靠。
          ..orderBy([(t) => OrderingTerm(expression: t.rowId)]))
        .get();
    return rows.map(_attributeFromTyped).toList();
  }

  // ==================== 属性写入 ====================

  @override
  Future<FactualAttribute> createAttribute(
    FactualAttribute attribute,
  ) async {
    await _database.into(_database.factualAttributesTable).insert(
          FactualAttributesTableCompanion.insert(
            attributeId: attribute.attributeId,
            entityId: attribute.entityId,
            sessionId: attribute.sessionId,
            attrKey: attribute.attrKey,
            value: attribute.value,
            valueType: Value(attribute.valueType.toDbString()),
            importance: Value(attribute.importance),
            source: Value(attribute.source.toDbString()),
            createdAt: Value(attribute.createdAt),
            updateReason: Value(attribute.updateReason),
          ),
        );
    return attribute;
  }

  @override
  Future<void> updateAttributeValue(
    String attributeId,
    String newValue,
    int updatedTurn,
    String? updateReason,
  ) async {
    // 只读兜底拦截（DOC-15 §8.2）：source != auto 的属性不可修改
    final attr = await _findAttributeById(attributeId);
    if (attr != null && attr.source.isReadOnly) {
      throw ResourceApplyException(
        t.common.seedResource.readOnlyAttributeCannotBeModified,
      );
    }

    final now = DateTime.now();
    final affected = await (_database.update(_database.factualAttributesTable)
          ..where((t) => t.attributeId.equals(attributeId)))
        .write(
      FactualAttributesTableCompanion(
        value: Value(newValue),
        updatedAt: Value(now),
        updatedTurn: Value(updatedTurn),
        updateReason: Value(updateReason),
      ),
    );
    if (affected == 0) {
      throw ModelNotFoundException(attributeId);
    }
  }

  // ==================== 审计日志 ====================

  @override
  Future<void> insertHistory(FactualMemoryHistory history) async {
    await _database.into(_database.factualMemoryHistoryTable).insert(
          FactualMemoryHistoryTableCompanion.insert(
            entityId: history.entityId,
            action: history.action.toDbString(),
            turnNumber: history.turnNumber,
            attributeId: Value(history.attributeId),
            oldValue: Value(history.oldValue),
            newValue: Value(history.newValue),
            reason: Value(history.reason),
            confidence: Value(history.confidence),
            createdAt: Value(history.createdAt),
          ),
        );
  }

  @override
  Future<List<FactualMemoryHistory>> getHistory(String entityId) async {
    final rows = await (_database.select(_database.factualMemoryHistoryTable)
          ..where((t) => t.entityId.equals(entityId)))
        .get();
    // 按 createdAt 降序排列（最新在前）
    final sorted = rows.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return sorted.map(_historyFromTyped).toList();
  }

  @override
  Future<FactualMemoryChangesSnapshot> readMemoryChangesSnapshot(
    String sessionId,
  ) async {
    return _database.transaction(() async {
      final entityRows = await (_database.select(
        _database.factualEntitiesTable,
      )..where((t) => t.sessionId.equals(sessionId)))
          .get();
      final attributeRows = await (_database.select(
        _database.factualAttributesTable,
      )..where((t) => t.sessionId.equals(sessionId)))
          .get();
      final entityIds = entityRows.map((row) => row.entityId).toList();
      final historyRows = entityIds.isEmpty
          ? const <FactualMemoryHistoryTableData>[]
          : await (_database.select(_database.factualMemoryHistoryTable)
                ..where((t) => t.entityId.isIn(entityIds))
                ..orderBy([
                  (t) => OrderingTerm(
                        expression: t.turnNumber,
                        mode: OrderingMode.desc,
                      ),
                  (t) => OrderingTerm(
                        expression: t.id,
                        mode: OrderingMode.desc,
                      ),
                ]))
              .get();
      final artifactRows = await _database.customSelect(
        'SELECT a.turn_number, a.current_variant_index, a.facts_changes, '
        'a.reply_text, a.generated_text, a.event_summary, a.created_at, '
        'v.content AS selected_variant_content, '
        'v.facts_changes AS selected_variant_facts_changes, '
        'v.event_summary AS selected_variant_event_summary '
        'FROM intermediate_round_artifacts a '
        'LEFT JOIN message_variants v ON v.session_id = a.session_id '
        'AND v.turn_number = a.turn_number '
        'AND v.variant_index = a.current_variant_index '
        'WHERE a.session_id = ? ORDER BY a.turn_number, a.id',
        variables: [Variable.withString(sessionId)],
      ).get();
      final messageRows = await _database.customSelect(
        'SELECT id, message_id, role, content, parent_user_msg_id, branch_index, '
        'is_summary, created_at FROM chat_messages WHERE session_id = ? '
        'ORDER BY created_at, id',
        variables: [Variable.withString(sessionId)],
      ).get();
      final factsChangesByTurn = <int, String>{};
      final variantsByTurn = <int, int?>{};
      var storyRoundsByTurn = <int, FactualMemoryStoryRound>{};
      final revisionParts = <Object?>[];
      final userTurnById = <String, int>{};
      final userTexts = <int, String>{};
      final assistantTexts = <int, String>{};
      var currentTurn = 0;
      for (final row in messageRows) {
        if (row.read<bool>('is_summary')) continue;
        final role = row.read<String>('role');
        if (role == 'user') {
          currentTurn++;
          final messageId = row.read<String>('message_id');
          userTurnById[messageId] = currentTurn;
          final content = row.readNullable<String>('content');
          if (content != null) userTexts[currentTurn] = content;
        } else if (role == 'assistant') {
          final content = row.readNullable<String>('content');
          final turn =
              userTurnById[row.readNullable<String>('parent_user_msg_id')] ??
                  currentTurn;
          if (content != null && turn > 0) assistantTexts[turn] = content;
        }
      }
      for (final row in artifactRows) {
        final turn = row.read<int>('turn_number');
        final selectedFactsChanges =
            row.readNullable<String>('selected_variant_facts_changes');
        final factsChanges = selectedFactsChanges ??
            row.readNullable<String>('facts_changes') ??
            '[]';
        factsChangesByTurn[turn] = factsChanges;
        variantsByTurn[turn] = row.readNullable<int>('current_variant_index');
        final generatedText = row.readNullable<String>('generated_text');
        final replyText = row.readNullable<String>('reply_text');
        final assistantText = assistantTexts[turn];
        storyRoundsByTurn[turn] = FactualMemoryStoryRound(
          turnNumber: turn,
          createdAt: DateTime.fromMillisecondsSinceEpoch(
            row.read<int>('created_at'),
          ),
          narrativeText: assistantText ??
              row.readNullable<String>('selected_variant_content') ??
              generatedText,
          replyText: replyText == generatedText
              ? assistantText ?? replyText
              : replyText,
          eventSummaryText: row.readNullable<String>(
                'selected_variant_event_summary',
              ) ??
              row.readNullable<String>('event_summary'),
        );
        revisionParts.add([
          turn,
          row.readNullable<int>('current_variant_index'),
          factsChanges,
          row.readNullable<String>('reply_text'),
          row.readNullable<String>('generated_text'),
          row.readNullable<String>('selected_variant_content'),
          row.readNullable<String>('event_summary'),
          row.readNullable<String>('selected_variant_event_summary'),
        ]);
      }
      if (storyRoundsByTurn.isNotEmpty && messageRows.isNotEmpty) {
        storyRoundsByTurn = {
          for (final entry in storyRoundsByTurn.entries)
            entry.key: FactualMemoryStoryRound(
              turnNumber: entry.value.turnNumber,
              createdAt: entry.value.createdAt,
              userText: userTexts[entry.key],
              narrativeText: entry.value.narrativeText,
              replyText: entry.value.replyText,
              eventSummaryText: entry.value.eventSummaryText,
            ),
        };
      }
      for (final row in messageRows) {
        revisionParts.add([
          row.read<String>('message_id'),
          row.read<String>('role'),
          row.readNullable<String>('content'),
          row.readNullable<String>('parent_user_msg_id'),
          row.read<int>('branch_index'),
          row.read<bool>('is_summary'),
          row.read<DateTime>('created_at').millisecondsSinceEpoch,
        ]);
      }
      return FactualMemoryChangesSnapshot(
        entities: entityRows.map(_entityFromTyped).toList(),
        attributes: attributeRows.map(_attributeFromTyped).toList(),
        history: historyRows.map(_historyFromTyped).toList(),
        currentFactsChangesByTurn: factsChangesByTurn,
        currentVariantByTurn: variantsByTurn,
        storyRoundsByTurn: storyRoundsByTurn,
        storyRevision: jsonEncode(revisionParts),
      );
    });
  }

  @override
  Future<int> countRecentUpdates(
    String entityId, {
    required int fromTurn,
  }) async {
    // 仅统计 UPDATE_ATTR / APPEND_LIST / REMOVE_FROM_LIST（修改类操作）
    final rows = await (_database.select(_database.factualMemoryHistoryTable)
          ..where(
            (t) =>
                t.entityId.equals(entityId) &
                t.turnNumber.isBiggerOrEqualValue(fromTurn) &
                t.action.isIn(
                  const ['update_attr', 'append_list', 'remove_from_list'],
                ),
          ))
        .get();
    return rows.length;
  }

  // ==================== 清理 ====================

  @override
  Future<void> deleteAllFacts(String sessionId) async {
    await _database.transaction(() async {
      await (_database.delete(_database.factualMemoryHistoryTable)
            ..where(
              (t) => t.entityId.isInQuery(
                _database.selectOnly(_database.factualEntitiesTable)
                  ..addColumns([_database.factualEntitiesTable.entityId])
                  ..where(
                    _database.factualEntitiesTable.sessionId.equals(sessionId),
                  ),
              ),
            ))
          .go();
      await (_database.delete(_database.factualAttributesTable)
            ..where((t) => t.sessionId.equals(sessionId)))
          .go();
      await (_database.delete(_database.factualEntitiesTable)
            ..where((t) => t.sessionId.equals(sessionId)))
          .go();
      // 清理世界书词条全文索引（factual_fts）
      await _database.customStatement(
        'DELETE FROM factual_fts WHERE session_id = ?',
        [sessionId],
      );
    });
  }

  @override
  Future<void> deleteFactsByTurns({
    required String sessionId,
    required int fromTurn,
  }) async {
    // 旧流水可能把另一个对象的属性当作回滚目标。
    // 在任何删除前核对实际外键，保留整份现场供用户恢复。
    final mismatch = await _database.customSelect(
      'SELECT 1 FROM factual_entities e JOIN factual_attributes a '
      'ON a.entity_id = e.entity_id WHERE e.session_id = ? '
      'AND a.session_id <> e.session_id '
      'UNION ALL SELECT 1 FROM factual_memory_history h '
      'JOIN factual_entities e ON e.entity_id = h.entity_id '
      'JOIN factual_attributes a ON a.attribute_id = h.attribute_id '
      'WHERE e.session_id = ? AND h.turn_number >= ? '
      'AND (a.session_id <> e.session_id OR a.entity_id <> e.entity_id) LIMIT 1',
      variables: [
        Variable.withString(sessionId),
        Variable.withString(sessionId),
        Variable.withInt(fromTurn),
      ],
    ).get();
    if (mismatch.isNotEmpty) throw const FactTargetMismatch();

    // 1. 收集待删实体 IDs（createdTurn >= fromTurn）
    final entitiesToDelete = await (_database.select(
      _database.factualEntitiesTable,
    )..where(
            (t) =>
                t.sessionId.equals(sessionId) &
                t.createdTurn.isBiggerOrEqualValue(fromTurn),
          ))
        .get();
    final entityIdsToDelete = entitiesToDelete.map((e) => e.entityId).toList();

    // 2. 删除这些实体的属性 + 历史 + FTS 行
    //    FF3（2026-09-09 审查）：此前不删 factual_fts——当前索引行只属
    //    createdTurn=0 的投影实体（fromTurn≥1 恒不可达），但一旦索引覆盖面
    //    扩大即成孤儿行，属必须锚定的不变量。
    if (entityIdsToDelete.isNotEmpty) {
      await (_database.delete(_database.factualAttributesTable)
            ..where((t) => t.entityId.isIn(entityIdsToDelete)))
          .go();
      await (_database.delete(_database.factualMemoryHistoryTable)
            ..where((t) => t.entityId.isIn(entityIdsToDelete)))
          .go();
      await _database.customStatement(
        'DELETE FROM factual_fts WHERE entity_id IN '
        '(${List.filled(entityIdsToDelete.length, '?').join(', ')})',
        entityIdsToDelete,
      );
    }

    // 3. 2026-07-28 修复：回滚 createdTurn < fromTurn 的实体在 fromTurn 及之后
    //    的属性/别名/归档状态，基于 factual_memory_history 重建旧值。
    //    本步骤与步骤 2/4/5 在同一 drift transaction 内（由调用方开启），
    //    保证"删除 + 回滚"原子性。
    await _rollbackSurvivingEntities(
      sessionId: sessionId,
      fromTurn: fromTurn,
      excludedEntityIds: entityIdsToDelete,
    );

    // 4. 删除当前会话内 fromTurn 及之后的历史记录（保留更早的审计）
    //    factual_memory_history 无 sessionId 列，需通过 entityId 子查询
    //    限定到当前会话，避免跨会话误删。
    await (_database.delete(_database.factualMemoryHistoryTable)
          ..where(
            (t) =>
                t.turnNumber.isBiggerOrEqualValue(fromTurn) &
                t.entityId.isInQuery(
                  _database.selectOnly(_database.factualEntitiesTable)
                    ..addColumns([_database.factualEntitiesTable.entityId])
                    ..where(
                      _database.factualEntitiesTable.sessionId
                          .equals(sessionId),
                    ),
                ),
          ))
        .go();

    // 5. 最后删除实体本身
    await (_database.delete(_database.factualEntitiesTable)
          ..where(
            (t) =>
                t.sessionId.equals(sessionId) &
                t.createdTurn.isBiggerOrEqualValue(fromTurn),
          ))
        .go();
  }

  @override
  Future<T> runInTransaction<T>(Future<T> Function() action) {
    return _database
        .transaction(action, requireNew: true)
        .onError<CouldNotRollBackException>(
          (_, stackTrace) => Error.throwWithStackTrace(
            const SavepointRollbackException(),
            stackTrace,
          ),
        );
  }

  // ==================== FTS5 索引（世界书词条，DOC-15 §7.3）====================

  @override
  Future<void> insertFactualFts({
    required String entityId,
    required String sessionId,
    required String primaryName,
    required List<String> aliases,
    required String description,
  }) async {
    await _database.customStatement(
      'INSERT INTO factual_fts '
      '(primary_name, aliases, description, entity_id, session_id) '
      'VALUES (?, ?, ?, ?, ?)',
      [primaryName, aliases.join(' '), description, entityId, sessionId],
    );
  }

  @override
  Future<void> deleteFactualFts(String entityId) async {
    await _database.customStatement(
      'DELETE FROM factual_fts WHERE entity_id = ?',
      [entityId],
    );
  }

  @override
  Future<void> deleteAllFactualFts(String sessionId) async {
    await _database.customStatement(
      'DELETE FROM factual_fts WHERE session_id = ?',
      [sessionId],
    );
  }

  @override
  Future<void> rebuildEntityFts(String entityId) async {
    // 按实体重建——演变 description 行的
    // 原地更新（update_attr 改已有演变行）与回滚删除此前不走同步，FTS 留
    // 旧文本脏索引（幽灵召回/旧值召回）。取值口径与 rebuildSessionFts
    // 对齐：只建 worldbook 词条、description 取 rowid 首条（基线优先）。
    await deleteFactualFts(entityId);
    final entity = await getEntityById(entityId);
    if (entity == null || entity.source != FactualSource.worldbook) {
      return;
    }
    final descriptionRows = await getAttributesByKey(entityId, 'description');
    await insertFactualFts(
      entityId: entityId,
      sessionId: entity.sessionId,
      primaryName: entity.primaryName,
      aliases: entity.aliases,
      // 基线+演变全行进索引（原只取首行=基线）
      description: composeFtsDescription(
        [for (final row in descriptionRows) row.value],
      ),
    );
  }

  /// searchWorldFacts 两通道候选安全上限（防御值）：会话内世界书词条
  /// 量级有界，候选全取后按合并序截断；上限只防异常膨胀数据拖垮单次检索。
  static const int _kWorldFactsCandidateCap = 500;

  @override
  Future<List<FactualEntity>> searchWorldFacts(
    String sessionId,
    List<String> terms, {
    int limit = 20,
    bool excludeInjectionDisabled = false,
  }) async {
    // F2 修复：中文短触发词（<3 字符，如"剑""精灵"——
    // SillyTavern 世界书常见）trigram MATCH 无法召回——trigram 需 ≥3 字符
    // 才能构成 token。兑现 app_database 注释承诺的"<3 字符用 LIKE"：
    // 短词走子串匹配，长词照旧 FTS，两路合并去重。
    // 2026-09-09：切词收口到 MemoryQuery——此前整串当一个短语
    //（"图书馆 值班员"要求字面连续出现），空格分隔的关键词列表必空。
    //
    // 检索顺序/数量/过滤收口：两通道候选全取（各受
    // [_kWorldFactsCandidateCap] 上限约束），合并候选序 = FTS rank 序
    // 在前、LIKE 命中按（importance DESC, primary_name ASC）稳定序去重
    // 追加（短词无相关性分数，不伪造分数）；归档/停用/会话过滤在候选
    // 序上执行，被过滤候选不占 limit 名额，沿候选序补足后 take(limit)。
    // 此前 FTS/LIKE 各取 limit 条、Set 并集丢 rank 序、回表无 ORDER BY
    //——limit=1 且最优项归档时返回空（合格后续候选被名额挤掉）、
    // 长短词混合时可能返回 2 条。
    if (limit <= 0) return const [];
    final cleaned = MemoryQuery.tokenizeAll(terms);
    if (cleaned.isEmpty) return const [];

    final ftsTerms = cleaned.where((t) => !MemoryQuery.isShortTerm(t)).toList();
    final shortTerms = cleaned.where(MemoryQuery.isShortTerm).toList();

    // FTS 通道：保留 rank 序，候选全取（≤ 上限），保序去重
    final ftsIds = <String>[];
    if (ftsTerms.isNotEmpty) {
      final expression = MemoryQuery.buildMatchExpression(ftsTerms);
      if (expression.isNotEmpty) {
        final rows = await _database.customSelect(
          'SELECT entity_id FROM factual_fts '
          'WHERE factual_fts MATCH ? AND session_id = ? '
          'ORDER BY rank LIMIT ?',
          variables: [
            Variable.withString(expression),
            Variable.withString(sessionId),
            Variable.withInt(_kWorldFactsCandidateCap),
          ],
        ).get();
        for (final id in rows.map((r) => r.read<String>('entity_id'))) {
          if (!ftsIds.contains(id)) ftsIds.add(id);
        }
      }
    }

    // LIKE 通道：候选全取（≤ 上限），稳定序在合并阶段按实体表列补齐
    //（FTS 行不带 importance）。LIKE 逐词 OR 扫描（FTS5 虚拟表支持列值
    // 扫描；数据量为会话级词条量级，全扫开销可接受）。转义 LIKE 通配符
    // 防注入式误匹配。
    final likeIds = <String>{};
    if (shortTerms.isNotEmpty) {
      final conditions = <String>[];
      final params = <Variable>[];
      for (final term in shortTerms) {
        conditions.add(
          r"(primary_name LIKE ? ESCAPE '\'"
          r" OR aliases LIKE ? ESCAPE '\'"
          r" OR description LIKE ? ESCAPE '\')",
        );
        // 每次出现独立变量实例：drift 的变量绑定按出现次数计
        final pattern =
            Variable.withString('%${MemoryQuery.escapeLike(term)}%');
        params
          ..add(pattern)
          ..add(pattern)
          ..add(pattern);
      }
      final likeRows = await _database.customSelect(
        'SELECT entity_id FROM factual_fts '
        'WHERE session_id = ? AND (${conditions.join(' OR ')}) '
        'LIMIT ?',
        variables: [
          Variable.withString(sessionId),
          ...params,
          Variable.withInt(_kWorldFactsCandidateCap),
        ],
      ).get();
      likeIds.addAll(likeRows.map((r) => r.read<String>('entity_id')));
    }

    final ftsIdSet = ftsIds.toSet();
    final candidateIds = [
      ...ftsIds,
      ...likeIds.where((id) => !ftsIdSet.contains(id)),
    ];
    if (candidateIds.isEmpty) return const [];

    // 回表：过滤条件不变（FF13 会话过滤 + 归档剔除 + 可选停用剔除）；
    // 顺序不靠 SQL（无 ORDER BY 也不再丢失相关性序），按候选序在
    // Dart 侧重建映射。
    final rows = await (_database.select(_database.factualEntitiesTable)
          ..where(
            (t) {
              // FF13（2026-09-09 审查）：最终实体查询补 session 过滤——
              // 此前正确性完全依赖 FTS 行 session_id，一旦索引行写错
              //（导入/维护路径）就会跨会话泄漏实体。
              var condition = t.entityId.isIn(candidateIds) &
                  t.sessionId.equals(sessionId) &
                  t.isArchived.equals(false);
              // （批 J-b 漏桶收口）：注入面剔除停用词条——FTS/LIKE
              // 命中不代表可注入，仍以实体表 injection_disabled 为准
              if (excludeInjectionDisabled) {
                condition = condition & t.injectionDisabled.equals(false);
              }
              return condition;
            },
          ))
        .get();
    final rowById = {for (final row in rows) row.entityId: row};

    // LIKE 独有命中按（importance DESC, primary_name ASC）稳定序——
    // importance 在实体表，排序只能在回表之后做
    final likeOnly = [
      for (final id in likeIds)
        if (!ftsIdSet.contains(id) && rowById.containsKey(id)) id,
    ]..sort((a, b) {
        final left = rowById[a]!;
        final right = rowById[b]!;
        final byImportance = right.importance.compareTo(left.importance);
        return byImportance != 0
            ? byImportance
            : left.primaryName.compareTo(right.primaryName);
      });

    // 沿候选序取数：被过滤（归档/停用/跨会话/孤儿索引行）候选跳过
    // 不占名额，继续补足到 limit 或候选耗尽
    final result = <FactualEntity>[];
    for (final id in [...ftsIds, ...likeOnly]) {
      final row = rowById[id];
      if (row == null) continue;
      result.add(_entityFromTyped(row));
      if (result.length >= limit) break;
    }
    return result;
  }

  /// 回滚非待删实体在 [fromTurn] 及之后的变更
  ///
  /// 属性恢复到最早被撤销记录的旧值。缺旧值的历史格式可以回放此前
  /// 的存留记录。两处都没有旧值证据时，撤销新增的属性行。
  /// 同时移除这些轮次添加的别名，并撤销归档。
  Future<void> _rollbackSurvivingEntities({
    required String sessionId,
    required int fromTurn,
    required List<String> excludedEntityIds,
  }) async {
    // 获取所有非待删实体（createdTurn < fromTurn）
    final survivingEntities = await (_database.select(
      _database.factualEntitiesTable,
    )..where(
            (t) =>
                t.sessionId.equals(sessionId) &
                t.createdTurn.isSmallerThanValue(fromTurn) &
                (excludedEntityIds.isEmpty
                    ? const CustomExpression<bool>('1 = 1')
                    : t.entityId.isNotIn(excludedEntityIds)),
          ))
        .get();
    if (survivingEntities.isEmpty) return;

    final survivingIds = survivingEntities.map((e) => e.entityId).toSet();

    // 读取这些实体在 fromTurn 及之后的历史记录
    final historiesToRollback = await (_database.select(
      _database.factualMemoryHistoryTable,
    )
          ..where(
            (t) =>
                t.turnNumber.isBiggerOrEqualValue(fromTurn) &
                t.entityId.isIn(survivingIds.toList()),
          )
          // 同轮的多个变更可能同秒写入，以自增主键还原写入顺序。
          ..orderBy([
            (t) => OrderingTerm.asc(t.turnNumber),
            (t) => OrderingTerm.asc(t.id),
          ]))
        .get();
    if (historiesToRollback.isEmpty) return;

    final firstChangeByAttribute = <({String entityId, String attributeId}),
        FactualMemoryHistoryTableData>{};
    final firstImportanceChangeByEntity =
        <String, FactualMemoryHistoryTableData>{};
    final aliasesToRemove = <String, List<String>>{};
    final entitiesToUnarchive = <String>{};

    for (final history in historiesToRollback) {
      final action = FactAction.fromString(history.action);
      switch (action) {
        case FactAction.updateAttr:
        case FactAction.appendList:
        case FactAction.removeFromList:
          final attributeId = history.attributeId;
          if (attributeId != null) {
            firstChangeByAttribute.putIfAbsent(
              (entityId: history.entityId, attributeId: attributeId),
              () => history,
            );
          }
        case FactAction.addAlias:
          if (history.newValue != null) {
            // 兼容两种历史格式——旧归并写入的
            // 逗号并集行（join(',')）按逗号拆开逐个匹配；新格式逐别名一行。
            final values = history.newValue!.contains(',')
                ? history.newValue!.split(',')
                : [history.newValue!];
            aliasesToRemove
                .putIfAbsent(history.entityId, () => [])
                .addAll(values.where((v) => v.isNotEmpty));
          }
        case FactAction.archiveEntity:
          entitiesToUnarchive.add(history.entityId);
        case FactAction.setImportance:
          firstImportanceChangeByEntity.putIfAbsent(
            history.entityId,
            () => history,
          );
        case FactAction.createEntity:
          // create_entity 的实体已在步骤 1 删除，这里不会遇到
          break;
      }
    }

    // 回滚属性
    for (final entry in firstChangeByAttribute.entries) {
      final key = entry.key;
      // 查询该属性在 fromTurn 之前的最新历史记录
      final previousHistory = await (_database.select(
        _database.factualMemoryHistoryTable,
      )
            ..where(
              (t) =>
                  t.entityId.equals(key.entityId) &
                  t.attributeId.equals(key.attributeId) &
                  t.turnNumber.isSmallerThanValue(fromTurn) &
                  t.action.isIn(const [
                    'update_attr',
                    'append_list',
                    'remove_from_list',
                  ]),
            )
            ..orderBy([
              (t) => OrderingTerm.desc(t.turnNumber),
              (t) => OrderingTerm.desc(t.id),
            ])
            ..limit(1))
          .getSingleOrNull();

      String? previousValue;
      if (previousHistory != null) {
        // 列表的 newValue 仅是增删项，需与旧值合成该条记录之后的全量。
        previousValue = switch (FactAction.fromString(previousHistory.action)) {
          FactAction.appendList => _replayAppendValue(
              previousHistory.oldValue,
              previousHistory.newValue,
            ),
          FactAction.removeFromList => _replayRemoveValue(
              previousHistory.oldValue,
              previousHistory.newValue,
            ),
          _ => previousHistory.newValue ?? '',
        };
      }
      // 随实体创建和手动改值可能没有对应的属性流水。
      final restoreValue = entry.value.oldValue ?? previousValue;
      if (restoreValue == null) {
        await (_database.delete(_database.factualAttributesTable)
              ..where(
                (t) =>
                    t.sessionId.equals(sessionId) &
                    t.entityId.equals(key.entityId) &
                    t.attributeId.equals(key.attributeId),
              ))
            .go();
        continue;
      }
      await (_database.update(_database.factualAttributesTable)
            ..where(
              (t) =>
                  t.sessionId.equals(sessionId) &
                  t.entityId.equals(key.entityId) &
                  t.attributeId.equals(key.attributeId),
            ))
          .write(
        FactualAttributesTableCompanion(
          value: Value(restoreValue),
          updatedAt: Value(DateTime.now()),
          updatedTurn: Value(
            restoreValue == previousValue ? previousHistory?.turnNumber : null,
          ),
          updateReason: const Value('rolled back to pre-turn state'),
        ),
      );
    }

    // 回滚别名
    for (final entry in aliasesToRemove.entries) {
      final entity = survivingEntities.firstWhere(
        (e) => e.entityId == entry.key,
      );
      final currentAliases = _parseAliases(entity.aliases);
      final newAliases = currentAliases
          .where((alias) => !entry.value.contains(alias))
          .toList();
      if (newAliases.length != currentAliases.length) {
        await (_database.update(_database.factualEntitiesTable)
              ..where((t) => t.entityId.equals(entry.key)))
            .write(
          FactualEntitiesTableCompanion(
            aliases: Value(jsonEncode(newAliases)),
          ),
        );
        // F7 漂移不在回滚路径复发——别名回退
        // 同样要写 factual_fts，否则已回滚的别名继续可召回
        await _database.customStatement(
          'UPDATE factual_fts SET aliases = ? WHERE entity_id = ?',
          [newAliases.join(' '), entry.key],
        );
      }
    }

    // 回滚归档：把在 fromTurn 及之后被 archive 的实体恢复为活跃
    for (final entityId in entitiesToUnarchive) {
      await (_database.update(_database.factualEntitiesTable)
            ..where((t) => t.entityId.equals(entityId)))
          .write(
        const FactualEntitiesTableCompanion(
          isArchived: Value(false),
        ),
      );
    }

    // 回滚重要度：恢复 fromTurn 前最近一次 set_importance 新值或首个回滚条目的 oldValue
    for (final entry in firstImportanceChangeByEntity.entries) {
      final entityId = entry.key;
      final previousSetImportance = await (_database.select(
        _database.factualMemoryHistoryTable,
      )
            ..where(
              (t) =>
                  t.entityId.equals(entityId) &
                  t.turnNumber.isSmallerThanValue(fromTurn) &
                  t.action.equals('set_importance'),
            )
            ..orderBy([
              (t) => OrderingTerm.desc(t.turnNumber),
              (t) => OrderingTerm.desc(t.id),
            ])
            ..limit(1))
          .getSingleOrNull();
      final previousImportance = int.tryParse(
        previousSetImportance?.newValue ?? '',
      );
      final restoredImportance =
          int.tryParse(entry.value.oldValue ?? '') ?? previousImportance;
      if (restoredImportance == null) continue;

      final latestPriorEntityHistory = await (_database.select(
        _database.factualMemoryHistoryTable,
      )
            ..where(
              (t) =>
                  t.entityId.equals(entityId) &
                  t.turnNumber.isSmallerThanValue(fromTurn) &
                  t.action.isIn(
                    const ['set_importance', 'add_alias', 'archive_entity'],
                  ),
            )
            ..orderBy([
              (t) => OrderingTerm.desc(t.turnNumber),
              (t) => OrderingTerm.desc(t.id),
            ])
            ..limit(1))
          .getSingleOrNull();
      final restoredUpdatedTurn = latestPriorEntityHistory?.turnNumber;
      await (_database.update(_database.factualEntitiesTable)
            ..where((t) => t.entityId.equals(entityId)))
          .write(
        FactualEntitiesTableCompanion(
          importance: Value(restoredImportance),
          updatedAt: Value(
            restoredUpdatedTurn != null ? DateTime.now() : null,
          ),
          updatedTurn: Value(restoredUpdatedTurn),
        ),
      );
    }

    // 属性回滚（改值恢复/整行删除）可能
    // 触碰世界书演变 description 行——按实体重建 factual_fts，防已回滚
    // 文本残留索引（幽灵召回）。内部对非 worldbook 实体仅删索引行。
    for (final entityId
        in firstChangeByAttribute.keys.map((k) => k.entityId).toSet()) {
      await rebuildEntityFts(entityId);
    }
  }

  /// 重放一条 append_list 审计行：oldValue（追加前全量 JSON）+ 追加项，
  /// 得到该行应用后的列表（= 回滚恢复值）。oldValue 缺失/非法时按
  /// "该行首建列表"处理为单项列表。
  String _replayAppendValue(String? oldValue, String? appendedItem) {
    final base = _decodeStringList(oldValue);
    if (appendedItem != null && appendedItem.isNotEmpty) {
      base.add(appendedItem);
    }
    return jsonEncode(base);
  }

  /// 重放一条 remove_from_list 审计行：oldValue（移除前全量 JSON）-
  /// 移除项，得到该行应用后的列表。oldValue 缺失/非法时返回空列表 JSON
  /// （列表内容已不可考，空表优于裸字符串——listValue() 至少能解析）。
  String _replayRemoveValue(String? oldValue, String? removedItem) {
    final base = _decodeStringList(oldValue);
    if (removedItem != null) {
      base.removeWhere((v) => v == removedItem);
    }
    return jsonEncode(base);
  }

  List<String> _decodeStringList(String? json) {
    if (json == null || json.isEmpty) return <String>[];
    try {
      final decoded = jsonDecode(json);
      if (decoded is List) return decoded.map((e) => e.toString()).toList();
    } on FormatException {
      // 落到下方空表兜底
    }
    return <String>[];
  }

  // ==================== 记忆查看器 CRUD（2026-07-22 新增）====================

  @override
  Future<void> deleteEntityById(String entityId) async {
    // 只读兜底拦截（DOC-15 §8.2）：source != auto 的实体不可删除
    final entity = await getEntityById(entityId);
    if (entity != null && entity.source.isReadOnly) {
      throw ResourceApplyException(
        t.common.seedResource.readOnlyEntityCannotBeDeleted,
      );
    }

    await _database.transaction(() async {
      // 1. 删属性
      await (_database.delete(_database.factualAttributesTable)
            ..where((t) => t.entityId.equals(entityId)))
          .go();
      // 2. 删历史
      await (_database.delete(_database.factualMemoryHistoryTable)
            ..where((t) => t.entityId.equals(entityId)))
          .go();
      // 3. 删实体
      await (_database.delete(_database.factualEntitiesTable)
            ..where((t) => t.entityId.equals(entityId)))
          .go();
      // 4. 删全文索引
      await _database.customStatement(
        'DELETE FROM factual_fts WHERE entity_id = ?',
        [entityId],
      );
    });
  }

  @override
  Future<int> deleteEntitiesBySourceRef(
    String sessionId,
    String sourceRef,
  ) async {
    // F1 修复：取消应用专用通道——有意绕过只读守卫
    // （守卫面向记忆库手动单条删除；种子成组移除是投影生命周期的另一半）。
    return _database.transaction(() async {
      final entities = await (_database.select(_database.factualEntitiesTable)
            ..where(
              (t) =>
                  t.sessionId.equals(sessionId) & t.sourceRef.equals(sourceRef),
            ))
          .get();
      if (entities.isEmpty) return 0;
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
      await _database.customStatement(
        'DELETE FROM factual_fts WHERE entity_id IN '
        '(${List.filled(ids.length, '?').join(', ')})',
        ids,
      );
      return ids.length;
    });
  }

  @override
  Future<void> deleteAttributeById(String attributeId) async {
    // 只读兜底拦截（DOC-15 §8.2）：source != auto 的属性不可删除
    final attr = await _findAttributeById(attributeId);
    if (attr != null && attr.source.isReadOnly) {
      throw ResourceApplyException(
        t.common.seedResource.readOnlyAttributeCannotBeDeleted,
      );
    }

    await (_database.delete(_database.factualAttributesTable)
          ..where((t) => t.attributeId.equals(attributeId)))
        .go();
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
    // 只读兜底拦截：source != auto
    // 实体内容字段（主名/类型/重要度/分类）不可编辑；isArchived 是可逆的
    // 生命周期标记而非内容——AI 可归档导入实体，手动「恢复」（isArchived:
    // false）必须同路可达，否则归档成死状态。簿记字段（updatedTurn）随行。
    final entity = await getEntityById(entityId);
    if (entity != null &&
        entity.source.isReadOnly &&
        (primaryName != null ||
            type != null ||
            importance != null ||
            category != null)) {
      throw ResourceApplyException(
        t.common.seedResource.readOnlyEntityContentCannotBeEdited,
      );
    }

    final companion = FactualEntitiesTableCompanion(
      primaryName:
          primaryName != null ? Value(primaryName) : const Value.absent(),
      type: type != null ? Value(type.toDbString()) : const Value.absent(),
      importance: importance != null ? Value(importance) : const Value.absent(),
      category: category != null ? Value(category) : const Value.absent(),
      isArchived: isArchived != null ? Value(isArchived) : const Value.absent(),
      updatedAt: Value(DateTime.now()),
      updatedTurn:
          updatedTurn != null ? Value(updatedTurn) : const Value.absent(),
    );

    final affected = await (_database.update(_database.factualEntitiesTable)
          ..where((t) => t.entityId.equals(entityId)))
        .write(companion);
    if (affected == 0) {
      throw ModelNotFoundException(entityId);
    }

    // FF2（2026-09-09 审查）：改名同步 factual_fts——此前只写实体表，
    // 改名后旧名仍可召回、新名搜不到（索引与实体渐行漂移）。
    // 注意：只更新既有行，不为非世界书实体新建索引行（FTS 覆盖面口径不变）。
    if (primaryName != null) {
      await _database.customStatement(
        'UPDATE factual_fts SET primary_name = ? WHERE entity_id = ?',
        [primaryName, entityId],
      );
    }
  }

  // ==================== 映射辅助 ====================

  FactualEntity _entityFromTyped(FactualEntitiesTableData row) {
    return FactualEntity(
      entityId: row.entityId,
      sessionId: row.sessionId,
      type: FactualEntityType.fromString(row.type),
      primaryName: row.primaryName,
      aliases: _parseAliases(row.aliases),
      importance: row.importance,
      createdTurn: row.createdTurn,
      createdAt: row.createdAt,
      category: row.category,
      isArchived: row.isArchived,
      source: FactualSource.fromString(row.source),
      sourceRef: row.sourceRef,
      forceInject: ForceInjectTarget.fromString(row.forceInject),
      injectionDisabled: row.injectionDisabled,
      updatedAt: row.updatedAt,
      updatedTurn: row.updatedTurn,
    );
  }

  FactualAttribute _attributeFromTyped(FactualAttributesTableData row) {
    return FactualAttribute(
      attributeId: row.attributeId,
      entityId: row.entityId,
      sessionId: row.sessionId,
      attrKey: row.attrKey,
      value: row.value,
      valueType: AttributeValueType.fromString(row.valueType),
      importance: row.importance,
      source: FactualSource.fromString(row.source),
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
      updatedTurn: row.updatedTurn,
      updateReason: row.updateReason,
    );
  }

  /// 按 attributeId 查单条属性（只读守卫用）
  Future<FactualAttribute?> _findAttributeById(String attributeId) async {
    final rows = await (_database.select(_database.factualAttributesTable)
          ..where((t) => t.attributeId.equals(attributeId)))
        .get();
    return rows.isEmpty ? null : _attributeFromTyped(rows.first);
  }

  FactualMemoryHistory _historyFromTyped(FactualMemoryHistoryTableData row) {
    return FactualMemoryHistory(
      entityId: row.entityId,
      historyId: row.id,
      attributeId: row.attributeId,
      action: FactAction.fromString(row.action),
      oldValue: row.oldValue,
      newValue: row.newValue,
      reason: row.reason,
      confidence: row.confidence,
      turnNumber: row.turnNumber,
      createdAt: row.createdAt,
    );
  }

  /// 解析 aliases JSON 数组字符串
  ///
  /// 容错：解析失败时返回空列表（避免旧数据/脏数据导致崩溃）。
  List<String> _parseAliases(String aliasesJson) {
    if (aliasesJson.isEmpty) return const [];
    try {
      final decoded = jsonDecode(aliasesJson);
      if (decoded is List) {
        // FF19（2026-09-09 审查）：cast<String>() 遇非字符串元素会抛
        // TypeError（且不在 catch 范围内）——按类型过滤，脏数据静默降级。
        return decoded.whereType<String>().toList();
      }
    } on FormatException {
      // 容错：旧数据可能存了非 JSON 字符串
    }
    return const [];
  }

  /// 生成新 entityId（FactApplier 创建实体时调用）
  String generateEntityId() => 'ent_${_uuid.v4()}';

  /// 生成新 attributeId（FactApplier 创建属性时调用）
  String generateAttributeId() => 'attr_${_uuid.v4()}';
}
