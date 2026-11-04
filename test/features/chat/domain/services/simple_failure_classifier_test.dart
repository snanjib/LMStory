import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/exceptions/app_exceptions.dart';
import 'package:lmstory/features/chat/domain/services/simple_failure_classifier.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// Simple 模式失败分类器单测（.5，DOC-09B §9 扩展）
///
/// 验证：
/// - classifyError：AppHttpException 各状态码/code 分流、TimeoutException、
///   StreamError 字符串特征、未知异常、rawError 截断
/// - errorCodeFromCategory：9 个分类 → S001-S009 映射 + 未知回退
/// - resolveMessage：9 个分类全覆盖
/// - formatDisplay：组合「友好提示（错误码）」格式
void main() {
  late SimpleFailureClassifier classifier;

  setUpAll(() {
    // slang 初始化为中文（保证 t.* 返回中文文案）
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  setUp(() {
    classifier = const SimpleFailureClassifier();
  });

  // ── classifyError：AppHttpException ─────────────────────────────────

  group('classifyError - AppHttpException', () {
    test('1. 401 → auth', () {
      const error = AppHttpException(
        'Unauthorized',
        statusCode: 401,
        code: 'bad_response',
      );
      final result = classifier.classifyError(error);

      expect(result.category, SimpleFailureClassifier.auth);
      expect(result.httpStatus, 401);
      expect(result.rawError, contains('Unauthorized'));
    });

    test('2. 403 → auth', () {
      const error = AppHttpException(
        'Forbidden',
        statusCode: 403,
        code: 'bad_response',
      );
      final result = classifier.classifyError(error);

      expect(result.category, SimpleFailureClassifier.auth);
      expect(result.httpStatus, 403);
    });

    test('3. 429 → rateLimit', () {
      const error = AppHttpException(
        'Too Many Requests',
        statusCode: 429,
        code: 'bad_response',
      );
      final result = classifier.classifyError(error);

      expect(result.category, SimpleFailureClassifier.rateLimit);
      expect(result.httpStatus, 429);
    });

    test('4. 500 → server', () {
      const error = AppHttpException(
        'Internal Server Error',
        statusCode: 500,
        code: 'bad_response',
      );
      final result = classifier.classifyError(error);

      expect(result.category, SimpleFailureClassifier.server);
      expect(result.httpStatus, 500);
    });

    test('5. 503 → server', () {
      const error = AppHttpException(
        'Service Unavailable',
        statusCode: 503,
        code: 'bad_response',
      );
      final result = classifier.classifyError(error);

      expect(result.category, SimpleFailureClassifier.server);
    });

    test('6. 其他 4xx（404）→ server', () {
      const error = AppHttpException(
        'Not Found',
        statusCode: 404,
        code: 'bad_response',
      );
      final result = classifier.classifyError(error);

      // 计划：其他 4xx → server
      expect(result.category, SimpleFailureClassifier.server);
      expect(result.httpStatus, 404);
    });

    test('模型不可用 400+文案 → server（非 unknown/S009）', () {
      // 网关在模型下线/无可用通道时返回 400+文案（实测 AG "Upstream
      // request failed: Model is unavailable"）——对齐故事侧
      //  口径，归 server 提示等待/换模型
      const error = AppHttpException(
        'Upstream request failed: Model is unavailable',
        statusCode: 400,
        code: 'server_error',
      );
      final result = classifier.classifyError(error);

      expect(result.category, SimpleFailureClassifier.server);
    });

    test('流错误串含模型不可用文案 → server', () {
      // chat 控制器把 LlmStreamError 包装为 Exception('server_error: ...')，
      // 无 status 码形态——流错误串分支同样检测
      final error = Exception(
        'STREAM_ERROR: Stream interrupted: no allowed providers for this model',
      );
      final result = classifier.classifyError(error);

      expect(result.category, SimpleFailureClassifier.server);
    });

    test('7. code connection_timeout → timeout', () {
      const error = AppHttpException(
        'Connection timeout',
        code: 'connection_timeout',
      );
      final result = classifier.classifyError(error);

      expect(result.category, SimpleFailureClassifier.timeout);
      expect(result.httpStatus, isNull);
    });

    test('8. code receive_timeout → timeout', () {
      const error = AppHttpException(
        'Receive timeout',
        code: 'receive_timeout',
      );
      final result = classifier.classifyError(error);

      expect(result.category, SimpleFailureClassifier.timeout);
    });

    test('9. code send_timeout → timeout', () {
      const error = AppHttpException(
        'Send timeout',
        code: 'send_timeout',
      );
      final result = classifier.classifyError(error);

      expect(result.category, SimpleFailureClassifier.timeout);
    });

    test('10. code connection_error → network', () {
      const error = AppHttpException(
        'Connection failed',
        code: 'connection_error',
      );
      final result = classifier.classifyError(error);

      expect(result.category, SimpleFailureClassifier.network);
      expect(result.httpStatus, isNull);
    });

    test('11. 未知 code + 无 statusCode → unknown', () {
      const error = AppHttpException('Something weird', code: 'unknown');
      final result = classifier.classifyError(error);

      expect(result.category, SimpleFailureClassifier.unknown);
      expect(result.httpStatus, isNull);
    });
  });

  // ── classifyError：其他异常类型 ─────────────────────────────────────

  group('classifyError - 其他异常类型', () {
    test('12. TimeoutException（dart:async）→ timeout', () {
      final error = TimeoutException('Request timed out');
      final result = classifier.classifyError(error);

      expect(result.category, SimpleFailureClassifier.timeout);
      expect(result.httpStatus, isNull);
      expect(result.rawError, isNotNull);
    });

    test('13. StreamErrorException（toString 含 "StreamError"）→ network', () {
      // 模拟 StreamErrorException 的 toString 特征（类型已提取为公开 StreamRunner 模块）
      const error = _FakeStreamErrorException('connection reset');
      final result = classifier.classifyError(error);

      expect(result.category, SimpleFailureClassifier.network);
      expect(result.httpStatus, isNull);
    });

    test('13a. STREAM_ERROR 格式（Simple 模式 ChatModeController 包装）→ 解析状态码', () {
      // 2026-07-30 回归测试：ChatModeController 将 LlmStreamError 包装为
      // Exception('STREAM_ERROR: ...')，toString() 小写后含 'stream_error'
      // （带下划线）。原代码 contains('streamerror') 无法匹配，导致所有
      // 流错误被误分类为 S009 unknown。修复后应正确匹配并解析状态码。
      final error = Exception(
        'STREAM_ERROR: Stream interrupted: AppHttpException: '
        'SSE request failed with status 400 | Response: bad request',
      );
      final result = classifier.classifyError(error);

      expect(result.category, SimpleFailureClassifier.config);
      expect(result.httpStatus, 400);
    });

    test('13b. STREAM_ERROR 格式（无状态码）→ network', () {
      // 流错误中无 HTTP 状态码时，应回退为 network（S002）
      final error = Exception(
        'STREAM_ERROR: Stream interrupted: connection reset by peer',
      );
      final result = classifier.classifyError(error);

      expect(result.category, SimpleFailureClassifier.network);
      expect(result.httpStatus, isNull);
    });

    test('13c. STREAM_ERROR 格式（429 限流）→ rateLimit', () {
      final error = Exception(
        'STREAM_ERROR: Stream interrupted: AppHttpException: '
        'SSE request failed with status 429 | Response: rate limited',
      );
      final result = classifier.classifyError(error);

      expect(result.category, SimpleFailureClassifier.rateLimit);
      expect(result.httpStatus, 429);
    });

    test('13d. STREAM_ERROR 格式（500 服务器错误）→ server', () {
      final error = Exception(
        'STREAM_ERROR: Stream interrupted: AppHttpException: '
        'SSE request failed with status 500 | Response: internal error',
      );
      final result = classifier.classifyError(error);

      expect(result.category, SimpleFailureClassifier.server);
      expect(result.httpStatus, 500);
    });

    test('14. 普通异常 → unknown', () {
      final error = Exception('something broke');
      final result = classifier.classifyError(error);

      expect(result.category, SimpleFailureClassifier.unknown);
      expect(result.httpStatus, isNull);
      expect(result.rawError, contains('something broke'));
    });

    test('15. rawError 截断到 2000 字符', () {
      // Exception.toString() = 'Exception: ' + message，总长 = 11 + 2100 = 2111
      final longMessage = 'A' * 2100;
      final error = Exception(longMessage);
      final result = classifier.classifyError(error);

      // 截断到 2000 字符（含 'Exception: ' 前缀）
      expect(result.rawError!.length, 2000);
      expect(result.rawError!.startsWith('Exception: '), isTrue);
    });

    test('16. rawError 短于 2000 字符时不截断', () {
      final error = Exception('short');
      final result = classifier.classifyError(error);

      expect(result.rawError, contains('short'));
      expect(result.rawError!.length, lessThan(2000));
    });
  });

  // ── errorCodeFromCategory ───────────────────────────────────────────

  group('errorCodeFromCategory', () {
    test('17. config → S001', () {
      expect(
        classifier.errorCodeFromCategory(SimpleFailureClassifier.config),
        'S001',
      );
    });

    test('18. network → S002', () {
      expect(
        classifier.errorCodeFromCategory(SimpleFailureClassifier.network),
        'S002',
      );
    });

    test('19. auth → S003', () {
      expect(
        classifier.errorCodeFromCategory(SimpleFailureClassifier.auth),
        'S003',
      );
    });

    test('20. rateLimit → S004', () {
      expect(
        classifier.errorCodeFromCategory(SimpleFailureClassifier.rateLimit),
        'S004',
      );
    });

    test('21. server → S005', () {
      expect(
        classifier.errorCodeFromCategory(SimpleFailureClassifier.server),
        'S005',
      );
    });

    test('22. timeout → S006', () {
      expect(
        classifier.errorCodeFromCategory(SimpleFailureClassifier.timeout),
        'S006',
      );
    });

    test('23. format → S007', () {
      expect(
        classifier.errorCodeFromCategory(SimpleFailureClassifier.format),
        'S007',
      );
    });

    test('24. persist → S008', () {
      expect(
        classifier.errorCodeFromCategory(SimpleFailureClassifier.persist),
        'S008',
      );
    });

    test('25. unknown → S009', () {
      expect(
        classifier.errorCodeFromCategory(SimpleFailureClassifier.unknown),
        'S009',
      );
    });

    test('26. 未知分类字符串 → S009（回退）', () {
      expect(classifier.errorCodeFromCategory('not-a-known-category'), 'S009');
    });
  });

  // ── resolveMessage ──────────────────────────────────────────────────

  group('resolveMessage', () {
    test('27. config → 配置不完整', () {
      expect(
        classifier.resolveMessage(SimpleFailureClassifier.config),
        '配置不完整，请前往设置检查 API 供应商和模型',
      );
    });

    test('28. network → 网络连接失败', () {
      expect(
        classifier.resolveMessage(SimpleFailureClassifier.network),
        '网络连接失败，请检查网络后重试',
      );
    });

    test('29. auth → API Key 无效', () {
      expect(
        classifier.resolveMessage(SimpleFailureClassifier.auth),
        'API Key 无效或无权限',
      );
    });

    test('30. rateLimit → 请求过于频繁', () {
      expect(
        classifier.resolveMessage(SimpleFailureClassifier.rateLimit),
        '请求过于频繁，请稍后重试',
      );
    });

    test('31. server → 服务器异常', () {
      expect(
        classifier.resolveMessage(SimpleFailureClassifier.server),
        '服务器异常，请稍后重试',
      );
    });

    test('32. timeout → 请求超时', () {
      expect(
        classifier.resolveMessage(SimpleFailureClassifier.timeout),
        '请求超时，请检查网络后重试',
      );
    });

    test('33. format → 模型响应格式异常', () {
      expect(
        classifier.resolveMessage(SimpleFailureClassifier.format),
        '模型响应格式异常',
      );
    });

    test('34. persist → 本地存储失败', () {
      expect(
        classifier.resolveMessage(SimpleFailureClassifier.persist),
        '本地存储失败',
      );
    });

    test('35. unknown → 发生错误', () {
      expect(
        classifier.resolveMessage(SimpleFailureClassifier.unknown),
        '发生错误，请重试',
      );
    });

    test('36. 未知分类字符串 → 发生错误（回退）', () {
      expect(
        classifier.resolveMessage('not-a-known-category'),
        '发生错误，请重试',
      );
    });
  });

  // ── formatDisplay ───────────────────────────────────────────────────

  group('formatDisplay', () {
    test('37. network + S002 → "网络连接失败，请检查网络后重试（S002）"', () {
      final display = classifier.formatDisplay(
        SimpleFailureClassifier.network,
        'S002',
      );
      expect(display, '网络连接失败，请检查网络后重试（S002）');
    });

    test('38. config + S001 → "配置不完整...（S001）"', () {
      final display = classifier.formatDisplay(
        SimpleFailureClassifier.config,
        'S001',
      );
      expect(display, '配置不完整，请前往设置检查 API 供应商和模型（S001）');
    });

    test('39. unknown + S009 → "发生错误，请重试（S009）"', () {
      final display = classifier.formatDisplay(
        SimpleFailureClassifier.unknown,
        'S009',
      );
      expect(display, '发生错误，请重试（S009）');
    });

    test('40. 错误码与分类独立传递（不强制一致性）', () {
      // formatDisplay 不校验 category 与 code 的对应关系，调用方负责匹配
      final display = classifier.formatDisplay(
        SimpleFailureClassifier.timeout,
        'S999',
      );
      expect(display, '请求超时，请检查网络后重试（S999）');
    });
  });

  // ── 端到端：classifyError → errorCodeFromCategory → formatDisplay ──

  group('端到端流程', () {
    test('41. 401 异常 → auth/S003/友好提示', () {
      const error = AppHttpException(
        'Unauthorized',
        statusCode: 401,
        code: 'bad_response',
      );
      final result = classifier.classifyError(error);
      final code = classifier.errorCodeFromCategory(result.category);
      final display = classifier.formatDisplay(result.category, code);

      expect(result.category, SimpleFailureClassifier.auth);
      expect(code, 'S003');
      expect(display, 'API Key 无效或无权限（S003）');
    });

    test('42. TimeoutException → timeout/S006/友好提示', () {
      final error = TimeoutException('Request timed out');
      final result = classifier.classifyError(error);
      final code = classifier.errorCodeFromCategory(result.category);
      final display = classifier.formatDisplay(result.category, code);

      expect(result.category, SimpleFailureClassifier.timeout);
      expect(code, 'S006');
      expect(display, '请求超时，请检查网络后重试（S006）');
    });

    test('43. 普通异常 → unknown/S009/友好提示', () {
      final error = Exception('something broke');
      final result = classifier.classifyError(error);
      final code = classifier.errorCodeFromCategory(result.category);
      final display = classifier.formatDisplay(result.category, code);

      expect(result.category, SimpleFailureClassifier.unknown);
      expect(code, 'S009');
      expect(display, '发生错误，请重试（S009）');
    });
  });
}

/// 模拟 StreamErrorException 的行为（类型已提取为公开 StreamRunner 模块）。
///
/// 真实类型 toString() 返回 'StreamError: $message'，
/// 分类器按 "StreamError" 字符串特征识别为 network。
class _FakeStreamErrorException implements Exception {
  const _FakeStreamErrorException(this.message);
  final String message;

  @override
  String toString() => 'StreamError: $message';
}
