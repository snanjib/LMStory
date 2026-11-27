import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:uuid/uuid.dart';

/// 关系属性拆分迁移（schema v55）
///
/// 背景：旧契约允许对 `relationships`（dict）执行 append_list，dict 行被
/// 按列表读取时恒得空表，单条追加值会以单元素 list 整体覆盖原 dict 内容
/// （真实数据丢失）；另有「无任何行时 append 直接新建 list 错型行」分支。
/// 写入侧守卫已随本批修复，本迁移处理存量数据：
///
/// 1. **损坏检测与恢复**（valueType=dict 但 value 解析为 List）：沿审计
///    历史逆序找最近一条可解析为合法 JSON 对象的 oldValue 恢复；历史无
///    可确定证据时保留原值并写「待人工确认」审计行，不猜测还原。
/// 2. **错型 list 行**（attrKey=relationships 且 valueType=list）：数据
///    原样保留 + 待确认审计行（条目语义无法从历史确定，不虚构对象）。
/// 3. **拆分**（合法 dict 对象）：entry 键按会话实体（主名/别名）**唯一**
///    命中的个人关系拆出为 `relationship:<主名>` single 属性；零命中或
///    歧义（群体表述如「师门众人」、未知对象）留在 dict 中继续承载。
///
/// 数据保护：
/// - 逐行先备份到 factual_relationship_migration_backup 再触碰；
/// - 语句级原子：调用方（onUpgrade）显式包事务，迁移中途崩溃整体
///   回滚，user_version 未写 → 下次启动重跑收敛（幂等）；
/// - 行级容错：单行处理异常不抛出（不阻塞升级与建库），该行保持
///   原样并尽力补写「待人工确认」审计标记——已成功的行正常生效；
/// - 每步写审计历史（oldValue 可回溯）；
/// - 幂等：已恢复/已拆分/已标记的行二次运行为 no-op；
/// - 不触碰只读基线行（source != auto）。
class RelationshipSplitMigration {
  RelationshipSplitMigration(this._db);

  final AppDatabase _db;
  static const Logger _log = Logger('RelationshipSplitMigration');

  /// 审计 reason 标记（幂等判定依赖字符串精确匹配，不要改动既有值）
  static const String splitReason = '关系拆分迁移：个人关系按对象拆出';
  static const String restoreReason = '关系数据损坏修复：按历史恢复';
  static const String pendingReason = '关系数据待人工确认：无法从历史确定原值';

  /// 执行迁移（调用方须包事务——见类注释「语句级原子」；自身不再开事务）
  Future<void> run() async {
    final rows = await (_db.select(_db.factualAttributesTable)
          ..where(
            (t) => t.attrKey.equals('relationships') & t.source.equals('auto'),
          ))
        .get();

    if (rows.isEmpty) return;
    _log.info(
      'Relationship split migration scanning rows',
      detail: 'rows=${rows.length}',
    );

    // 会话级实体名索引缓存（session_id → 主名/别名 → 实体列表）
    final entityIndexBySession =
        <String, Map<String, List<FactualEntitiesTableData>>>{};

    for (final row in rows) {
      try {
        await _migrateRow(row, entityIndexBySession);
      } catch (e, s) {
        // 行级容错：不抛出（不阻塞升级/建库）；该行保持原样，尽力补写
        // 待确认标记留痕（注意：user_version 在 onUpgrade 成功后写入，
        // 版本推进后本行不会再被自动重跑——人工可按备份表+审计回溯处理）
        _log.error(
          'Relationship split migration row failed',
          detail: 'attributeId=${row.attributeId}, error=$e',
          error: e,
          stackTrace: s,
        );
        try {
          await _markPendingIfNeeded(row, valueTypeNote: '迁移行处理异常');
        } catch (_) {
          // 标记失败仅丢失可观测性，数据仍在（已备份）
        }
      }
    }
  }

  Future<void> _migrateRow(
    FactualAttributesTableData row,
    Map<String, Map<String, List<FactualEntitiesTableData>>>
        entityIndexBySession,
  ) async {
    await _backupRow(row);

    if (row.valueType == 'list') {
      // 错型 list 行：保留数据 + 待确认标记（幂等）
      await _markPendingIfNeeded(row, valueTypeNote: 'list 错型');
      return;
    }

    // dict 行（或历史遗留的其他类型）：按内容判定
    dynamic decoded;
    try {
      decoded = jsonDecode(row.value);
    } on FormatException {
      decoded = null;
    }

    if (decoded is List) {
      // 损坏：dict 类型存了 List 内容——尝试按历史恢复
      final restored = await _restoreFromHistory(row);
      if (restored == null) {
        await _markPendingIfNeeded(row, valueTypeNote: 'dict 存 List 内容');
        return;
      }
      await _splitDict(row, restored, entityIndexBySession);
      return;
    }

    if (decoded is Map<String, dynamic>) {
      await _splitDict(row, decoded, entityIndexBySession);
      return;
    }

    // 非 JSON 对象也非数组（无法解析/纯字符串）：待确认
    await _markPendingIfNeeded(row, valueTypeNote: '无法解析');
  }

  /// 逐行备份（幂等：同 attribute_id 只备份一次，保留最早原值）
  Future<void> _backupRow(FactualAttributesTableData row) async {
    final existing =
        await (_db.select(_db.factualRelationshipMigrationBackupTable)
              ..where((t) => t.attributeId.equals(row.attributeId))
              ..limit(1))
            .get();
    if (existing.isNotEmpty) return;
    await _db.into(_db.factualRelationshipMigrationBackupTable).insert(
          FactualRelationshipMigrationBackupTableCompanion.insert(
            attributeId: row.attributeId,
            sessionId: row.sessionId,
            entityId: row.entityId,
            attrKey: row.attrKey,
            valueType: row.valueType,
            value: row.value,
          ),
        );
  }

  /// 沿审计历史逆序找最近一条可解析为合法 JSON 对象的 oldValue，
  /// 恢复为当前值。无可确定证据返回 null（不猜测）。
  Future<Map<String, dynamic>?> _restoreFromHistory(
    FactualAttributesTableData row,
  ) async {
    final history = await (_db.select(_db.factualMemoryHistoryTable)
          ..where((t) => t.attributeId.equals(row.attributeId)))
        .get();
    history.sort((a, b) => b.createdAt.compareTo(a.createdAt));

    for (final entry in history) {
      final old = entry.oldValue;
      if (old == null) continue;
      try {
        final decodedOld = jsonDecode(old);
        if (decodedOld is Map<String, dynamic>) {
          final encoded = jsonEncode(decodedOld);
          await (_db.update(_db.factualAttributesTable)
                ..where((t) => t.attributeId.equals(row.attributeId)))
              .write(FactualAttributesTableCompanion(value: Value(encoded)));
          await _insertHistory(
            row,
            oldValue: row.value,
            newValue: encoded,
            reason: restoreReason,
          );
          _log.info(
            'Restored corrupted relationships value from history',
            detail: 'attributeId=${row.attributeId}',
          );
          return decodedOld;
        }
      } on FormatException {
        continue;
      }
    }
    return null;
  }

  /// 拆分 dict：个人关系（键唯一命中实体）拆出为 relationship:<主名>
  /// single 行；群体/未知/歧义留在 dict。
  Future<void> _splitDict(
    FactualAttributesTableData row,
    Map<String, dynamic> dict,
    Map<String, Map<String, List<FactualEntitiesTableData>>>
        entityIndexBySession,
  ) async {
    if (dict.isEmpty) return;
    final index =
        entityIndexBySession[row.sessionId] ??= await _buildEntityIndex(
      row.sessionId,
    );

    final remaining = <String, dynamic>{};
    var movedAny = false;
    for (final entry in dict.entries) {
      final objectName = entry.key.trim();
      final matches = index[objectName] ?? const <FactualEntitiesTableData>[];
      if (matches.length != 1) {
        // 群体表述 / 未知对象 / 歧义：保留在 dict
        remaining[entry.key] = entry.value;
        continue;
      }
      // 拆出行按命中实体的正式主名命名（别名命中同样归一）
      final canonicalName = matches.single.primaryName;
      final targetKey = 'relationship:$canonicalName';
      // 非字符串 dict 值（历史遗留嵌套结构）保 JSON 形态，不做 toString
      final valueText = entry.value is String
          ? entry.value as String
          : jsonEncode(entry.value);
      // 已存在同对象行（此前部分运行）：值相同则移除 dict 条目完成收敛，
      // 值不同则保留 dict 条目（不丢信息，不覆盖既有行）
      final existingRows = await (_db.select(_db.factualAttributesTable)
            ..where(
              (t) =>
                  t.entityId.equals(row.entityId) &
                  t.attrKey.equals(targetKey) &
                  t.source.equals('auto'),
            ))
          .get();
      if (existingRows.isEmpty) {
        const uuid = Uuid();
        final newAttributeId = 'attr_${uuid.v4()}';
        final now = DateTime.now();
        await _db.into(_db.factualAttributesTable).insert(
              FactualAttributesTableCompanion.insert(
                attributeId: newAttributeId,
                entityId: row.entityId,
                sessionId: row.sessionId,
                attrKey: targetKey,
                value: valueText,
                valueType: const Value('single'),
                source: const Value('auto'),
                createdAt: Value(now),
                updatedAt: Value(now),
                updatedTurn: Value(row.updatedTurn),
                updateReason: const Value(splitReason),
              ),
            );
        await _insertHistory(
          row,
          attributeIdOverride: newAttributeId,
          newValue: valueText,
          reason: splitReason,
        );
        movedAny = true;
      } else if (existingRows.first.value == valueText) {
        // 与既有行一致：仅从 dict 移除（收敛部分运行残留）
        movedAny = true;
      } else {
        remaining[entry.key] = entry.value;
      }
    }

    if (!movedAny) return;
    final newDictValue = jsonEncode(remaining);
    await (_db.update(_db.factualAttributesTable)
          ..where((t) => t.attributeId.equals(row.attributeId)))
        .write(FactualAttributesTableCompanion(value: Value(newDictValue)));
    await _insertHistory(
      row,
      oldValue: row.value,
      newValue: newDictValue,
      reason: splitReason,
    );
  }

  /// 待确认标记（幂等：同 attribute 已有标记不再重复写）
  Future<void> _markPendingIfNeeded(
    FactualAttributesTableData row, {
    required String valueTypeNote,
  }) async {
    final marked = await (_db.select(_db.factualMemoryHistoryTable)
          ..where(
            (t) =>
                t.attributeId.equals(row.attributeId) &
                t.reason.equals(pendingReason),
          )
          ..limit(1))
        .get();
    if (marked.isNotEmpty) return;
    await _insertHistory(
      row,
      oldValue: row.value,
      reason: pendingReason,
    );
    _log.warn(
      'Relationships row needs manual confirmation',
      detail: 'attributeId=${row.attributeId}, issue=$valueTypeNote',
    );
  }

  Future<void> _insertHistory(
    FactualAttributesTableData row, {
    required String reason,
    String? attributeIdOverride,
    String? oldValue,
    String? newValue,
  }) async {
    await _db.into(_db.factualMemoryHistoryTable).insert(
          FactualMemoryHistoryTableCompanion.insert(
            entityId: row.entityId,
            attributeId: Value(attributeIdOverride ?? row.attributeId),
            action: 'update_attr',
            turnNumber: row.updatedTurn ?? 0,
            oldValue: Value(oldValue),
            newValue: Value(newValue),
            reason: Value(reason),
          ),
        );
  }

  /// 会话实体名索引：主名与每个别名 → 实体列表（含归档实体，
  /// 已死亡角色的既有关系同样应拆出）
  Future<Map<String, List<FactualEntitiesTableData>>> _buildEntityIndex(
    String sessionId,
  ) async {
    final entities = await (_db.select(_db.factualEntitiesTable)
          ..where((t) => t.sessionId.equals(sessionId)))
        .get();
    final index = <String, List<FactualEntitiesTableData>>{};
    for (final entity in entities) {
      for (final name in [
        entity.primaryName,
        ..._decodeAliases(entity.aliases),
      ]) {
        index.putIfAbsent(name, () => []).add(entity);
      }
    }
    return index;
  }

  List<String> _decodeAliases(String aliasesJson) {
    if (aliasesJson.isEmpty) return const [];
    try {
      final decoded = jsonDecode(aliasesJson);
      if (decoded is List) return decoded.cast<String>();
    } on FormatException {
      return const [];
    }
    return const [];
  }
}
