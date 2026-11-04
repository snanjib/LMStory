import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/agent/agent_llm_gateway.dart';
import 'package:lmstory/core/network/retry_policy.dart';

/// 共享重试策略单测（2026-10-15 批 D， 契约层落地）
///
/// 覆盖：判定表全行（含新增 EMPTY_RESPONSE/FORMAT_ERROR 归一）、
/// 退避序列 500/1000/2000/4000/8000/15000 封顶、Retry-After 优先封顶、
/// 立即重试零退避、±25% jitter 区间性质、预算闸边界。
void main() {
  group('RetryPolicy.isRetryable 判定表全行', () {
    const policy = RetryPolicy();

    test('可重试：RATE_LIMIT/SERVER/timeout/STREAM_ERROR/EMPTY/FORMAT/5xx', () {
      const retryable = [
        'RATE_LIMIT',
        'SERVER',
        'timeout',
        'STREAM_ERROR',
        'EMPTY_RESPONSE',
        'FORMAT_ERROR',
        'PARSE_ERROR', // gemini/anthropic 旧码兼容
        '429',
        '500',
        '502',
        '503',
        '504',
      ];
      for (final code in retryable) {
        expect(policy.isRetryable(code), isTrue, reason: code);
      }
    });

    test('不可重试：AUTH/BAD_REQUEST/其余 4xx/contextOverflow', () {
      const nonRetryable = ['AUTH', 'BAD_REQUEST', '401', '403', '400', '404'];
      for (final code in nonRetryable) {
        expect(policy.isRetryable(code), isFalse, reason: code);
      }
      // 溢出走自愈独立通道，不进自动重试（硬口径）
      expect(
        policy.isRetryable(AgentLlmErrorSemantic.contextOverflow),
        isFalse,
      );
    });

    test('null/未知非数字码保守可重试', () {
      expect(policy.isRetryable(null), isTrue);
      expect(policy.isRetryable('WEIRD_CODE'), isTrue);
    });
  });

  group('RetryPolicy.delayFor 退避序列', () {
    const policy = RetryPolicy();

    test('指数退避 500ms 起翻倍封顶 15s（roll=0.5 = 无 jitter 中心值）', () {
      // roll=0.5 → scaled = base * (0.75 + 0.5*0.5) = base * 1.0
      expect(
        policy.delayFor(semantic: 'SERVER', attempt: 1, roll: 0.5),
        const Duration(milliseconds: 500),
      );
      expect(
        policy.delayFor(semantic: 'SERVER', attempt: 2, roll: 0.5),
        const Duration(milliseconds: 1000),
      );
      expect(
        policy.delayFor(semantic: 'SERVER', attempt: 3, roll: 0.5),
        const Duration(milliseconds: 2000),
      );
      expect(
        policy.delayFor(semantic: 'SERVER', attempt: 4, roll: 0.5),
        const Duration(milliseconds: 4000),
      );
      expect(
        policy.delayFor(semantic: 'SERVER', attempt: 5, roll: 0.5),
        const Duration(milliseconds: 8000),
      );
      expect(
        policy.delayFor(semantic: 'SERVER', attempt: 6, roll: 0.5),
        const Duration(milliseconds: 15000),
      );
      expect(
        policy.delayFor(semantic: 'SERVER', attempt: 99, roll: 0.5),
        const Duration(milliseconds: 15000),
      );
    });

    test('EMPTY_RESPONSE / FORMAT_ERROR 立即重试（零退避）', () {
      expect(
        policy.delayFor(semantic: 'EMPTY_RESPONSE', attempt: 1),
        Duration.zero,
      );
      expect(
        policy.delayFor(semantic: 'FORMAT_ERROR', attempt: 3),
        Duration.zero,
      );
    });

    test('Retry-After 优先且封顶 60s（不加 jitter，精确遵守）', () {
      expect(
        policy.delayFor(
          semantic: 'RATE_LIMIT',
          attempt: 1,
          retryAfter: const Duration(seconds: 12),
        ),
        const Duration(seconds: 12),
      );
      expect(
        policy.delayFor(
          semantic: 'RATE_LIMIT',
          attempt: 1,
          retryAfter: const Duration(seconds: 300),
        ),
        const Duration(seconds: 60),
      );
    });

    test('±25% jitter 区间性质（roll∈[0,1) → delay∈[0.75x, 1.25x)）', () {
      // attempt=4 → base 4000ms；roll=0 → 3000；roll→1 → 5000
      expect(
        policy.delayFor(semantic: 'SERVER', attempt: 4, roll: 0),
        const Duration(milliseconds: 3000),
      );
      final nearMax =
          policy.delayFor(semantic: 'SERVER', attempt: 4, roll: 0.999);
      expect(nearMax.inMilliseconds, lessThan(5000));
      expect(nearMax.inMilliseconds, greaterThanOrEqualTo(4990));
    });
  });

  group('RetryPolicy 预算闸（P6）', () {
    test('默认 90s：累计+下次超预算才拦，恰好等于不拦', () {
      const policy = RetryPolicy(); // budget 90s
      expect(
        policy.exceedsBudget(
          const Duration(seconds: 80),
          const Duration(seconds: 9),
        ),
        isFalse,
      );
      expect(
        policy.exceedsBudget(
          const Duration(seconds: 80),
          const Duration(seconds: 11),
        ),
        isTrue,
      );
      expect(
        policy.exceedsBudget(const Duration(seconds: 90), Duration.zero),
        isFalse,
      );
    });

    test('totalWaitBudget=null 不限（0=不限语义由配置层转换）', () {
      const policy = RetryPolicy(totalWaitBudget: null);
      expect(
        policy.exceedsBudget(
          const Duration(hours: 5),
          const Duration(hours: 1),
        ),
        isFalse,
      );
    });

    test('maxAttempts 默认 5', () {
      expect(const RetryPolicy().maxAttempts, 5);
      expect(const RetryPolicy(maxAttempts: 0).maxAttempts, 0);
    });
  });

  group('RetryWaitReason 人话映射', () {
    test('语义码 → 原因归类', () {
      expect(RetryWaitReason.of('RATE_LIMIT'), RetryWaitReason.rateLimited);
      expect(RetryWaitReason.of('429'), RetryWaitReason.rateLimited);
      expect(RetryWaitReason.of('SERVER'), RetryWaitReason.serverError);
      expect(RetryWaitReason.of('503'), RetryWaitReason.serverError);
      expect(RetryWaitReason.of('timeout'), RetryWaitReason.timeout);
      expect(
        RetryWaitReason.of('STREAM_ERROR'),
        RetryWaitReason.streamInterrupted,
      );
      expect(
        RetryWaitReason.of('EMPTY_RESPONSE'),
        RetryWaitReason.badResponse,
      );
      expect(RetryWaitReason.of('FORMAT_ERROR'), RetryWaitReason.badResponse);
      expect(RetryWaitReason.of(null), RetryWaitReason.unknown);
    });
  });
}
