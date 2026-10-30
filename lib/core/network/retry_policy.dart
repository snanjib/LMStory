import 'dart:math';

import 'package:lmstory/core/agent/agent_llm_gateway.dart'
    show AgentLlmErrorSemantic;
import 'package:lmstory/core/network/retry_after.dart';

export 'package:lmstory/core/network/retry_after.dart'
    show jitteredDelay, maxRetryAfterDelay, parseRetryAfter;

/// 共享重试策略契约层（2026-10-15 批 D；落地：
/// 「超时/错误映射/重试规则抽共享契约层」）
///
/// 三模式（导演 step 层 / 故事阶段层 / simple 薄壳）消费**同一份**判定表
/// 与退避算法——判定表 = 单一真源，模式侧只保留次数覆盖项，不旁路抄表。
///
/// 依据：P5（默认 5 次，进度透明后高默认=知情自决）、P6（累计纯等待
/// 预算闸默认 90s，防 5 连长冷却纯等约 5 分钟；0=不限）。
class RetryPolicy {
  const RetryPolicy({
    this.maxAttempts = 5,
    this.totalWaitBudget = const Duration(seconds: 90),
  });

  /// 自动重试次数上限（不含首次尝试；P5 默认 5，设置范围 0–5）
  final int maxAttempts;

  /// 累计纯等待预算（P6；null = 不限——愿意盯进度条长等的用户可放开）。
  /// 只计退避/冷却等待，不计请求执行耗时——预算闸防的是「白等冷却」。
  final Duration? totalWaitBudget;

  /// 可重试判定表（单源；免费站扩展 2026-10-15）
  ///
  /// | 语义 | 可重试 | 说明 |
  /// |---|---|---|
  /// | RATE_LIMIT / 429 | ✅ | Retry-After 优先 |
  /// | SERVER / 5xx | ✅ | |
  /// | timeout | ✅ | 连接/空闲读 |
  /// | STREAM_ERROR | ✅ | 流中断，免费站高频 |
  /// | EMPTY_RESPONSE（新增归一） | ✅ | 200 空内容 |
  /// | FORMAT_ERROR（新增归一） | ✅ | JSON 解析失败/HTML 挑战页伪装 200 |
  /// | AUTH / 401 / 403 | ❌ | 重试无意义 |
  /// | BAD_REQUEST / 其余 4xx | ❌ | |
  /// | contextOverflow | ❌ | 走溢出自愈独立通道（硬口径，两侧既有） |
  bool isRetryable(Object? codeOrSemantic) {
    // 归一语义枚举：溢出不进自动重试（独立自愈通道）
    if (codeOrSemantic == AgentLlmErrorSemantic.contextOverflow) return false;
    if (codeOrSemantic is! String) return true; // null/未知 → 保守可重试
    switch (codeOrSemantic) {
      case 'STREAM_ERROR':
      case 'timeout':
      case 'RATE_LIMIT':
      case 'SERVER':
      case 'EMPTY_RESPONSE':
      case 'FORMAT_ERROR':
      case 'PARSE_ERROR': // gemini/anthropic 旧码（已统一 FORMAT_ERROR，防漏网）
      case '429':
      case '500':
      case '502':
      case '503':
      case '504':
        return true;
      case 'AUTH':
      case 'BAD_REQUEST':
      case '401':
      case '403':
        return false;
      default:
        // 其余数字码：4xx 不重试、5xx 可重试；非数字未知码保守可重试
        final asInt = int.tryParse(codeOrSemantic);
        return asInt == null || asInt >= 500;
    }
  }

  /// 本次失败的等待延迟
  ///
  /// - EMPTY_RESPONSE / FORMAT_ERROR → **立即**（零退避——响应已完整到达
  ///   只是内容坏，下一发大概率恢复；退避反而拖长恢复）
  /// - Retry-After 优先（服务端限流冷却指示，封顶 [maxRetryAfterDelay]
  ///   60s，精确遵守不加 jitter——重发不早于指示值）
  /// - 无指示 → 指数退避 500ms 起翻倍，封顶 **15s**（2026-10-15 从导演侧
  ///   旧值 4s 上调：5 连场景 500/1000/2000/4000/4000 总等待仅 7.5s 对
  ///   间歇性故障偏密，提封顶后总等待 ~23s）+ ±25% jitter
  ///
  /// [attempt] 为即将进行的第几次重试（1 起）。[roll] ∈ [0,1) 注入 jitter
  ///（测试确定性），缺省随机。
  Duration delayFor({
    required Object? semantic,
    required int attempt,
    Duration? retryAfter,
    double? roll,
  }) {
    if (semantic == 'EMPTY_RESPONSE' || semantic == 'FORMAT_ERROR') {
      return Duration.zero;
    }
    if (retryAfter != null) {
      return retryAfter > maxRetryAfterDelay ? maxRetryAfterDelay : retryAfter;
    }
    return jitteredDelay(
      Duration(milliseconds: backoffMs(attempt)),
      roll ?? _jitterRandom.nextDouble(),
    );
  }

  /// 指数退避毫秒（500ms 起翻倍封顶 15s）：
  /// attempt=1→500，2→1000，3→2000，4→4000，5→8000，≥6→15000
  static int backoffMs(int attempt) {
    var ms = 500;
    for (var i = 1; i < attempt && ms < kMaxBackoffMs; i++) {
      ms *= 2;
    }
    return ms > kMaxBackoffMs ? kMaxBackoffMs : ms;
  }

  /// 退避封顶（批 D 从 4s 提至 15s）
  static const int kMaxBackoffMs = 15000;

  /// 预算闸（P6）：再等 [nextDelay] 是否会超出累计等待预算
  ///
  /// [cumulativeWait] 为此前已累计的纯等待。超限后调用方应放弃并给出
  /// 「冷却超预算」原因文案。null 预算恒 false（不限）。
  bool exceedsBudget(Duration cumulativeWait, Duration nextDelay) {
    final budget = totalWaitBudget;
    if (budget == null) return false;
    return cumulativeWait + nextDelay > budget;
  }

  /// 预算超限的放弃原因（供失败信封/日志统一口径）
  static const String budgetExceededReason = '冷却超预算，提前放弃重试';

  static final Random _jitterRandom = Random();
}

/// 语义码 → 人话原因（重试等待行/失败信封共用；i18n 在 UI 层按此映射）
enum RetryWaitReason {
  rateLimited,
  serverError,
  timeout,
  streamInterrupted,
  badResponse,
  unknown;

  /// 语义码映射（EMPTY_RESPONSE/FORMAT_ERROR 同归 badResponse「响应异常」）
  static RetryWaitReason of(Object? semantic) {
    if (semantic is! String) return RetryWaitReason.unknown;
    switch (semantic) {
      case 'RATE_LIMIT':
      case '429':
        return RetryWaitReason.rateLimited;
      case 'SERVER':
      case '500':
      case '502':
      case '503':
      case '504':
        return RetryWaitReason.serverError;
      case 'timeout':
        return RetryWaitReason.timeout;
      case 'STREAM_ERROR':
        return RetryWaitReason.streamInterrupted;
      case 'EMPTY_RESPONSE':
      case 'FORMAT_ERROR':
      case 'PARSE_ERROR':
        return RetryWaitReason.badResponse;
      default:
        final asInt = int.tryParse(semantic);
        if (asInt != null && asInt >= 500) return RetryWaitReason.serverError;
        if (asInt == 429) return RetryWaitReason.rateLimited;
        return RetryWaitReason.unknown;
    }
  }
}
