import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/exceptions/app_exceptions.dart';
import 'package:lmstory/core/network/retry_after.dart';

///  网络错误语义与重试工程：Retry-After 解析 / 语义码映射 / jitter 测试
void main() {
  group('parseRetryAfter 三态', () {
    test('retry-after-ms（毫秒）优先', () {
      final d = parseRetryAfter(
        headers: const HttpErrorHeaders(retryAfter: '2', retryAfterMs: '1500'),
      );
      expect(d, const Duration(milliseconds: 1500));
    });

    test('retry-after 纯整数按秒解析', () {
      final d = parseRetryAfter(
        headers: const HttpErrorHeaders(retryAfter: '30'),
      );
      expect(d, const Duration(seconds: 30));
    });

    test('retry-after HTTP-date（RFC 1123）按与 now 的差值解析', () {
      final now = DateTime.utc(2026, 9, 3, 12);
      final d = parseRetryAfter(
        headers:
            const HttpErrorHeaders(retryAfter: 'Thu, 03 Sep 2026 12:01:00 GMT'),
        now: now,
      );
      expect(d, const Duration(minutes: 1));
    });

    test('HTTP-date 已过期返回 null（不再冷却）', () {
      final now = DateTime.utc(2026, 9, 3, 12);
      final d = parseRetryAfter(
        headers:
            const HttpErrorHeaders(retryAfter: 'Thu, 03 Sep 2026 11:59:00 GMT'),
        now: now,
      );
      expect(d, isNull);
    });

    test('缺失/空/零值/畸形返回 null（调用方落回本地退避）', () {
      expect(parseRetryAfter(), isNull);
      expect(parseRetryAfter(headers: const HttpErrorHeaders()), isNull);
      expect(
        parseRetryAfter(headers: const HttpErrorHeaders(retryAfter: '0')),
        isNull,
      );
      expect(
        parseRetryAfter(headers: const HttpErrorHeaders(retryAfter: 'soon')),
        isNull,
      );
      expect(
        parseRetryAfter(headers: const HttpErrorHeaders(retryAfterMs: '-5')),
        isNull,
      );
    });

    test('fromMap 头名大小写不敏感、空值整组返回 null', () {
      final h = HttpErrorHeaders.fromMap({
        'Retry-After': '5',
        'X-Request-Id': 'req-1',
      });
      expect(h?.retryAfter, '5');
      expect(h?.requestId, 'req-1');
      expect(HttpErrorHeaders.fromMap({'Content-Type': 'text/html'}), isNull);
      expect(HttpErrorHeaders.fromMap(null), isNull);
    });
  });

  group('semanticCodeForStatus 状态码映射', () {
    test('429→RATE_LIMIT、401/403→AUTH、5xx→SERVER、其余 4xx→BAD_REQUEST', () {
      expect(semanticCodeForStatus(429), 'RATE_LIMIT');
      expect(semanticCodeForStatus(401), 'AUTH');
      expect(semanticCodeForStatus(403), 'AUTH');
      expect(semanticCodeForStatus(500), 'SERVER');
      expect(semanticCodeForStatus(503), 'SERVER');
      expect(semanticCodeForStatus(400), 'BAD_REQUEST');
      expect(semanticCodeForStatus(404), 'BAD_REQUEST');
    });

    test('null/0（网络层失败）返回 null（调用方保持 STREAM_ERROR）', () {
      expect(semanticCodeForStatus(null), isNull);
      expect(semanticCodeForStatus(0), isNull);
    });
  });

  group('streamErrorCodeOf / streamErrorRetryAfterOf', () {
    test('AppHttpException(429, Retry-After: 7) → RATE_LIMIT + 7s', () {
      const e = AppHttpException(
        'rate limited',
        statusCode: 429,
        headers: HttpErrorHeaders(retryAfter: '7'),
      );
      expect(streamErrorCodeOf(e), 'RATE_LIMIT');
      expect(streamErrorRetryAfterOf(e), const Duration(seconds: 7));
    });

    test('AppHttpException(401) → AUTH、无冷却', () {
      const e = AppHttpException('bad key', statusCode: 401);
      expect(streamErrorCodeOf(e), 'AUTH');
      expect(streamErrorRetryAfterOf(e), isNull);
    });

    test('非 HTTP 异常（解析错误等）保持 STREAM_ERROR', () {
      expect(
        streamErrorCodeOf(const FormatException('bad json')),
        'STREAM_ERROR',
      );
      expect(streamErrorRetryAfterOf(StateError('x')), isNull);
    });
  });

  group('jitteredDelay', () {
    test('roll=0.5 恰为基准值；边界收束到 ±25%', () {
      const base = Duration(seconds: 4);
      expect(jitteredDelay(base, 0.5), base);
      expect(jitteredDelay(base, 0).inMilliseconds, 3000);
      expect(jitteredDelay(base, 0.999).inMilliseconds, closeTo(4999, 1));
    });
  });
}
