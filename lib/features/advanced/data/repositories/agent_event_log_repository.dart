import 'dart:convert';

import 'package:drift/drift.dart' show Variable;

import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_durable_event.dart';
import 'package:lmstory/features/advanced/domain/services/agent_log_recovery.dart';
import 'package:lmstory/features/advanced/domain/services/engineering_context_mode.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:uuid/uuid.dart';

/// Agent 会话事件日志仓库（append-only，唯一真相源）
///
/// 职责（设计报告 §7.3）：
/// - 追加事件（事务内分配连续 seq）
/// - 读取事件（全量 / 增量 fromSeq）
/// - 删除自某 seq 起的事件（仅用于用户显式回滚轮次，随故事数据一起删）
///
/// 投影（deriveAgentSurface / deriveAgentOutline）在 Domain 层纯函数实现，
/// 本仓库只做存取。写入时机由上层控制：turn 边界 flush + 语义检查点
/// （发 LLM 请求前保证请求前缀已持久，经 request 钩子 await flush）。
///
/// 实现 domain 声明的 [AgentEventLogStore] 抽象，
/// 供 AgentLogRecoveryService 依赖倒置（domain 不 import data 实现）。
class AgentEventLogRepository
    implements AgentLogMaintenanceStore, EngineeringContextSwitchStore {
  AgentEventLogRepository({
    required AppDatabase database,
    Logger? logger,
  })  : _database = database,
        _logger = logger;

  final AppDatabase _database;
  final Logger? _logger;

  @override
  Future<T> runLogMaintenance<T>(Future<T> Function() operation) =>
      _database.transaction(operation);

  // These predicates match the Dart decoder: skip malformed/non-object
  // payloads and distinguish the JSON boolean true from the numeric value 1.
  static const _validEventData =
      "CASE WHEN json_valid(data) THEN json_type(data) = 'object' ELSE 0 END";
  static const _mainEventData =
      "CASE WHEN json_valid(data) THEN json_type(data) = 'object' "
      r"AND json_type(data, '$.subagent') IS NOT 'true' ELSE 0 END";
  static const _projectedEvent = "surface_op IN ('append', 'replace')";

  /// 追加一个事件（seq 自动分配）——事件较多时用 [appendAll]
  Future<int> append(String sessionId, AgentDurableEvent event) async {
    final seqs = await appendAll(sessionId, [event]);
    return seqs.single;
  }

  /// 事务内批量追加（seq 连续分配），返回分配的 seq 列表
  @override
  Future<List<int>> appendAll(
    String sessionId,
    List<AgentDurableEvent> events,
  ) {
    if (events.isEmpty) return Future.value(const []);
    return _database.transaction(() async {
      final seqs = <int>[];
      var next = await _nextSeqInTransaction(sessionId);
      for (final event in events) {
        final seq = next++;
        await _database.customStatement(
          'INSERT INTO agent_events '
          '(session_id, seq, type, time, data, surface_op, replace_start, '
          ' replace_end, source_event_seqs) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
          // customStatement 直传原始值（Variable 仅用于 customSelect）
          [
            sessionId,
            seq,
            event.type,
            event.time.millisecondsSinceEpoch,
            jsonEncode(event.data),
            if (event.surfaceOp == null)
              null
            else if (event.surfaceOp == AgentSurfaceOpKind.append)
              'append'
            else
              'replace',
            event.replaceStart,
            event.replaceEnd,
            if (event.sourceEventSeqs.isEmpty)
              null
            else
              jsonEncode(event.sourceEventSeqs),
          ],
        );
        seqs.add(seq);
      }
      return seqs;
    });
  }

  /// 读取事件（seq 升序）
  @override
  Future<List<AgentDurableEvent>> readEvents(
    String sessionId, {
    int? fromSeq,
    int? limit,
  }) {
    return _readEventsWhere(
      sessionId,
      fromSeq != null ? 'seq >= $fromSeq' : null,
      limit: limit,
    );
  }

  /// 按附加条件读取事件行（seq 升序；[extraWhere] 为不含 session 过滤的
  /// 原生 SQL 片段，参数已内联安全值或由调用方受控拼接）
  Future<List<AgentDurableEvent>> _readEventsWhere(
    String sessionId,
    String? extraWhere, {
    int? limit,
    bool latestFirst = false,
    String dataExpression = 'data',
    bool includeSourceSeqs = true,
  }) async {
    final rows = await _database.customSelect(
      'SELECT id, seq, type, time, $dataExpression AS data, '
      'surface_op, replace_start, replace_end, '
      '${includeSourceSeqs ? 'source_event_seqs' : 'NULL AS source_event_seqs'} '
      'FROM agent_events WHERE session_id = ? '
      '${extraWhere != null ? 'AND ($extraWhere) ' : ''}'
      'ORDER BY seq ${latestFirst ? 'DESC' : 'ASC'} '
      '${limit != null ? 'LIMIT ?' : ''}',
      variables: [
        Variable.withString(sessionId),
        if (limit != null) Variable.withInt(limit),
      ],
    ).get();

    final events = <AgentDurableEvent>[];
    for (final row in rows) {
      Map<String, dynamic> data;
      try {
        data = (jsonDecode(row.read<String>('data')) as Map)
            .cast<String, dynamic>();
      } catch (e) {
        // HAR-02：损坏行跳过（不进返回列表）而非以 {} 空对象进投影
        // 产出空 assistant——消费方（deriveAgentSurface/恢复器）对缺失行
        // 容忍（投影少一条消息不破坏配对；恢复器本就处理未配对
        // tool/result）。日志含 id/type/seq 供诊断。
        _logger?.error(
          'Agent event data corrupted, row skipped',
          detail: 'sessionId=$sessionId, '
              'id=${row.read<int>('id')}, '
              'type=${row.read<String>('type')}, '
              'seq=${row.read<int>('seq')}, error=$e',
        );
        continue;
      }
      var sourceSeqs = const <int>[];
      final rawSource = row.readNullable<String>('source_event_seqs');
      if (rawSource != null && rawSource.isNotEmpty) {
        try {
          sourceSeqs = (jsonDecode(rawSource) as List).cast<int>();
        } catch (_) {
          sourceSeqs = const [];
        }
      }
      events.add(
        AgentDurableEvent(
          seq: row.read<int>('seq'),
          type: row.read<String>('type'),
          time: DateTime.fromMillisecondsSinceEpoch(row.read<int>('time')),
          data: data,
          surfaceOp: switch (row.readNullable<String>('surface_op')) {
            'append' => AgentSurfaceOpKind.append,
            'replace' => AgentSurfaceOpKind.replace,
            _ => null,
          },
          replaceStart: row.readNullable<int>('replace_start'),
          replaceEnd: row.readNullable<int>('replace_end'),
          sourceEventSeqs: sourceSeqs,
        ),
      );
    }
    return events;
  }

  /// 会话的最大 seq（无事件返回 -1）
  Future<int> lastSeq(String sessionId) async {
    final rows = await _database.customSelect(
      'SELECT MAX(seq) AS max_seq FROM agent_events WHERE session_id = ?',
      variables: [Variable.withString(sessionId)],
    ).get();
    return rows.first.readNullable<int>('max_seq') ?? -1;
  }

  /// 只读纪元边界事件（mode/epoch 行）——三态解析的廉价预检通道：
  /// 列非 true 的会话先查本方法，无纪元证据即普通旧会话（免全量读取）。
  @override
  Future<List<AgentDurableEvent>> readModeEpochEvents(String sessionId) {
    return _readEventsWhere(
      sessionId,
      "type = 'mode/epoch'",
    );
  }

  @override
  Future<List<AgentDurableEvent>> readEngineeringModeEvidence(
    String sessionId,
  ) {
    final knownTypes = kKnownSurfaceEventTypes.join("', '");
    return _readEventsWhere(
      sessionId,
      "type = '${AgentEventTypes.modeEpoch}' OR "
      "((type = '${AgentEventTypes.modeCapture}' "
      "OR ($_projectedEvent AND type NOT IN ('$knownTypes'))) AND "
      '($_validEventData))',
      // Capture bodies can duplicate the whole pre-epoch story. The mode
      // resolver only needs the capture's epoch and numeric set position.
      dataExpression: 'CASE '
          "WHEN type = '${AgentEventTypes.modeEpoch}' THEN data "
          "WHEN type = '${AgentEventTypes.modeCapture}' THEN json_object( "
          r"'epochId', CASE WHEN json_type(data, '$.epochId') = 'text' "
          r"THEN json_extract(data, '$.epochId') END, "
          r"'captureIndex', CASE WHEN json_type(data, '$.captureIndex') "
          r"IN ('integer', 'real') THEN json_extract(data, '$.captureIndex') END "
          ") ELSE '{}' END",
      includeSourceSeqs: false,
    );
  }

  @override
  Future<List<AgentDurableEvent>> readRecoveryCompactionEvents(
    String sessionId,
  ) =>
      _readEventsWhere(
        sessionId,
        "type IN ('${AgentEventTypes.compactionStart}', "
        "'${AgentEventTypes.compactionEnd}', '${AgentEventTypes.compactionUndo}', "
        "'${AgentEventTypes.compactionCancel}') AND ($_validEventData)",
        // Undo also stores the restored surface. Recovery needs only its key.
        dataExpression: 'json_object( '
            r"'opId', json_extract(data, '$.opId'), "
            r"'targetOpId', json_extract(data, '$.targetOpId') )",
        includeSourceSeqs: false,
      );

  @override
  Future<({bool hasDanglingTurn, List<int> orphanSeqs})> probeTurnRecovery(
    String sessionId,
  ) async {
    const lastBoundary = 'SELECT seq FROM agent_events '
        'WHERE session_id = ? AND type = ? AND ($_mainEventData) '
        'ORDER BY seq DESC LIMIT 1';
    final boundaries = await _database.customSelect(
      'SELECT ($lastBoundary) AS last_begin, ($lastBoundary) AS last_end',
      variables: [
        Variable.withString(sessionId),
        Variable.withString(AgentEventTypes.turnBegin),
        Variable.withString(sessionId),
        Variable.withString(AgentEventTypes.turnEnd),
      ],
    ).getSingle();
    final begin = boundaries.readNullable<int>('last_begin');
    final end = boundaries.readNullable<int>('last_end');
    if (begin != null && (end == null || end < begin)) {
      return (hasDanglingTurn: true, orphanSeqs: const <int>[]);
    }

    // Without any main begin, all projected rows outside a mode capture
    // are bootstrap orphans. Otherwise only inspect the closed turn's tail.
    final closedTurnEnd = begin == null ? null : end;
    final orphans = await _database.customSelect(
      'SELECT seq FROM agent_events WHERE session_id = ? '
      '${closedTurnEnd == null ? '' : 'AND seq > ? '}'
      'AND $_projectedEvent AND ($_validEventData) '
      'AND type != ? ORDER BY seq ASC',
      variables: [
        Variable.withString(sessionId),
        if (closedTurnEnd != null) Variable.withInt(closedTurnEnd),
        Variable.withString(AgentEventTypes.modeCapture),
      ],
    ).get();
    return (
      hasDanglingTurn: false,
      orphanSeqs: [for (final row in orphans) row.read<int>('seq')],
    );
  }

  @override
  Future<List<AgentDurableEvent>> readLatestUsageEvent(String sessionId) =>
      _readEventsWhere(
        sessionId,
        "type = '${AgentEventTypes.stepEnd}' AND "
        'CASE WHEN ($_mainEventData) THEN '
        r"json_type(data, '$.promptTokens') IN ('integer', 'real') "
        r"AND CAST(json_extract(data, '$.promptTokens') AS INTEGER) > 0 "
        'ELSE 0 END',
        limit: 1,
        latestFirst: true,
        includeSourceSeqs: false,
      );

  @override
  Future<void> applyEngineeringContextEnter({
    required String sessionId,
    required String epochId,
    required int fromTurn,
    required List<AgentDurableEvent> captureEvents,
  }) {
    // 同库单事务：pending enter → 捕获批量 → complete enter → 置会话列
    // true。中途任一步抛异常由 drift 整体回滚，库内不残留半截提交；
    // 非事务异常残留的 pending 交由三态解析按需要修复态保留。
    return _database.transaction(() async {
      await _writeEnterInTransaction(
        sessionId: sessionId,
        epochId: epochId,
        fromTurn: fromTurn,
        captureEvents: captureEvents,
      );
    });
  }

  @override
  Future<void> applyEngineeringContextEnterAtomic({
    required String sessionId,
    required String epochId,
    required Future<EngineeringEnterCapture> Function() prepare,
  }) {
    // 同快照进入：捕获读取（可见历史+产物）在写入事务内执行——期间
    // 并发写入被事务串行化排除，读快照与写入一致（不在事务外预读）。
    return _database.transaction(() async {
      final capture = await prepare();
      await _writeEnterInTransaction(
        sessionId: sessionId,
        epochId: epochId,
        fromTurn: capture.fromTurn,
        captureEvents: capture.captureEvents,
      );
    });
  }

  Future<void> _writeEnterInTransaction({
    required String sessionId,
    required String epochId,
    required int fromTurn,
    required List<AgentDurableEvent> captureEvents,
  }) async {
    final events = <AgentDurableEvent>[
      modeEpochEnterPendingEvent(epochId: epochId, fromTurn: fromTurn),
      ...captureEvents,
      modeEpochEnterCompleteEvent(
        epochId: epochId,
        captureCount: captureEvents.length,
      ),
    ];
    var next = await _nextSeqInTransaction(sessionId);
    for (final event in events) {
      await _insertEventAtSeq(sessionId, next++, event);
    }
    await _database.customUpdate(
      'UPDATE chat_sessions SET engineering_context_enabled = 1 '
      'WHERE session_id = ?',
      variables: [Variable.withString(sessionId)],
    );
  }

  @override
  Future<void> applyEngineeringContextExit({
    required String sessionId,
    String? epochId,
  }) {
    // 同库单事务：exit 事件（有未闭合纪元时）+ 会话列 false（用户确认
    // 退出后提交；epochId 为 null = true 列缺纪元的异常账本，仅置列）。
    return _database.transaction(() async {
      if (epochId != null && epochId.isNotEmpty) {
        final next = await _nextSeqInTransaction(sessionId);
        await _insertEventAtSeq(
          sessionId,
          next,
          modeEpochExitEvent(epochId: epochId),
        );
      }
      await _database.customUpdate(
        'UPDATE chat_sessions SET engineering_context_enabled = 0 '
        'WHERE session_id = ?',
        variables: [Variable.withString(sessionId)],
      );
    });
  }

  Future<void> _insertEventAtSeq(
    String sessionId,
    int seq,
    AgentDurableEvent event,
  ) {
    return _database.customStatement(
      'INSERT INTO agent_events '
      '(session_id, seq, type, time, data, surface_op, replace_start, '
      ' replace_end, source_event_seqs) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        sessionId,
        seq,
        event.type,
        event.time.millisecondsSinceEpoch,
        jsonEncode(event.data),
        if (event.surfaceOp == null)
          null
        else if (event.surfaceOp == AgentSurfaceOpKind.append)
          'append'
        else
          'replace',
        event.replaceStart,
        event.replaceEnd,
        if (event.sourceEventSeqs.isEmpty)
          null
        else
          jsonEncode(event.sourceEventSeqs),
      ],
    );
  }

  /// 删除自某 seq 起的全部事件（用户显式回滚轮次时随故事数据一起删）
  Future<void> deleteFromSeq(String sessionId, int fromSeq) {
    return _database.customStatement(
      'DELETE FROM agent_events WHERE session_id = ? AND seq >= ?',
      [sessionId, fromSeq],
    );
  }

  /// 按序号精确删除事件（：孤儿 surface 事件回收）
  ///
  /// 逐条删除而非区间截断——孤儿可能与非 surface 的 log-only 留痕
  /// （persist/* 等，带 turn 戳且合法存在于轮外）交错，区间删会误伤。
  @override
  Future<void> deleteAtSeqs(String sessionId, List<int> seqs) {
    if (seqs.isEmpty) return Future.value();
    return _database.transaction(() async {
      for (final seq in seqs) {
        await _database.customStatement(
          'DELETE FROM agent_events WHERE session_id = ? AND seq = ?',
          [sessionId, seq],
        );
      }
    });
  }

  /// 从指定轮或更晚的首个非冻结事件起截断日志。工程纪元的历史
  /// 捕获也有轮次边界，截断时维护当前模式与账本的一致性。
  ///
  /// 已落稿的轮次回退与故事持久化共用连接，正文、记忆和日志在同一
  /// 事务中更新。未落稿时先清理残留，让同一轮只保留最新尝试。
  ///
  /// 冻结前缀不单独作为截断点。如果它位于被截断的范围内，返回 true
  /// 供调用方清除补写备忘，并在下一轮重新写入。
  @override
  Future<bool> deleteTurnEvents(
    String sessionId,
    int turn, {
    Future<void> Function()? rollbackStory,
    Future<EngineeringEnterCapture> Function(String epochId)? captureHistory,
  }) {
    return _database.transaction(() async {
      await rollbackStory?.call();
      final events = await readEvents(sessionId);
      int? fromSeq;
      for (final event in events) {
        final eventTurn = event.data['turn'];
        // 开启时捕获了 fromTurn 之前的可见历史。旧轮日志即使已裁剪，
        // 回退到这个边界之前也必须移除包含旧正文的捕获。
        final captureFromTurn = event.type == AgentEventTypes.modeEpoch &&
                event.data['phase'] == kModeEpochPhaseEnter
            ? event.data['fromTurn']
            : null;
        if ((eventTurn is num &&
                eventTurn >= turn &&
                event.type != AgentEventTypes.systemFrozen) ||
            (captureFromTurn is num && captureFromTurn > turn)) {
          fromSeq = event.seq;
          break;
        }
      }
      final startSeq = fromSeq;
      if (startSeq == null) return false;

      final session = await _database.customSelect(
        'SELECT engineering_context_enabled FROM chat_sessions '
        'WHERE session_id = ?',
        variables: [Variable.withString(sessionId)],
      ).getSingleOrNull();
      final enabled =
          session?.readNullable<bool>('engineering_context_enabled');
      final mode = resolveEngineeringMode(enabled: enabled, events: events);
      if (mode.isBlocked) {
        throw StateError('Engineering context needs repair: ${mode.reason}');
      }
      final retained = events.takeWhile((e) => e.seq! < startSeq).toList();
      final retainedMode = resolveEngineeringMode(
        enabled: enabled,
        events: retained,
      );

      await deleteFromSeq(sessionId, startSeq);
      if (mode.isOpen && retainedMode.epochId != mode.epochId) {
        if (captureHistory == null) {
          throw StateError('Truncating the active epoch requires a capture');
        }
        final epochId = const Uuid().v4();
        final capture = await captureHistory(epochId);
        await _writeEnterInTransaction(
          sessionId: sessionId,
          epochId: epochId,
          fromTurn: capture.fromTurn,
          captureEvents: capture.captureEvents,
        );
      } else if (!mode.isOpen && retainedMode.isBlocked) {
        // 截断可以删到退出标记。若旧纪元还在，补齐其退出边界。
        final epochId = unclosedEpochIdOf(retained);
        if (epochId == null || epochId.isEmpty) {
          throw StateError('Cannot close the retained engineering epoch');
        }
        await _insertEventAtSeq(
          sessionId,
          await _nextSeqInTransaction(sessionId),
          modeEpochExitEvent(epochId: epochId),
        );
      }

      final deletedFrozen = events.any(
        (e) => e.seq! >= startSeq && e.type == AgentEventTypes.systemFrozen,
      );
      _logger?.info(
        'Agent event turn truncated for regeneration',
        detail: 'sessionId=$sessionId, turn=$turn, fromSeq=$startSeq, '
            'deletedFrozen=$deletedFrozen',
      );
      return deletedFrozen;
    });
  }

  /// 删除会话全部事件（会话删除时）
  Future<void> deleteAll(String sessionId) {
    return _database.customStatement(
      'DELETE FROM agent_events WHERE session_id = ?',
      [sessionId],
    );
  }

  /// 批 I：事件日志滚动保留——只留最近 [keepTurns]
  /// 轮的事件，更旧轮的**非 system** 行删除，返回删除行数。
  ///
  /// 程序消费面（崩溃恢复=当前轮、用量回填=最近轮、轨迹页=近期历史）
  /// 均不受影响；`system/frozen`（缓存断点前缀，按规则变更累积、量小）
  /// 与 `system/core`（投影折叠基准）永不删除。keepTurns<=0 = 不限制。
  ///
  /// HAR-01：`surface/replace`（溢出整面快照，唯一生产者=溢出自愈，
  /// 每轮至多一次、恒 replaceStart=0 含全量消息）与 system/% 同等豁免
  /// ——长会话（触发过溢出压缩）trim 后失败续跑/恢复的投影
  /// （deriveAgentSurface）依赖最后一条整面快照重建压缩摘要，删掉它
  /// 投影就永久丢失压缩前的一切。保留负担随溢出次数线性（低频 KB 级）。
  @override
  Future<int> trimToRecentTurns(String sessionId, int keepTurns) async {
    if (keepTurns <= 0) return 0;
    final cutoffRows = await _database.customSelect(
      r"SELECT CAST(json_extract(data,'$.turn') AS INTEGER) AS t "
      'FROM agent_events '
      r"WHERE session_id = ? AND json_extract(data,'$.turn') IS NOT NULL "
      'GROUP BY t ORDER BY t DESC LIMIT 1 OFFSET ?',
      variables: [
        Variable.withString(sessionId),
        Variable.withInt(keepTurns - 1),
      ],
    ).get();
    if (cutoffRows.isEmpty) return 0; // 轮数未超窗
    final cutoffTurn = cutoffRows.first.read<int>('t');
    final deleted = await _database.customUpdate(
      'DELETE FROM agent_events WHERE session_id = ? '
      r"AND CAST(json_extract(data,'$.turn') AS INTEGER) < ? "
      "AND type NOT LIKE 'system/%' "
      "AND type != 'surface/replace'",
      variables: [Variable.withString(sessionId), Variable.withInt(cutoffTurn)],
    );
    if (deleted > 0) {
      _logger?.info(
        'Agent event log trimmed',
        detail:
            'sessionId=$sessionId, keptTurns>=$cutoffTurn, deleted=$deleted',
      );
    }
    return deleted;
  }

  /// 全库事件日志用量（存储统计展示）：行数 + data 负载近似字节数
  ///
  /// 口径必须是字节——SQLite LENGTH(TEXT) 返回字符数，
  /// data 为 jsonEncode 未转义 CJK 文本，字符数会低估约 3 倍；
  /// CAST AS BLOB 后 LENGTH 按字节计。
  Future<({int count, int bytes})> eventsUsage() async {
    final rows = await _database
        .customSelect(
          'SELECT COUNT(*) AS c, '
          'COALESCE(SUM(LENGTH(CAST(data AS BLOB))), 0) AS bytes '
          'FROM agent_events',
        )
        .get();
    return (
      count: rows.first.read<int>('c'),
      bytes: rows.first.read<int>('bytes'),
    );
  }

  Future<int> _nextSeqInTransaction(String sessionId) async {
    final rows = await _database.customSelect(
      'SELECT MAX(seq) AS max_seq FROM agent_events WHERE session_id = ?',
      variables: [Variable.withString(sessionId)],
    ).get();
    return (rows.first.readNullable<int>('max_seq') ?? -1) + 1;
  }
}
