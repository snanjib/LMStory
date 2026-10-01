/// 应用级异常基类
class AppException implements Exception {
  const AppException(this.message, {this.code});

  final String message;
  final String? code;

  @override
  String toString() => 'AppException: $message';
}

/// 模型未找到异常 (E007)
class ModelNotFoundException extends AppException {
  const ModelNotFoundException(String modelId)
      : super('Model not found: $modelId', code: 'E007');
}

/// 无效配置异常 (E002)
class InvalidConfigurationException extends AppException {
  const InvalidConfigurationException(super.message) : super(code: 'E002');
}

/// 数据库查询异常 (E301)
class QueryException extends AppException {
  const QueryException(super.message) : super(code: 'E301');
}

/// 资源应用异常（世界书/角色卡投影，DOC-15）
///
/// 如「同名实体已存在，应用被拒绝」等投影前置校验失败时抛出。
class ResourceApplyException extends AppException {
  const ResourceApplyException(super.message) : super(code: 'E401');
}

/// Embedding API 限流异常 (E104)
///
/// 当 embedding API 返回 429 Too Many Requests 时抛出。
/// 由 EmbeddingRemoteDS 检测 statusCode==429 转换。
class EmbeddingRateLimitedException extends AppException {
  const EmbeddingRateLimitedException(String message)
      : super('Embedding rate limited: $message', code: 'E104');
}

/// 限流/诊断相关响应头子集
class HttpErrorHeaders {
  const HttpErrorHeaders({
    this.retryAfter,
    this.retryAfterMs,
    this.requestId,
  });

  /// Retry-After（RFC 7231：秒数或 HTTP-date）
  final String? retryAfter;

  /// Retry-After-Ms（毫秒，部分厂商扩展，优先于 [retryAfter]）
  final String? retryAfterMs;

  /// 请求 ID（x-request-id / request-id，诊断对账用）
  final String? requestId;

  /// 从原始响应头拾取相关子集（头名小写归一后查找）
  static HttpErrorHeaders? fromMap(Map<String, String>? raw) {
    if (raw == null || raw.isEmpty) return null;
    final normalized = <String, String>{
      for (final e in raw.entries) e.key.toLowerCase(): e.value,
    };
    String? get(String key) {
      final v = normalized[key];
      return v == null || v.isEmpty ? null : v;
    }

    final headers = HttpErrorHeaders(
      retryAfter: get('retry-after'),
      retryAfterMs: get('retry-after-ms'),
      requestId: get('x-request-id') ?? get('request-id'),
    );
    if (headers.retryAfter == null &&
        headers.retryAfterMs == null &&
        headers.requestId == null) {
      return null;
    }
    return headers;
  }
}

/// 应用级 HTTP 异常（避免与 dart:io.HttpException 冲突）
///
/// 统一承载网络层（HttpClient / DioClient）抛出的 HTTP 错误，
/// 供失败分类器（StoryFailureClassifier / SimpleFailureClassifier）
/// 按 statusCode / code 分流为 ErrorCategory。
///
/// 继承 [AppException]，纳入应用级异常统一层次结构，
/// 调用方可通过 `on AppException` 统一捕获所有应用级异常。
class AppHttpException extends AppException {
  const AppHttpException(
    super.message, {
    super.code,
    this.statusCode,
    this.uri,
    this.responseBody,
    this.headers,
  });

  /// HTTP 状态码（如 401、429、500）
  final int? statusCode;

  /// 请求 URI
  final Uri? uri;

  /// 响应体原文（供技术用户诊断 400 根因）
  final String? responseBody;

  /// 限流/诊断响应头子集（：Retry-After 贯穿重试链路；null=未拾取）
  final HttpErrorHeaders? headers;

  /// 含 response body 摘要的完整描述（前 500 字符）
  ///
  ///  修复：原实现仅输出 message，丢弃了供应商返回的具体错误原因
  /// （如 "response_format not supported"、"invalid schema" 等）。
  /// 错误链路 sse_parser → LlmStreamError → _StreamErrorException 依赖
  /// toString() 传递信息，丢失 body 导致用户无法定位 400 根因。
  @override
  String toString() {
    final body = responseBody;
    if (body == null || body.isEmpty) return 'AppHttpException: $message';
    final preview = body.length > 500 ? '${body.substring(0, 500)}...' : body;
    return 'AppHttpException: $message | Response: $preview';
  }
}

/// Embedding 调用失败异常 (E104)
///
/// 2026-07-21 新增：用于明确告知用户 embedding 调用失败，
/// 不再静默降级到 FTS5。异常会被失败分类器归为 E104 错误码，
/// 触发 FailureBar 显示，用户可选择重试/临时降级/中止。
///
/// 限流场景（HTTP 429）仍然使用 [EmbeddingRateLimitedException]，
/// 该异常也带 E104 code，会被分类器统一识别。
class EmbeddingCallFailedException extends AppException {
  const EmbeddingCallFailedException(String message)
      : super('Embedding call failed: $message', code: 'E104');
}
