import 'package:lmstory/core/exceptions/app_exceptions.dart';

///  网络错误语义与重试工程：限流/诊断响应头与重试延迟的统一解析。
///
/// 承载方：[AppHttpException.headers]（wire 层从响应头拾取）；
/// 消费方：导演重试（agent_runner）与故事重试（RetryScheduler）的延迟决策、
/// SSE 解析器的语义错误码（semanticCodeForStatus）。

/// 解析 Retry-After 头为冷却时长
///
/// 三态：retry-after-ms（毫秒，优先）/ retry-after 纯整数（秒）/
/// retry-after HTTP-date（RFC 1123，与 [now] 差值，已过期返回 null）。
/// 均缺失或不可解析返回 null（调用方落回本地退避策略）。
Duration? parseRetryAfter({
  HttpErrorHeaders? headers,
  DateTime? now,
}) {
  final ms = headers?.retryAfterMs;
  if (ms != null) {
    final parsed = int.tryParse(ms.trim());
    if (parsed != null && parsed > 0) return Duration(milliseconds: parsed);
  }
  final raw = headers?.retryAfter?.trim();
  if (raw == null || raw.isEmpty) return null;

  final seconds = int.tryParse(raw);
  if (seconds != null) {
    return seconds > 0 ? Duration(seconds: seconds) : null;
  }
  final date = _parseHttpDate(raw);
  if (date != null) {
    final reference = now ?? DateTime.now();
    final delta = date.difference(reference);
    return delta > Duration.zero ? delta : null;
  }
  return null;
}

/// RFC 1123 HTTP-date（`Wed, 21 Oct 2015 07:28:00 GMT`）解析
DateTime? _parseHttpDate(String raw) {
  final match = _httpDatePattern.firstMatch(raw);
  if (match == null) return null;
  const months = {
    'Jan': 1,
    'Feb': 2,
    'Mar': 3,
    'Apr': 4,
    'May': 5,
    'Jun': 6,
    'Jul': 7,
    'Aug': 8,
    'Sep': 9,
    'Oct': 10,
    'Nov': 11,
    'Dec': 12,
  };
  final month = months[match.group(2)];
  if (month == null) return null;
  return DateTime.utc(
    int.parse(match.group(3)!),
    month,
    int.parse(match.group(1)!),
    int.parse(match.group(4)!),
    int.parse(match.group(5)!),
    int.parse(match.group(6)!),
  );
}

final RegExp _httpDatePattern = RegExp(
  r'(\d{1,2}) (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) '
  r'(\d{4}) (\d{2}):(\d{2}):(\d{2})',
);

/// 非零延迟加 ±25% jitter（[roll] ∈ [0,1) 注入便于测试；
/// 隐藏真实重试节奏，避免同批客户端同步重发）
Duration jitteredDelay(Duration base, double roll) {
  final scaled = base.inMilliseconds * (0.75 + roll * 0.5);
  return Duration(milliseconds: scaled.round());
}

/// Retry-After 冷却封顶（尊重长冷却但不无限等待； 与导演侧同口径）
const Duration maxRetryAfterDelay = Duration(seconds: 60);

/// HTTP 状态码 → wire 层语义错误码
///
/// 429→RATE_LIMIT、401/403→AUTH、5xx→SERVER、其余 4xx→BAD_REQUEST；
/// null/0（网络层失败等无状态码场景）返回 null，由调用方保持 STREAM_ERROR。
/// 上下文超限不在此映射（各家均以 400+文案承载，body 归一在网关
/// _normalizeError 的 overflow 模式匹配，见 AgentLlmErrorSemantic）。
String? semanticCodeForStatus(int? status) {
  if (status == 429) return 'RATE_LIMIT';
  if (status == 401 || status == 403) return 'AUTH';
  if (status != null && status >= 500) return 'SERVER';
  if (status != null && status >= 400) return 'BAD_REQUEST';
  return null;
}

/// 流异常 → 语义错误码（SSE 解析器 catch 统一使用）：
/// AppHttpException 按状态码映射，其余（解析错误/未知）保持 STREAM_ERROR
String streamErrorCodeOf(Object error) {
  if (error is AppHttpException) {
    if (error.code == 'response_start_timeout' ||
        error.code == 'non_streaming_timeout') {
      return error.code!;
    }
    return semanticCodeForStatus(error.statusCode) ?? 'STREAM_ERROR';
  }
  return 'STREAM_ERROR';
}

/// 流异常 → Retry-After 冷却时长（无结构化头时 null）
Duration? streamErrorRetryAfterOf(Object error) {
  if (error is AppHttpException) {
    return parseRetryAfter(headers: error.headers);
  }
  return null;
}
