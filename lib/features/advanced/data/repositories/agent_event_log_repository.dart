import 'dart:convert';

import 'package:drift/drift.dart' show Variable;

import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_durable_event.dart';
import 'package:lmstory/features/advanced/domain/services/agent_log_recovery.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';

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
class AgentEventLogRepository implements AgentEventLogStore {
  AgentEventLogRepository({
    required AppDatabase database,
    Logger? logger,
  })  : _database = database,
        _logger = logger;

  final AppDatabase _database;
  final Logger? _logger;

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
  }) async {
    final rows = await _database.customSelect(
      'SELECT seq, type, time, data, surface_op, replace_start, replace_end, '
      'source_event_seqs FROM agent_events WHERE session_id = ? '
      '${fromSeq != null ? 'AND seq >= ? ' : ''}'
      'ORDER BY seq ASC ${limit != null ? 'LIMIT ?' : ''}',
      variables: [
        Variable.withString(sessionId),
        if (fromSeq != null) Variable.withInt(fromSeq),
        if (limit != null) Variable.withInt(limit),
      ],
    ).get();

    return rows.map((row) {
      Map<String, dynamic> data;
      try {
        data = (jsonDecode(row.read<String>('data')) as Map)
            .cast<String, dynamic>();
      } catch (e) {
        _logger?.warn(
          'Agent event data corrupted',
          detail: 'seq=${row.read<int>('seq')}, error=$e',
        );
        data = {};
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
      return AgentDurableEvent(
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
      );
    }).toList();
  }

  /// 会话的最大 seq（无事件返回 -1）
  Future<int> lastSeq(String sessionId) async {
    final rows = await _database.customSelect(
      'SELECT MAX(seq) AS max_seq FROM agent_events WHERE session_id = ?',
      variables: [Variable.withString(sessionId)],
    ).get();
    return rows.first.readNullable<int>('max_seq') ?? -1;
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

  /// 删除指定轮的全部事件（：重生成前清理上一尝试）
  ///
  /// 找到该轮首个事件的 seq（事件 data.turn 标注轮号），自删其后全部。
  /// 必须在新尝试写入之前调用——删除先于写入，同 turn 在日志中仅保留
  /// 最新尝试（轮轨迹页与投影不再看到旧尝试残影）。无该轮事件时为空操作。
  ///
  /// system/frozen 豁免——冻结前缀按首写轮 stamp turn，若不豁免，
  /// 重生成 turn1 会把它整段删掉，而补写判据（_lastLoggedFrozenPrefix）
  /// 同会话内恒相等不再补写，投影从此永久缺失 system 前缀（缓存断点载体）。
  ///
  /// 返回是否删掉了 systemFrozen 事件：frozen 在 turn N 变更
  /// 后 stamp 的是 N，重生成更早轮时它落在删除区间内——调用方须据此
  /// 重置补写备忘，否则下轮不会重新落 frozen，投影用旧前缀与真实请求分叉。
  @override
  Future<bool> deleteTurnEvents(String sessionId, int turn) async {
    final events = await readEvents(sessionId);
    int? fromSeq;
    var deletedFrozen = false;
    // 判据 turn == N 改为 turn >= N——
    // 滚动保留把目标轮事件裁掉后（保留窗只留最近 N 轮），下游更晚轮的
    // 事件仍在：重生成该轮时按 == 找不到起点而 no-op，已删轮次的日志
    // 成幽灵（故事数据已回滚、事件日志残留，轮轨迹页仍可回放）。
    // 事件按 seq 追加、turn 随 seq 单调，首个 turn >= N 的事件即删除
    // 起点（目标轮事件在时行为不变：其首事件同样满足 >=）。
    for (final event in events) {
      final eventTurn = event.data['turn'];
      if (eventTurn is num &&
          eventTurn >= turn &&
          event.type != AgentEventTypes.systemFrozen) {
        fromSeq = event.seq;
        break;
      }
    }
    if (fromSeq != null) {
      final startSeq = fromSeq;
      deletedFrozen = events.any(
        (e) =>
            (e.seq ?? -1) >= startSeq && e.type == AgentEventTypes.systemFrozen,
      );
      await deleteFromSeq(sessionId, startSeq);
      _logger?.info(
        'Agent event turn truncated for regeneration',
        detail: 'sessionId=$sessionId, turn=$turn, fromSeq=$fromSeq, '
            'deletedFrozen=$deletedFrozen',
      );
    }
    return deletedFrozen;
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
      "AND type NOT LIKE 'system/%'",
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
