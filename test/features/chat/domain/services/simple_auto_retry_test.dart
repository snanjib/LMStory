import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/network/retry_policy.dart';
import 'package:lmstory/features/chat/domain/services/simple_auto_retry.dart';

/// Simple 自动重试薄壳单测（2026-10-15 批 E，P5/P8）
void main() {
  group('semanticOf 分类映射', () {
    test('网络五类映射共享语义码；config/auth/persist/unknown 不重试', () {
      expect(SimpleAutoRetry.semanticOf('rateLimit'), 'RATE_LIMIT');
      expect(SimpleAutoRetry.semanticOf('server'), 'SERVER');
      expect(SimpleAutoRetry.semanticOf('timeout'), 'timeout');
      expect(SimpleAutoRetry.semanticOf('network'), 'STREAM_ERROR');
      expect(SimpleAutoRetry.semanticOf('format'), 'FORMAT_ERROR');
      expect(SimpleAutoRetry.semanticOf('config'), isNull);
      expect(SimpleAutoRetry.semanticOf('auth'), isNull);
      expect(SimpleAutoRetry.semanticOf('persist'), isNull);
      expect(SimpleAutoRetry.semanticOf('unknown'), isNull);
    });
  });

  group('planNextRetry 判定链', () {
    test('默认 5 次（P5）：第 1-5 次给延迟，第 6 次 null', () {
      final retry = SimpleAutoRetry();
      const policy = RetryPolicy();
      for (var i = 1; i <= 5; i++) {
        final delay = retry.planNextRetry(
          errorCategory: 'server',
          policy: policy,
        );
        expect(delay, isNotNull, reason: '第 $i 次应可重试');
      }
      expect(
        retry.planNextRetry(errorCategory: 'server', policy: policy),
        isNull,
        reason: '次数耗尽',
      );
    });

    test('maxAttempts=0 完全关闭（可调 0-5 的 0 档）', () {
      final retry = SimpleAutoRetry();
      expect(
        retry.planNextRetry(
          errorCategory: 'server',
          policy: const RetryPolicy(maxAttempts: 0),
        ),
        isNull,
      );
    });

    test('不可重试类别恒 null；Retry-After 精确遵守', () {
      final retry = SimpleAutoRetry();
      const policy = RetryPolicy();
      expect(
        retry.planNextRetry(errorCategory: 'auth', policy: policy),
        isNull,
      );
      final delay = retry.planNextRetry(
        errorCategory: 'rateLimit',
        policy: policy,
        retryAfter: const Duration(seconds: 42),
      );
      expect(delay, const Duration(seconds: 42));
    });

    test('格式类立即重试零退避；服务类指数退避', () {
      final retry = SimpleAutoRetry();
      const policy = RetryPolicy();
      expect(
        retry.planNextRetry(errorCategory: 'format', policy: policy),
        Duration.zero,
      );
      // server 是本实例第 2 次规划（format 已用 1 次）→ attempt=2 退避 1000ms
      final serverDelay = retry.planNextRetry(
        errorCategory: 'server',
        policy: policy,
      );
      expect(serverDelay!.inMilliseconds, inInclusiveRange(750, 1250));
    });

    test('预算闸：累计等待超 90s 提前放弃（P6）', () {
      final retry = SimpleAutoRetry();
      const policy = RetryPolicy();
      // 直接累计接近预算（服务端长冷却）
      retry.cumulativeWait = const Duration(seconds: 85);
      expect(
        retry.planNextRetry(
          errorCategory: 'rateLimit',
          policy: policy,
          retryAfter: const Duration(seconds: 60),
        ),
        isNull,
        reason: '85s + 60s 冷却超 90s 预算',
      );
    });

    test('reset 清零（新发送重置计数）', () {
      final retry = SimpleAutoRetry();
      const policy = RetryPolicy();
      retry
        ..planNextRetry(errorCategory: 'server', policy: policy)
        ..reset();
      expect(retry.used, 0);
      expect(retry.cumulativeWait, Duration.zero);
    });
  });
}
