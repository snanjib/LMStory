import 'package:lmstory/features/diagnostics/domain/entities/failure_log_entry.dart';

/// 失败日志仓储接口（诊断包，DOC-05 索引页待补充）
///
/// 持久化所有模式（Simple/Intermediate）的失败上下文。Repository 仅含纯数据
/// 存取（B-7 约束），业务逻辑（如何构造日志、何时写入）在 Controller。
///
/// 写入时机：Controller `_fail` 进入 failed 状态时调用 [insertLog]。
/// 读取时机：诊断页调用 [getRecentLogs] 列出最近 N 条。
/// 清理时机：诊断页清空按钮调用 [clearAll]；会话删除时由
/// ChatRepositoryImpl.deleteSession 在同一事务内直删 failure_logs。
abstract class FailureLogRepository {
  /// 插入一条失败日志，返回含回填 id 的 [FailureLogEntry]。
  ///
  /// [mode] 来源模式：'chat'（对话模式）| 'intermediate'（故事模式）| 'advanced'（v0.3）。
  /// [errorCategory] ErrorCategory.name（config/network/.../unknown）。
  /// [failedPhase] 失败阶段名（IntermediatePhase.name）；Simple 模式传 null。
  /// [rawError] 原始异常 toString（已截断）。
  ///
  /// 异常: QueryException (E301)
  Future<FailureLogEntry> insertLog({
    required String sessionId,
    required String mode,
    required String errorCategory,
    String? errorCode,
    String? failedPhase,
    int? httpStatus,
    String? errorMessage,
    String? rawError,
    String? outcome,
  });

  /// 获取最近 [limit] 条失败日志（按 createdAt 降序）。
  ///
  /// 可选过滤：[mode] 按模式；[sessionId] 按会话。
  /// 诊断页默认 limit=50，按时间倒序展示。
  ///
  /// 异常: QueryException (E301)
  Future<List<FailureLogEntry>> getRecentLogs({
    int limit = 50,
    String? mode,
    String? sessionId,
  });

  /// 表内失败日志总条数（滚动保留上限内的真实计数）。
  ///
  /// 诊断页概览用——列表只加载最近 50 条，计数若取列表长度会在
  /// 超 50 条时失真（表滚动保留 200 条）。
  ///
  /// 异常: QueryException (E301)
  Future<int> countAll();

  /// 清空所有失败日志（诊断页"清空"按钮，二次确认后调用）。
  ///
  /// 异常: QueryException (E301)
  Future<void> clearAll();

  /// 删除指定会话的全部失败日志（会话删除时级联清理）。
  ///
  /// 返回删除的行数。异常: QueryException (E301)
  Future<int> deleteBySession(String sessionId);

  /// 回写终局标记（2026-10-15 批 F / P8）：自动重试最终成功后把引发
  /// 重试的那条日志标记为 'recovered'——失败历史里能看出「这条是被
  /// 自动重试救回来的」。静默降级（不存在/写失败不抛）。
  Future<void> markRecovered(int logId);
}
