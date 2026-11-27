import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Variable;

import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/chat/data/repositories/chat_repository_impl.dart';
import 'package:lmstory/features/memory/data/repositories/memory_fts_rebuilder.dart';
import 'package:lmstory/features/settings/data/repositories/backup_repository_impl.dart';

class _TransformedSnapshot {
  const _TransformedSnapshot({
    required this.session,
    required this.messages,
    required this.compactionPoints,
    required this.forkBranches,
    required this.experientialMemories,
    required this.factualEntities,
    required this.factualAttributes,
    required this.factualHistory,
    required this.intermediateArtifacts,
    required this.messageVariants,
    required this.agentEvents,
  });

  final Map<String, dynamic> session;
  final List<Map<String, dynamic>> messages;
  final List<Map<String, dynamic>> compactionPoints;
  final List<Map<String, dynamic>> forkBranches;
  final List<Map<String, dynamic>> experientialMemories;
  final List<Map<String, dynamic>> factualEntities;
  final List<Map<String, dynamic>> factualAttributes;
  final List<Map<String, dynamic>> factualHistory;
  final List<Map<String, dynamic>> intermediateArtifacts;
  final List<Map<String, dynamic>> messageVariants;
  final List<Map<String, dynamic>> agentEvents;
}

enum DemoHandoverResult {
  /// 本次导入成功
  imported,

  /// 正式库已有同 ID 会话（此前导入已成功，本次为崩溃后重跑）
  alreadyImported,

  /// 演示库中不存在源会话（无可交接）
  sourceMissing,
}

/// 演示会话交接（契约 §8）：demo 库 → 正式库。
///
/// 数据集合 = exportSessionData 全部 11 表（memories_fts 不搬、事务内
/// 经 rebuildSessionFts 重建；failure_logs 不搬）；变换 = 清空会话级
/// 虚拟模型引用与草稿列、剥离演示向量三字段；ID 全保留（每次 run 新
/// uuid，与正式库撞 id 概率≈0）。
///
/// 原子性与幂等：
/// - 正式库侧**单事务**（逐表 INSERT OR IGNORE + FTS 重建同事务）；
/// - 崩溃窗口 A（事务提交前）→ 回滚零残留，重试全量导入；
/// - 崩溃窗口 B（提交后、状态标记前）→ 重试时同 ID 全部 IGNORE，
///   会话行已存在 → [DemoHandoverResult.alreadyImported]；
/// - **不宣称跨两个数据库的分布式原子事务**——幂等由同 ID IGNORE
///   与「会话行存在即已导入」判定共同保证；
/// - 成功后清理 demo 库源会话（best-effort，失败不回滚交接）。
class DemoSessionHandover {
  /// [failBeforeCommit] 仅测试注入：在正式库事务体末尾抛错，
  /// 模拟「导入提交前崩溃」。
  DemoSessionHandover({void Function()? failBeforeCommit})
      : _failBeforeCommit = failBeforeCommit;

  final void Function()? _failBeforeCommit;

  Future<DemoHandoverResult> run({
    required AppDatabase demoDb,
    required AppDatabase realDb,
    required String sourceSessionId,
  }) async {
    // 幂等判定：正式库已有同 ID 会话 = 上次导入已成功
    final existing = await realDb.customSelect(
      'SELECT session_id FROM chat_sessions WHERE session_id = ?',
      variables: [Variable.withString(sourceSessionId)],
    ).get();
    if (existing.isNotEmpty) {
      await _cleanupSource(demoDb, sourceSessionId);
      return DemoHandoverResult.alreadyImported;
    }

    // 源快照（demo 库单事务导出）
    // 源会话存在性预检（避免依赖 repo 对缺失会话抛 StateError 的实现细节）
    final sourceExists = await demoDb.customSelect(
      'SELECT session_id FROM chat_sessions WHERE session_id = ?',
      variables: [Variable.withString(sourceSessionId)],
    ).get();
    if (sourceExists.isEmpty) {
      return DemoHandoverResult.sourceMissing;
    }
    final snapshot = await BackupRepositoryImpl(database: demoDb)
        .exportSessionData(sourceSessionId);

    // 变换（导入前一次性改写快照行）
    final t = _transformSnapshot(snapshot);

    // 正式库单事务导入（表序：会话行先入，子表随后）
    await realDb.transaction(() async {
      await _restoreTable(realDb, 'chat_sessions', [t.session]);
      await _restoreTable(realDb, 'chat_messages', t.messages);
      await _restoreTable(realDb, 'compaction_points', t.compactionPoints);
      await _restoreTable(realDb, 'chat_session_branches', t.forkBranches);
      await _restoreTable(
        realDb,
        'experiential_memories',
        t.experientialMemories,
      );
      await _restoreTable(realDb, 'factual_entities', t.factualEntities);
      await _restoreTable(realDb, 'factual_attributes', t.factualAttributes);
      await _restoreTable(realDb, 'factual_memory_history', t.factualHistory);
      await _restoreTable(
        realDb,
        'intermediate_round_artifacts',
        t.intermediateArtifacts,
      );
      await _restoreTable(realDb, 'message_variants', t.messageVariants);
      await _restoreTable(realDb, 'agent_events', t.agentEvents);
      // FTS 同事务重建（memoriesFts 行不搬；正式库索引从记忆行重建）
      await rebuildSessionFts(realDb, sourceSessionId);
      _failBeforeCommit?.call();
    });

    await _cleanupSource(demoDb, sourceSessionId);
    return DemoHandoverResult.imported;
  }

  /// 快照变换：清虚拟配置引用 + 剥离演示向量（契约 §8.1）
  ///
  /// 虚拟引用清理覆盖会话级**全部** preset/model 引用列（生成/抽取/
  /// 审阅/总结/推荐回复 + 兼容列）——不依赖具体虚拟 id 常量，任何
  /// demo-narrator-* 候选（多仿真模型）的引用都一并清空，正式会话
  /// 回退全局真实配置（空串=跟随全局）。
  _TransformedSnapshot _transformSnapshot(Map<String, dynamic> snapshot) {
    final session = _asMap(snapshot['session']);
    // 会话级虚拟 GM/各阶段模型覆盖 → 回退全局真实配置（空串=跟随全局）
    const modelRefColumns = <String>[
      'generating_preset_id',
      'generating_model_id',
      'extracting_preset_id',
      'extracting_model_id',
      'reviewing_preset_id',
      'reviewing_model_id',
      'summarizing_preset_id',
      'summarizing_model_id',
      'suggest_reply_preset_id',
      'suggest_reply_model_id',
      'preset_id',
      'model_id',
    ];
    for (final col in modelRefColumns) {
      session[col] = '';
    }
    // 演示固定提示词草稿不入正式库
    session['draft_input'] = null;
    session['director_pending_input'] = null;
    session['director_queued_input'] = null;

    final memories = _asList(snapshot['experientialMemories']).map((m) {
      // 演示向量与维度元数据不进真实嵌入空间；文本/FTS 保留，
      // 配置真实嵌入模型后经既有「重建向量索引」生成新向量
      final row = Map<String, dynamic>.from(m)
        ..remove('embedding')
        ..['has_embedding'] = 0
        ..['embedding_dimensions'] = null;
      return row;
    }).toList();

    return _TransformedSnapshot(
      session: session,
      messages: _asList(snapshot['messages']),
      compactionPoints: _asList(snapshot['compactionPoints']),
      forkBranches: _asList(snapshot['forkBranches']),
      experientialMemories: memories,
      factualEntities: _asList(snapshot['factualEntities']),
      factualAttributes: _asList(snapshot['factualAttributes']),
      factualHistory: _asList(snapshot['factualHistory']),
      intermediateArtifacts: _asList(snapshot['intermediateArtifacts']),
      messageVariants: _asList(snapshot['messageVariants']),
      agentEvents: _asList(snapshot['agentEvents']),
    );
  }

  Future<void> _restoreTable(
    AppDatabase db,
    String tableName,
    List<Map<String, dynamic>> rows,
  ) async {
    if (rows.isEmpty) return;
    final tableInfo =
        await db.customSelect('PRAGMA table_info($tableName)').get();
    final allowed = tableInfo.map((r) => r.data['name'].toString()).toSet();
    for (final row in rows) {
      final filtered = Map<String, dynamic>.from(row)
        ..remove('id')
        ..removeWhere((key, _) => !allowed.contains(key));
      if (filtered.isEmpty) continue;
      // embedding 残留（base64 字符串）不落正式库（变换已剥离，
      // 此处兜底防御）
      filtered.remove('embedding');
      final columns = filtered.keys.toList();
      final placeholders = List.filled(columns.length, '?').join(', ');
      await db.customStatement(
        'INSERT OR IGNORE INTO $tableName (${columns.join(', ')}) '
        'VALUES ($placeholders)',
        _variablesFor(filtered.values.toList()),
      );
    }
  }

  /// 正式库已导入后清理 demo 源会话（best-effort）
  Future<void> _cleanupSource(AppDatabase demoDb, String sessionId) async {
    try {
      await ChatRepositoryImpl(database: demoDb).deleteSession(sessionId);
    } catch (_) {
      // 清理失败不回滚交接；下次启动 handoverDone 态可静默补清
    }
  }

  List<Object?> _variablesFor(List<dynamic> values) {
    return values.map((v) {
      if (v == null || v is String || v is num || v is bool) return v;
      if (v is Uint8List) return v;
      if (v is List && v.isEmpty) return '[]';
      return jsonEncode(v);
    }).toList();
  }

  Map<String, dynamic> _asMap(dynamic v) {
    if (v is Map<String, dynamic>) return v;
    if (v is Map) return Map<String, dynamic>.from(v);
    return <String, dynamic>{};
  }

  List<Map<String, dynamic>> _asList(dynamic v) {
    if (v is! List) return const [];
    return v
        .map(
          (e) => e is Map<String, dynamic>
              ? e
              : (e is Map ? Map<String, dynamic>.from(e) : <String, dynamic>{}),
        )
        .where((e) => e.isNotEmpty)
        .toList();
  }
}
