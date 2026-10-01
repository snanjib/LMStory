import 'package:drift/drift.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/core/utils/secret_redactor.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/diagnostics/domain/entities/failure_log_entry.dart';
import 'package:lmstory/features/diagnostics/domain/repositories/failure_log_repository.dart';

/// FailureLogRepository 实现（诊断包，Data 层）
///
/// 使用 drift 实现 failure_logs 表的增删查。Repository 仅含纯数据存取（B-7）。
///
/// **失败降级策略**：日志是诊断辅助，写入/读取失败不应影响主流程。
/// 所有操作 catch 异常 → 记录到 Logger（落盘）→ 返回安全默认值（insertLog
/// 返回 id=-1 占位 entry；getRecentLogs 返回空列表；clearAll/deleteBySession
/// 返回 0）。调用方无需 try-catch。
class FailureLogRepositoryImpl implements FailureLogRepository {
  FailureLogRepositoryImpl({required AppDatabase database})
      : _database = database;

  final AppDatabase _database;
  static const _logger = Logger('FailureLogRepo');

  @override
  Future<FailureLogEntry> insertLog({
    required String sessionId,
    required String mode,
    required String errorCategory,
    String? errorCode,
    String? failedPhase,
    int? httpStatus,
    String? errorMessage,
    String? rawError,
  }) async {
    //  修复：入库前脱敏——rawError 携带原始异常原文（可能含
    // API Key/Authorization 头），且 failure_logs 会随会话备份导出到设备外；
    // redactSecrets 此前只在剪贴板复制路径使用，防线画错了地方。
    // 在此单一收口点处理，三个模式控制器的调用方无需各自处理。
    final safeErrorMessage =
        errorMessage == null ? null : redactSecrets(errorMessage);
    final safeRawError = rawError == null ? null : redactSecrets(rawError);
    final now = DateTime.now();
    try {
      final id = await _database.into(_database.failureLogsTable).insert(
            FailureLogsTableCompanion.insert(
              sessionId: sessionId,
              mode: mode,
              errorCategory: errorCategory,
              errorCode: Value(errorCode),
              failedPhase: Value(failedPhase),
              httpStatus: Value(httpStatus),
              errorMessage: Value(safeErrorMessage),
              rawError: Value(safeRawError),
              createdAt: now.millisecondsSinceEpoch,
            ),
          );
      //  修复：保留策略——仅保留最近 200 条。
      // failure_logs 此前无任何清理路径，无限增长且计入 dbSize。
      // 写入低频（每轮失败一次），此处顺带清理的开销可忽略。
      await _database.customStatement(
        'DELETE FROM failure_logs WHERE id NOT IN '
        '(SELECT id FROM failure_logs ORDER BY id DESC LIMIT 200)',
      );
      return FailureLogEntry(
        id: id,
        sessionId: sessionId,
        mode: mode,
        errorCategory: errorCategory,
        errorCode: errorCode,
        failedPhase: failedPhase,
        httpStatus: httpStatus,
        errorMessage: safeErrorMessage,
        rawError: safeRawError,
        createdAt: now,
      );
    } catch (e, s) {
      // 日志写入失败静默降级：记录到 Logger（落盘），返回 id=-1 占位 entry
      _logger.error('insertLog failed', error: e, stackTrace: s);
      return FailureLogEntry(
        id: -1,
        sessionId: sessionId,
        mode: mode,
        errorCategory: errorCategory,
        errorCode: errorCode,
        failedPhase: failedPhase,
        httpStatus: httpStatus,
        errorMessage: safeErrorMessage,
        rawError: safeRawError,
        createdAt: now,
      );
    }
  }

  @override
  Future<List<FailureLogEntry>> getRecentLogs({
    int limit = 50,
    String? mode,
    String? sessionId,
  }) async {
    try {
      final query = _database.select(_database.failureLogsTable)
        ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
        ..limit(limit);
      if (mode != null) {
        query.where((t) => t.mode.equals(mode));
      }
      if (sessionId != null) {
        query.where((t) => t.sessionId.equals(sessionId));
      }
      final rows = await query.get();
      return rows.map(_entryFromTyped).toList();
    } catch (e, s) {
      _logger.error('getRecentLogs failed', error: e, stackTrace: s);
      return const <FailureLogEntry>[];
    }
  }

  @override
  Future<void> clearAll() async {
    try {
      await _database.delete(_database.failureLogsTable).go();
    } catch (e, s) {
      _logger.error('clearAll failed', error: e, stackTrace: s);
    }
  }

  @override
  Future<int> deleteBySession(String sessionId) async {
    try {
      return await (_database.delete(_database.failureLogsTable)
            ..where((t) => t.sessionId.equals(sessionId)))
          .go();
    } catch (e, s) {
      _logger.error('deleteBySession failed', error: e, stackTrace: s);
      return 0;
    }
  }

  /// drift TypedResult → FailureLogEntry
  FailureLogEntry _entryFromTyped(FailureLogsTableData row) {
    return FailureLogEntry(
      id: row.id,
      sessionId: row.sessionId,
      mode: row.mode,
      errorCategory: row.errorCategory,
      errorCode: row.errorCode,
      failedPhase: row.failedPhase,
      httpStatus: row.httpStatus,
      errorMessage: row.errorMessage,
      rawError: row.rawError,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row.createdAt),
    );
  }
}
