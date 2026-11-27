import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:lmstory/core/exceptions/app_exceptions.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/memory/data/database/embedding_dimensions_backfill.dart';
import 'package:lmstory/features/memory/data/repositories/memory_fts_rebuilder.dart';
import 'package:lmstory/features/settings/domain/entities/data_management_models.dart';
import 'package:lmstory/features/settings/domain/repositories/backup_repository.dart';

/// BackupRepository 实现
///
/// 使用 drift 的 customSelect / customStatement 进行原始行级别的批量读写，
/// 保留原始业务 ID，确保导出再导入后数据完全无损。
class BackupRepositoryImpl implements BackupRepository {
  BackupRepositoryImpl({required AppDatabase database}) : _database = database;

  final AppDatabase _database;

  // 会话级表名（含 session_id 列）
  static const _tSessions = 'chat_sessions';
  static const _tMessages = 'chat_messages';
  static const _tCompactionPoints = 'compaction_points';
  static const _tForkBranches = 'chat_session_branches';
  static const _tExperientialMemories = 'experiential_memories';
  static const _tFactualEntities = 'factual_entities';
  static const _tFactualAttributes = 'factual_attributes';
  static const _tRelationshipMigrationBackup =
      'factual_relationship_migration_backup';
  static const _tFactualHistory = 'factual_memory_history';
  static const _tIntermediateArtifacts = 'intermediate_round_artifacts';
  static const _tMessageVariants = 'message_variants';
  static const _tMemoriesFts = 'memories_fts';
  static const _tFactualFts = 'factual_fts';
  static const _tFailureLogs = 'failure_logs';
  static const _tApiPresets = 'api_presets';
  // v3 全局资产表（backupVersion 3，2026-09-02）
  static const _tCharacterCards = 'character_cards';
  static const _tWorldbooks = 'worldbooks';
  static const _tTemplates = 'templates';
  static const _tAgentEvents = 'agent_events';

  /// 所有含 session_id 列的会话级表（factual_memory_history 除外）
  ///
  ///  修复：failure_logs 移出——诊断数据不属于用户叙事资产，
  /// 且经  修复前的历史数据可能含未脱敏原始异常，不应随备份出设备。
  /// 旧备份中的 failureLogs 键在导入侧被自然忽略（不再读取）。
  static const _sessionTables = [
    _tSessions,
    _tMessages,
    _tCompactionPoints,
    _tForkBranches,
    _tExperientialMemories,
    _tFactualEntities,
    _tFactualAttributes,
    // v55 关系拆分迁移备份（会话叙事资产的迁移留档）随备份生命周期
    _tRelationshipMigrationBackup,
    _tIntermediateArtifacts,
    // schema v49 新表 message_variants 缺席全部数据
    // 生命周期链（导出不含/删除不删/覆盖导入残留幽灵变体可被切换物化）——
    // 同 commit 77e04a08 已知它属会话资产（copySession 随copy），漏的是
    // 备份/删除侧清单。agent_events（v44）之后第四次同型遗漏。
    _tMessageVariants,
  ];

  // ==================== 导出 ====================

  @override
  Future<Map<String, dynamic>> exportSessionData(String sessionId) async {
    // 导出链包单一事务快照——此前 11 段独立 SELECT
    // 与 persistRound 轮事务并发可产出「消息有/产物无」的撕裂备份（自动
    // 备份定时器与生成可同存）。事务内只读语句共享同一快照，保证
    // 跨表行数自洽。exportAllSessionsData 复用本方法即同获隔离。
    return _database.transaction(() async {
      final session = await _dumpSingle(_tSessions, 'session_id', sessionId);
      if (session == null) {
        throw StateError('Session not found: $sessionId');
      }

      final messages = await _dumpSessionMessages(sessionId);
      final compactionPoints =
          await _dumpTable(_tCompactionPoints, 'session_id', sessionId);
      final forkBranches =
          await _dumpTable(_tForkBranches, 'session_id', sessionId);
      final experientialMemories =
          await _dumpTable(_tExperientialMemories, 'session_id', sessionId);
      final factualEntities =
          await _dumpTable(_tFactualEntities, 'session_id', sessionId);
      final factualAttributes =
          await _dumpTable(_tFactualAttributes, 'session_id', sessionId);
      final relationshipMigrationBackup = await _dumpTable(
        _tRelationshipMigrationBackup,
        'session_id',
        sessionId,
      );

      // factual_memory_history 无 session_id 列，通过 entity_id 子查询过滤
      final factualHistory = await _dumpTableWithSubquery(
        _tFactualHistory,
        'entity_id IN (SELECT entity_id FROM $_tFactualEntities '
        'WHERE session_id = ?)',
        [sessionId],
      );

      final intermediateArtifacts =
          await _dumpTable(_tIntermediateArtifacts, 'session_id', sessionId);
      // 变体行随导出（artifacts 行的 current_variant_index 指针
      // 指向这些行；不导出即换机/回滚后变体全丢、指针悬空）
      final messageVariants =
          await _dumpTable(_tMessageVariants, 'session_id', sessionId);
      final memoriesFts =
          await _dumpTable(_tMemoriesFts, 'session_id', sessionId);
      // 导演事件日志随单会话导出——删除面
      // deleteSessionData 清 agent_events，导出缺该表会让「可再导入」
      // 承诺破功（覆盖导入净损失事件日志）。按 session_id 过滤行。
      final agentEvents =
          await _dumpTable(_tAgentEvents, 'session_id', sessionId);

      return {
        'session': session,
        'messages': messages,
        'compactionPoints': compactionPoints,
        'forkBranches': forkBranches,
        'experientialMemories': experientialMemories,
        'factualEntities': factualEntities,
        'factualAttributes': factualAttributes,
        'relationshipMigrationBackup': relationshipMigrationBackup,
        'factualHistory': factualHistory,
        'intermediateArtifacts': intermediateArtifacts,
        'messageVariants': messageVariants,
        'memoriesFts': memoriesFts,
        'agentEvents': agentEvents,
      };
    });
  }

  @override
  Future<List<Map<String, dynamic>>> exportAllSessionsData() async {
    final result = <Map<String, dynamic>>[];
    // 会话清单与逐会话导出同一事务
    // ——此前清单先出事务，循环中会话被并发删除会让 exportSessionData
    // 抛 ModelNotFoundException 整份备份中止；exportSessionData 自带的
    // 事务在此嵌套为 savepoint，单会话快照语义不变。跨域（供应商/
    // 偏好）仍为分快照读取（已知残余，见分册）。
    await _database.transaction(() async {
      final sessions = await _dumpTable(_tSessions);
      for (final session in sessions) {
        final sessionId = session['session_id'] as String?;
        if (sessionId != null) {
          result.add(await exportSessionData(sessionId));
        }
      }
    });
    return result;
  }

  // ==================== 导入 ====================

  @override
  Future<T> runInTransaction<T>(Future<T> Function() action) =>
      _database.transaction(action);

  @override
  Future<bool> containsMessageId(String id) async {
    final row = await _database.customSelect(
      'SELECT 1 FROM $_tMessages WHERE message_id = ?',
      variables: [Variable.withString(id)],
    ).getSingleOrNull();
    return row != null;
  }

  @override
  Future<BackupOverwriteState> readOverwriteState(
    Set<BackupDataDomain> domains,
  ) async {
    final sources = <String, String>{
      if (domains.contains(BackupDataDomain.sessions)) ...{
        for (final table in _sessionTables) table: '',
        _tFactualHistory: '',
        _tMemoriesFts: '',
        _tFactualFts: '',
        _tFailureLogs: '',
      },
      if (domains.contains(BackupDataDomain.sessions) ||
          domains.contains(BackupDataDomain.agentEvents))
        _tAgentEvents: '',
      if (domains.contains(BackupDataDomain.presets))
        _tApiPresets: 'WHERE is_built_in = 0',
      if (domains.contains(BackupDataDomain.characterCards))
        _tCharacterCards: '',
      if (domains.contains(BackupDataDomain.worldbooks)) _tWorldbooks: '',
      if (domains.contains(BackupDataDomain.userTemplates))
        _tTemplates: 'WHERE is_built_in = 0',
    };
    var hasData = false;
    final fingerprints = <String>[];
    final sessionIds = <Object?>{};
    final entityIds = <Object?>{};
    for (final source in sources.entries) {
      final table = source.key;
      final rows = await _database
          .customSelect('SELECT * FROM $table ${source.value} ORDER BY rowid')
          .get();
      // 失败日志属于诊断数据，会随事务回退，但不写进可移植备份。
      if (rows.isNotEmpty && table != _tFailureLogs) hasData = true;
      if (table == _tSessions) {
        sessionIds.addAll(rows.map((row) => row.data['session_id']));
      } else if (_sessionTables.contains(table) &&
          rows.any((row) => !sessionIds.contains(row.data['session_id']))) {
        // 可移植备份从现有会话出发导出，孤立正文或记忆无法从中恢复。
        throw StateError('Session data without a restorable owner');
      }
      if (table == _tFactualEntities) {
        entityIds.addAll(rows.map((row) => row.data['entity_id']));
      }
      if (table == _tFactualHistory &&
          rows.any((row) => !entityIds.contains(row.data['entity_id']))) {
        throw StateError('Fact history without a restorable owner');
      }
      final content = jsonEncode(rows.map((row) => row.data).toList());
      fingerprints.add(sha256.convert(utf8.encode(content)).toString());
    }
    return (hasData: hasData, fingerprint: fingerprints.join(','));
  }

  @override
  Future<int> importSessionData(
    Map<String, dynamic> data, {
    required ImportMode mode,
  }) async {
    final sessionRow = _asMap(data['session']);
    final sessionId = sessionRow['session_id'] as String?;

    if (sessionId == null || sessionId.isEmpty) {
      throw const FormatException('Missing session_id in backup data');
    }

    // 单会话的删除、插入和索引重建一起提交。整文件覆盖时，每条
    // 会话在外层事务内使用独立保存点。
    final imported = _database.transaction(
      () async {
        // 追加模式：sessionId 已存在则跳过（-1 与空会话导入成功区分）。
        if (mode == ImportMode.append) {
          final existing =
              await _dumpSingle(_tSessions, 'session_id', sessionId);
          if (existing != null) return -1;
        }
        final experiences = _asList(data['experientialMemories']);
        var hasMissingOwner = false;
        for (final row in experiences) {
          final owner = row['session_id'];
          if (owner is! String || owner.isEmpty) {
            hasMissingOwner = true;
          } else if (owner != sessionId) {
            throw const BackupExperienceIdConflictException.ownerMismatch();
          }
        }
        if (hasMissingOwner) {
          throw const FormatException(
            'Missing session_id in backup experience',
          );
        }
        if (mode == ImportMode.overwrite) {
          await _deleteSessionDataInner(sessionId);
        }
        final insertedSessions = await _restoreTable(_tSessions, [sessionRow]);
        if (insertedSessions == 0) {
          throw const FormatException(
            'Could not restore session row from backup',
          );
        }
        final insertedMessages =
            await _restoreTable(_tMessages, _rowsBySourceId(data['messages']));
        await _restoreTable(
          _tCompactionPoints,
          _asList(data['compactionPoints']),
        );
        await _restoreTable(_tForkBranches, _asList(data['forkBranches']));
        await _restoreExperientialMemories(sessionId, experiences);
        await _restoreTable(
          _tFactualEntities,
          _asList(data['factualEntities']),
        );
        await _restoreTable(
          _tFactualAttributes,
          _asList(data['factualAttributes']),
        );
        // v55 迁移备份随导入恢复（旧导出文件缺键 → 空清单不导入）
        await _restoreTable(
          _tRelationshipMigrationBackup,
          _asList(data['relationshipMigrationBackup']),
        );
        await _restoreTable(
          _tFactualHistory,
          _rowsBySourceId(data['factualHistory']),
        );
        await _restoreTable(
          _tIntermediateArtifacts,
          _asList(data['intermediateArtifacts']),
        );
        // 恢复变体行（旧导出文件缺键 → 空清单不导入，向后兼容）
        await _restoreTable(
          _tMessageVariants,
          _asList(data['messageVariants']),
        );
        // 恢复导演事件日志（覆盖导入 deleteSessionData 已先删该表，
        // 不恢复即净损失）。旧导出文件缺键 → _asList 空清单不导入（向后兼容）。
        await _restoreTable(_tAgentEvents, _asList(data['agentEvents']));
        //  修复：failure_logs 不再随会话备份导入（旧备份中的键被忽略）

        // FTS5 索引：不按备份行搬运，统一由落库主表重建（见
        // memory_fts_rebuilder.rebuildSessionFts）——备份可能缺键（旧格式/手裁）
        // 或含被 INSERT OR IGNORE 跳过的行，按 JSON 建索引会指向不存在的行。
        // 2026-09-09 审查（FF6）：factual_fts 与 memories_fts 一起重建。
        await rebuildSessionFts(_database, sessionId);
        // 旧备份的 experiential_memories 行缺
        // embedding_dimensions 键 → 落库为 NULL——导入即回填，不等下次开库。
        await backfillEmbeddingDimensions(_database);
        return insertedMessages;
      },
      requireNew: true,
    );
    return imported.onError<CouldNotRollBackException>(
      (_, stackTrace) => Error.throwWithStackTrace(
        const SavepointRollbackException(),
        stackTrace,
      ),
    );
  }

  // ==================== 删除 ====================

  @override
  Future<void> deleteSessionData(String sessionId) async {
    await _database.transaction(() async {
      await _deleteSessionDataInner(sessionId);
    });
  }

  /// 删除单会话全部衍生数据（不自带事务）——供 [deleteSessionData]
  /// （独立事务）与覆盖导入（与插新同事务）复用。
  Future<void> _deleteSessionDataInner(String sessionId) async {
    // 删除 FTS5 索引
    await _database.customStatement(
      'DELETE FROM $_tMemoriesFts WHERE session_id = ?',
      [sessionId],
    );
    //  世界书词条索引/导演事件日志/失败日志
    // 同属会话衍生数据——单会话覆盖导入不清会造成新旧数据混排
    //（旧导演事件重放错乱、旧失败详情残留）。
    await _database.customStatement(
      'DELETE FROM factual_fts WHERE session_id = ?',
      [sessionId],
    );
    await _database.customStatement(
      'DELETE FROM agent_events WHERE session_id = ?',
      [sessionId],
    );
    await _database.customStatement(
      'DELETE FROM failure_logs WHERE session_id = ?',
      [sessionId],
    );
    // 删除 factual_memory_history（通过子查询）
    await _database.customStatement(
      'DELETE FROM $_tFactualHistory WHERE entity_id IN '
      '(SELECT entity_id FROM $_tFactualEntities WHERE session_id = ?)',
      [sessionId],
    );
    // 删除其他含 session_id 的表
    for (final table in _sessionTables) {
      await _database.customStatement(
        'DELETE FROM $table WHERE session_id = ?',
        [sessionId],
      );
    }
  }

  @override
  Future<void> deleteAllSessionData() async {
    await _database.transaction(() async {
      await _database.customStatement('DELETE FROM $_tMemoriesFts');
      await _database.customStatement('DELETE FROM $_tFactualHistory');
      //  补齐：世界书词条索引与导演事件日志也属会话衍生
      // 数据——不清理会成为覆盖导入后的孤儿（检索命中已删实体/隐私残留）。
      await _database.customStatement('DELETE FROM factual_fts');
      await _database.customStatement('DELETE FROM agent_events');
      //  失败日志同属会话衍生数据，全量清除一并清空
      await _database.customStatement('DELETE FROM failure_logs');
      for (final table in _sessionTables) {
        await _database.customStatement('DELETE FROM $table');
      }
    });
  }

  // ==================== FTS5 重建 ====================
  // rebuildFtsIndex/rebuildAllFtsIndex 两个死方法已
  // 删除——零调用方，且 memory_type 列口径与活代码冲突（此处写
  // memory_level 值，memory_fts_rebuilder 硬编码 'experiential'；若未来
  // 接线死代码，同一表两处产出不同 memory_type）。FTS 重建唯一正路是
  // memory_fts_rebuilder.rebuildSessionFts（导入侧在用）。

  // ==================== 供应商数据 ====================

  @override
  Future<List<Map<String, dynamic>>> exportAllPresets() async {
    return _dumpTable(_tApiPresets);
  }

  @override
  Future<bool> importPreset(
    Map<String, dynamic> data, {
    required ImportMode mode,
  }) async {
    final presetId = data['preset_id'] as String?;
    if (presetId == null || presetId.isEmpty) return false;

    // 内置供应商始终跳过（#23 / ：永不预装——内置行不再
    // 由应用创建，仅历史备份里可能携带，导入时同样不落库）。
    //  修复：列名此前误写 is_builtin（实际列 is_built_in），
    // 导出行里该键恒为 null——内置供应商从不命中跳过分支。
    final isBuiltIn = data['is_built_in'];
    if (isBuiltIn == 1 || isBuiltIn == true) return false;

    // 追加模式：presetId 已存在则跳过
    if (mode == ImportMode.append) {
      final existing = await _dumpSingle(_tApiPresets, 'preset_id', presetId);
      if (existing != null) return false;
    }

    return (await _restoreTable(_tApiPresets, [data])) > 0;
  }

  @override
  Future<void> deleteAllCustomPresets() async {
    //  修复：列名此前误写 is_builtin（实际列 is_built_in），
    // 该 DELETE 在 prepare 阶段即抛 no such column——覆盖导入含供应商键
    // 时必然失败（本路径此前零测试）。
    await _database.customStatement(
      'DELETE FROM $_tApiPresets WHERE is_built_in = 0',
    );
  }

  // ==================== 全局资产（v3 备份格式） ====================

  /// v3 全局资产导出键 → 表名映射（行级 dump 自动跟随 schema）
  static const _globalAssetTables = {
    'characterCards': _tCharacterCards,
    'worldbooks': _tWorldbooks,
    'agentEvents': _tAgentEvents,
  };

  @override
  Future<Map<String, List<Map<String, dynamic>>>> exportGlobalAssets({
    bool includeAgentEvents = true,
  }) async {
    final result = <String, List<Map<String, dynamic>>>{
      'characterCards': await _dumpTable(_tCharacterCards),
      'worldbooks': await _dumpTable(_tWorldbooks),
      // 自建模板：内置模板由应用启动重建，不属于用户数据
      'userTemplates': await _dumpTable(_tTemplates, 'is_built_in', 0),
      if (includeAgentEvents) 'agentEvents': await _dumpTable(_tAgentEvents),
    };
    return result;
  }

  @override
  Future<int> importGlobalAssets(
    Map<String, dynamic> data, {
    required ImportMode mode,
  }) async {
    var inserted = 0;
    await _database.transaction(() async {
      // 覆盖模式：先清空对应表现有数据（templates 仅自建行，内置保留）
      if (mode == ImportMode.overwrite) {
        // 三资产表对齐 agent_events 的键存在性判定
        // ——备份缺某资产键时该表不被清空重建（此前手裁/第三方 v3 变体
        // 缺 characterCards 键会把本机角色卡整表清零且只恢复 0 行，
        // 属未声明删除）。自家导出全键全写，正常链路不受影响。
        if (data.containsKey('characterCards')) {
          await _database.customStatement('DELETE FROM $_tCharacterCards');
        }
        if (data.containsKey('worldbooks')) {
          await _database.customStatement('DELETE FROM $_tWorldbooks');
        }
        if (data.containsKey('userTemplates')) {
          await _database.customStatement(
            'DELETE FROM $_tTemplates WHERE is_built_in = 0',
          );
        }
        // agent_events 属会话衍生数据（deleteSessionData
        // 同口径）——仅当备份实际携带事件行时才清除重建。空库设备导出的
        // 备份 agentEvents 为空数组，照删会把本机会话的事件日志连带清空，
        // 与「空会话备份覆盖不影响任何会话」的 UI 承诺相悖。
        final agentEvents = data['agentEvents'];
        if (agentEvents is List && agentEvents.isNotEmpty) {
          await _database.customStatement('DELETE FROM $_tAgentEvents');
        }
      }
      for (final entry in _globalAssetTables.entries) {
        // 缺键跳过恢复（与上方删除门控对称——缺键=该域不动）
        if (!data.containsKey(entry.key)) continue;
        inserted += await _restoreTable(entry.value, _asList(data[entry.key]));
      }
      if (data.containsKey('userTemplates')) {
        inserted +=
            await _restoreTable(_tTemplates, _asList(data['userTemplates']));
      }
    });
    return inserted;
  }

  // ==================== 私有方法：导出 ====================

  Future<List<Map<String, dynamic>>> _dumpSessionMessages(
    String sessionId,
  ) async {
    final rows = await _database.customSelect(
      'SELECT * FROM $_tMessages WHERE session_id = ? ORDER BY id',
      variables: [Variable.withString(sessionId)],
    ).get();
    return rows.map((row) => _sanitizeRow(row.data)).toList();
  }

  /// 导出表中匹配条件的所有行
  Future<List<Map<String, dynamic>>> _dumpTable(
    String tableName, [
    String? whereColumn,
    Object? whereValue,
  ]) async {
    final sql = whereColumn != null
        ? 'SELECT * FROM $tableName WHERE $whereColumn = ?'
        : 'SELECT * FROM $tableName';
    final vars = whereValue != null
        ? <Variable<Object>>[Variable(whereValue)]
        : <Variable<Object>>[];
    final rows = await _database.customSelect(sql, variables: vars).get();
    return rows.map((row) => _sanitizeRow(row.data)).toList();
  }

  /// 导出单行
  Future<Map<String, dynamic>?> _dumpSingle(
    String tableName,
    String whereColumn,
    Object whereValue,
  ) async {
    final rows = await _dumpTable(tableName, whereColumn, whereValue);
    return rows.isEmpty ? null : rows.first;
  }

  /// 使用子查询导出
  Future<List<Map<String, dynamic>>> _dumpTableWithSubquery(
    String tableName,
    String whereClause,
    List<Object> whereArgs,
  ) async {
    final sql = 'SELECT * FROM $tableName WHERE $whereClause';
    final vars = whereArgs.map(Variable<Object>.new).toList();
    final rows = await _database.customSelect(sql, variables: vars).get();
    return rows.map((row) => _sanitizeRow(row.data)).toList();
  }

  /// 将数据库行转换为可 JSON 序列化的 Map
  ///
  /// 主要处理 BLOB -> base64 转换（embedding 列）。
  Map<String, dynamic> _sanitizeRow(Map<String, dynamic> data) {
    final result = Map<String, dynamic>.from(data);
    final embedding = result['embedding'];
    if (embedding is Uint8List) {
      result['embedding'] = base64Encode(embedding);
    }
    return result;
  }

  // ==================== 私有方法：导入 ====================

  /// 新库分配自增主键前，先用备份里完整、唯一的原行号恢复入库顺序。
  /// 缺少可靠行号的备份沿用文件里的顺序。
  List<Map<String, dynamic>> _rowsBySourceId(Object? data) {
    final rows = _asList(data);
    final sourceIds = rows.map((row) => row['id']).whereType<int>().toSet();
    if (rows.length > 1 && sourceIds.length == rows.length) {
      rows.sort((a, b) => (a['id'] as int).compareTo(b['id'] as int));
    }
    return rows;
  }

  Future<void> _restoreExperientialMemories(
    String sessionId,
    List<Map<String, dynamic>> rows,
  ) async {
    final inserted = await _restoreTable(_tExperientialMemories, rows);
    if (inserted == rows.length) return;

    // 按 SQLite 的实际列值检查归属。TEXT 列也可能把数字 ID 写入为文本。
    var hasUnrestoredMemory = false;
    for (final row in rows) {
      final Object? memoryId = row['memory_id'];
      final existing = await _database.customSelect(
        'SELECT session_id FROM $_tExperientialMemories WHERE memory_id = ?',
        variables: [Variable(memoryId)],
      ).getSingleOrNull();
      if (existing == null) {
        hasUnrestoredMemory = true;
      } else if (existing.data['session_id'] != sessionId) {
        throw const BackupExperienceIdConflictException.existingOwner();
      }
    }
    if (hasUnrestoredMemory) {
      throw const FormatException(
        'Could not restore experience row from backup',
      );
    }
  }

  /// 将行数据批量插入表中（保留原始 ID，排除自增 id 列）
  ///
  /// 使用 INSERT OR IGNORE 避免唯一约束冲突。
  /// 恢复一张表的行（INSERT OR IGNORE），返回**实际插入**的行数。
  ///
  ///  修复：此前返回 void，调用方按 list 长度计数——
  /// OR IGNORE 撞 ID 静默丢行时导入摘要虚报。现以 sqlite changes() 为准。
  Future<int> _restoreTable(
    String tableName,
    List<Map<String, dynamic>> rows,
  ) async {
    if (rows.isEmpty) return 0;

    // 列名来自备份文件（外部输入），此前
    // 直接拼进 SQL 列清单——畸形/未来版本备份的未知列触发 'no such column'
    // 中断导入，此前会话已逐事务提交成部分导入。按表结构白名单过滤，
    // 未知列丢弃（行内全未知则跳过该行）。
    final tableInfo =
        await _database.customSelect('PRAGMA table_info($tableName)').get();
    final allowedColumns =
        tableInfo.map((r) => r.data['name'].toString()).toSet();

    var inserted = 0;
    for (final row in rows) {
      final filtered = Map<String, dynamic>.from(row)
        ..remove('id') // 排除自增主键，让数据库自动生成
        ..removeWhere((key, _) => !allowedColumns.contains(key));
      if (filtered.isEmpty) continue;

      // 恢复 embedding BLOB（base64 -> Uint8List）
      final embedding = filtered['embedding'];
      if (embedding is String) {
        try {
          filtered['embedding'] = base64Decode(embedding);
        } on FormatException {
          filtered.remove('embedding');
        }
      }
      // 只绑定 SQLite 支持的标量。坏 JSON 行直接跳过，下面真正的
      // SQLite 写入异常（如磁盘失败或触发器拒绝）由事务处理。
      if (filtered.values.any(
        (value) =>
            value != null &&
            value is! String &&
            value is! num &&
            value is! bool &&
            value is! Uint8List,
      )) {
        continue;
      }

      final columns = filtered.keys.toList();
      final values = filtered.values.toList();
      final placeholders = List.filled(columns.length, '?').join(', ');
      final sql = 'INSERT OR IGNORE INTO $tableName '
          '(${columns.join(', ')}) VALUES ($placeholders)';

      await _database.customStatement(sql, values);
      // sqlite3_changes()：最近一条 INSERT/UPDATE/DELETE 的影响行数——
      // OR IGNORE 撞 ID 时为 0，由此得到真实插入数（SELECT 不重置该值）
      final changesRow =
          await _database.customSelect('SELECT changes() AS n').getSingle();
      inserted += changesRow.data['n'] as int;
    }
    return inserted;
  }

  // ==================== 私有方法：工具 ====================

  /// 安全类型转换：dynamic -> Map<String, dynamic>
  Map<String, dynamic> _asMap(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    return {};
  }

  /// 安全类型转换：dynamic -> List<Map<String, dynamic>>
  List<Map<String, dynamic>> _asList(dynamic value) {
    if (value is! List) return const [];
    return value
        .map(
          (e) => e is Map<String, dynamic>
              ? e
              : e is Map
                  ? Map<String, dynamic>.from(e)
                  : <String, dynamic>{},
        )
        .where((e) => e.isNotEmpty)
        .toList();
  }
}
