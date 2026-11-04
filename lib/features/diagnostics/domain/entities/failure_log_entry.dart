import 'package:meta/meta.dart';

/// 失败日志条目（诊断包）
///
/// 对应 `failure_logs` 表的持久化记录。与运行时 FailureContext（中级模式
/// 状态机内的失败上下文）不同，本实体是已落库的历史记录，供诊断页查看。
///
/// 设计决策：本实体含 `id`（数据库自增主键）。与业务实体（如 ExperientialMemory
/// 用 memoryId UUID）不同，日志记录无业务主键，自增 id 即为唯一标识，
/// 诊断页用 id 定位单条记录。这不违反 B-4 约束（B-4 针对业务实体不暴露 dbId）。
@immutable
class FailureLogEntry {
  const FailureLogEntry({
    required this.id,
    required this.sessionId,
    required this.mode,
    required this.errorCategory,
    required this.createdAt,
    this.errorCode,
    this.failedPhase,
    this.httpStatus,
    this.errorMessage,
    this.rawError,
    this.outcome,
  });

  /// 自增主键（诊断页定位/删除单条用）
  final int id;

  /// 所属会话 ID
  final String sessionId;

  /// 来源模式：'chat'（对话模式）| 'intermediate'（故事模式）| 'advanced'（v0.3）
  final String mode;

  /// 错误码：中级 E010-E018 / Simple S001-S0xx
  final String? errorCode;

  /// 失败阶段：generating/retrieving/reviewing/persisting/streaming
  /// Simple 模式无阶段划分，为 null
  final String? failedPhase;

  /// 错误分类（ErrorCategory.name）
  final String errorCategory;

  /// 终局标记：'failed' | 'recovered' | null（旧数据/未终局）——
  /// recovered = 引发这条日志的失败被自动重试救回（批 F / P8）
  final String? outcome;

  /// 是否已被自动重试救回
  bool get isRecovered => outcome == 'recovered';

  /// HTTP 状态码（非 HTTP 错误为 null）
  final int? httpStatus;

  /// 用户可见的 i18n 通俗提示
  final String? errorMessage;

  /// 原始异常信息（toString 截断）
  final String? rawError;

  /// 创建时间
  final DateTime createdAt;
}
