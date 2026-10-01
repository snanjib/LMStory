/// 流式错误异常（：结构化携带 wire 层语义码与 Retry-After 冷却指示）
///
/// 原居 stream_runner（presentation）， 下沉至 domain 供失败分类器
/// 结构性识别（此前仅 toString 字符串特征匹配，语义码无处安放）。
/// stream_runner 仍 re-export 本类，既有 import 不受影响。
class StreamErrorException implements Exception {
  const StreamErrorException(this.message, {this.code, this.retryAfter});

  final String message;

  /// wire 层语义码（RATE_LIMIT/AUTH/SERVER/BAD_REQUEST/PARSE_ERROR/
  /// STREAM_ERROR…；null = 未识别）
  final String? code;

  /// Retry-After 冷却时长（限流场景服务端指示；null=无指示）
  final Duration? retryAfter;

  @override
  String toString() => 'StreamError: $message';
}
