import 'package:meta/meta.dart';

/// Simple 模式错误上下文（DOC-09B §9 扩展）
///
/// 携带错误码（S001-S009）、错误分类、HTTP 状态码、原始异常。
/// 比 FailureContext（中级模式）精简：Simple 模式无失败阶段（无状态机）
/// 和自动重试机制，故不含 failedPhase / retryable 字段。
///
/// 错误码体系（计划文件）：
/// - S001 config    配置错误（未配置供应商/模型/API Key）
/// - S002 network   网络错误（连接失败、DNS 失败）
/// - S003 auth      认证失败（401/403、API Key 无效）
/// - S004 rateLimit 限流（429）
/// - S005 server    服务器异常（5xx）
/// - S006 timeout   超时
/// - S007 format    响应格式异常
/// - S008 persist   本地存储失败
/// - S009 unknown   未知错误
///
/// [errorCategory] 用 String 而非 ErrorCategory 枚举，避免 Simple（chat）
/// domain 反向依赖 intermediate feature。String 值与 ErrorCategory.name 一致
/// （'config'/'network'/.../'unknown'），诊断页可统一展示。
@immutable
class SimpleErrorContext {
  const SimpleErrorContext({
    required this.errorCode,
    required this.errorCategory,
    this.httpStatus,
    this.rawError,
  });

  /// 错误码 S001-S009
  final String errorCode;

  /// 错误分类（'config'/'network'/'auth'/'rateLimit'/'server'/'timeout'/
  /// 'format'/'persist'/'unknown'，与 ErrorCategory.name 值一致）
  final String errorCategory;

  /// HTTP 状态码（网络/服务器错误时携带，便于诊断页展示）
  /// 非 HTTP 错误（如格式异常、配置缺失）为 null。
  final int? httpStatus;

  /// 原始异常 toString() 截断前 500 字符，供技术用户诊断。
  final String? rawError;
}
