import 'package:lmstory/core/network/retry_policy.dart';

/// Simple 模式自动重试薄壳（2026-10-15 批 E，P5/P8）
///
/// 消费共享 [RetryPolicy]（判定表/退避/预算单源， 契约层）：
/// 分类器（SimpleFailureClassifier 的 errorCategory）映射到共享语义码后
/// 查表——**不新写判定**。次数/预算上限读 network.auto_retry_* 配置
/// （由调用方构造 policy 传入）。
///
/// **零内容约束**：simple 侧仅在「零首字节」（firstTokenLatency == null）
/// 时自动重试——半截正文已进消息列表，整轮重发需要清消息（复杂且易错），
/// 有内容的流中断落现状 error 由用户手动处置；免费站典型病
/// （429/5xx/空响应/格式坏/早期断流）恰都发生在首字节之前。
class SimpleAutoRetry {
  /// 已用掉的自动重试次数
  int used = 0;

  /// 累计纯等待（预算闸输入）
  Duration cumulativeWait = Duration.zero;

  /// 规划下一次重试
  ///
  /// 返回等待延迟；null = 不重试（类别不可重试/次数耗尽/超预算）。
  /// 判定通过的调用方语义：等待 [返回值] 后以新令牌重发同一请求。
  Duration? planNextRetry({
    required String errorCategory,
    required RetryPolicy policy,
    Duration? retryAfter,
  }) {
    final semantic = semanticOf(errorCategory);
    if (semantic == null) return null;
    if (!policy.isRetryable(semantic)) return null;
    if (used >= policy.maxAttempts) return null;
    final delay = policy.delayFor(
      semantic: semantic,
      attempt: used + 1,
      retryAfter: retryAfter,
    );
    if (policy.exceedsBudget(cumulativeWait, delay)) return null;
    used++;
    cumulativeWait += delay;
    return delay;
  }

  void reset() {
    used = 0;
    cumulativeWait = Duration.zero;
  }

  /// 分类类别 → 共享语义码
  ///
  /// config（配置缺失/参数 4xx——重发必然再败）/ auth（鉴权）/ persist
  /// （本地持久化）/ unknown 不自动重试；网络五类（限流/服务端/超时/
  /// 连接/格式）映射共享码进判定表。
  static String? semanticOf(String errorCategory) => switch (errorCategory) {
        'rateLimit' => 'RATE_LIMIT',
        'server' => 'SERVER',
        'timeout' => 'timeout',
        'network' => 'STREAM_ERROR',
        'format' => 'FORMAT_ERROR',
        _ => null,
      };
}
