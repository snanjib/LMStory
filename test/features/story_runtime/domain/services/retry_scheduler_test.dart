import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/story_runtime/domain/services/retry_scheduler.dart';

/// 重试延迟调度——格式错误立即重试；限流尊重 Retry-After；
/// 非零延迟 ±25% jitter（roll 注入确定性）
void main() {
  const scheduler = RetryScheduler();

  // E011/E015 为幽灵码（V2 后不再产生），
  // 从格式错误立即重试名单与重试配额中移除——只保留真实存活的 E013/E017。
  test('格式错误（E013/E017）立即重试，不受 retryAfter 影响', () {
    for (final code in const ['E013', 'E017']) {
      expect(
        scheduler.retryDelay(code, retryAfter: const Duration(seconds: 30)),
        Duration.zero,
        reason: code,
      );
    }
  });

  test('幽灵码 E011/E015 无重试配额（走 default 0 次）', () {
    expect(scheduler.getMaxRetries('E011', null), 0);
    expect(scheduler.getMaxRetries('E015', null), 0);
  });

  test('退避改读共享策略：E016 attempt 首发即 500ms；Retry-After 精确遵守', () {
    // 2026-10-15 批 E：故事退避改读共享 RetryPolicy（E016→STREAM_ERROR
    // 指数退避，固定 1s 旧口径退役；roll=0.5 = 无 jitter 中心值）
    expect(
      scheduler.retryDelay('E016', roll: () => 0.5),
      const Duration(milliseconds: 500),
    );
    expect(
      scheduler.retryDelay(
        'E016',
        retryAfter: const Duration(seconds: 42),
        roll: () => 0.5,
      ),
      const Duration(seconds: 42),
    );
  });

  test('jitter：roll=0/1 收束到 ±25% 边界（E010 首发退避 500ms）', () {
    final low = scheduler.retryDelay('E010', roll: () => 0);
    final high = scheduler.retryDelay('E010', roll: () => 0.999999);
    expect(low.inMilliseconds, closeTo(375, 1));
    expect(high.inMilliseconds, closeTo(625, 1));
  });

  group('Retry-After 指示精确遵守（不早于指示值重发）', () {
    test('指示 5s → 延迟恰 5s，任何 roll 都不提前', () {
      for (final roll in const [0.0, 0.25, 0.5, 0.9, 0.999999]) {
        expect(
          scheduler.retryDelay(
            'E010',
            retryAfter: const Duration(seconds: 5),
            roll: () => roll,
          ),
          const Duration(seconds: 5),
          reason: 'roll=$roll：指示值不加 jitter，重发不早于指示',
        );
      }
    });

    test('超长指示封顶 60s（尊重长冷却但不无限等待，对齐导演侧）', () {
      expect(
        scheduler.retryDelay(
          'E016',
          retryAfter: const Duration(seconds: 90),
          roll: () => 0.5,
        ),
        const Duration(seconds: 60),
      );
    });

    test('亚秒指示同样精确遵守', () {
      expect(
        scheduler.retryDelay(
          'E012',
          retryAfter: const Duration(milliseconds: 500),
          roll: () => 0,
        ),
        const Duration(milliseconds: 500),
      );
    });
  });
}
