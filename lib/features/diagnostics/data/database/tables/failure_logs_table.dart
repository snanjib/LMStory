import 'package:drift/drift.dart';

/// failure_logs 表定义（诊断包）
///
/// 持久化所有模式（Simple/Intermediate）的失败上下文，供诊断页
/// 按会话/分类/错误码过滤查看。与 FailureContext（运行时状态）不同，
/// 本表是历史记录的持久化载体。
///
/// 写入时机：Controller `_fail` 进入 failed 状态时（重试用尽或不可重试）。
/// 读取时机：诊断页列出最近 N 条，点击展开 rawError。
///
/// Schema 依据：计划文件 `v0.2收尾与真机测试支撑建设计划.md` 阶段2 ；
/// 设计文档同步在 （DOC-09B 补充诊断包设计）。
class FailureLogsTable extends Table {
  @override
  String get tableName => 'failure_logs';

  /// 自增主键（内部使用，Repository 不暴露）
  IntColumn get id => integer().autoIncrement()();

  /// 所属会话 ID（草稿会话用临时前缀 ID，也记录便于诊断）
  TextColumn get sessionId => text()();

  /// 来源模式：'chat'（对话模式）| 'intermediate'（故事模式）| 'advanced'（v0.3）
  TextColumn get mode => text()();

  /// 错误码：中级 E010-E018 / Simple S001-S0xx（计划）。可空预留。
  TextColumn get errorCode => text().nullable()();

  /// 失败阶段：generating/retrieving/reviewing/persisting/streaming。
  /// Simple 模式无阶段划分，可空。
  TextColumn get failedPhase => text().nullable()();

  /// 错误分类（ErrorCategory.name）：config/network/auth/rateLimit/
  /// server/timeout/format/persist/unknown。必填，诊断页按此过滤。
  TextColumn get errorCategory => text()();

  /// HTTP 状态码（网络/服务器错误时携带）。非 HTTP 错误为 null。
  IntColumn get httpStatus => integer().nullable()();

  /// 用户可见的 i18n 通俗提示。可空（理论上必填，预留防御）。
  TextColumn get errorMessage => text().nullable()();

  /// 原始异常信息（toString 截断）。 放宽到 2000 字符。
  /// 当前 FailureContext.rawError 截断 500 字符， 统一放宽。
  TextColumn get rawError => text().nullable()();

  /// 创建时间（毫秒时间戳，DateTime.millisecondsSinceEpoch）。
  /// 用 IntColumn 而非 DateTimeColumn：毫秒整数便于排序和跨时区处理。
  IntColumn get createdAt => integer()();
}
