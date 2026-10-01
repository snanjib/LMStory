import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/exceptions/app_exceptions.dart';
import 'package:lmstory/features/intermediate/domain/entities/intermediate_chat_state.dart';
import 'package:lmstory/features/story_runtime/domain/entities/stream_failure.dart';
import 'package:lmstory/features/story_runtime/domain/services/failure_classifier.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 失败分类器单测
///
/// 验证：
/// - classifyError：AppHttpException 各状态码/code 分流、TimeoutException、
///   StreamError 字符串特征、未知异常、rawError 截断
/// - resolveFailureMessage：各 errorCode + 未知 errorCode 回退
/// - resolveSuggestion：9 个 category 全覆盖
void main() {
  late StoryFailureClassifier classifier;

  setUpAll(() {
    // slang 初始化为中文（保证 t.* 返回中文文案）
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  setUp(() {
    classifier = const StoryFailureClassifier();
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

      expect(result.category, ErrorCategory.auth);
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

      expect(result.category, ErrorCategory.auth);
      expect(result.httpStatus, 403);
    });

    test('3. 429 → rateLimit', () {
      const error = AppHttpException(
        'Too Many Requests',
        statusCode: 429,
        code: 'bad_response',
      );
      final result = classifier.classifyError(error);

      expect(result.category, ErrorCategory.rateLimit);
      expect(result.httpStatus, 429);
    });

    test('4. 500 → server', () {
      const error = AppHttpException(
        'Internal Server Error',
        statusCode: 500,
        code: 'bad_response',
      );
      final result = classifier.classifyError(error);

      expect(result.category, ErrorCategory.server);
      expect(result.httpStatus, 500);
    });

    test('5. 503 → server', () {
      const error = AppHttpException(
        'Service Unavailable',
        statusCode: 503,
        code: 'bad_response',
      );
      final result = classifier.classifyError(error);

      expect(result.category, ErrorCategory.server);
    });

    test('6. 其他 4xx（404）→ server', () {
      const error = AppHttpException(
        'Not Found',
        statusCode: 404,
        code: 'bad_response',
      );
      final result = classifier.classifyError(error);

      // 计划：其他 4xx → server
      expect(result.category, ErrorCategory.server);
      expect(result.httpStatus, 404);
    });

    test('7. code connection_timeout → timeout', () {
      const error = AppHttpException(
        'Connection timeout',
        code: 'connection_timeout',
      );
      final result = classifier.classifyError(error);

      expect(result.category, ErrorCategory.timeout);
      expect(result.httpStatus, isNull);
    });

    test('8. code receive_timeout → timeout', () {
      const error = AppHttpException(
        'Receive timeout',
        code: 'receive_timeout',
      );
      final result = classifier.classifyError(error);

      expect(result.category, ErrorCategory.timeout);
    });

    test('9. code send_timeout → timeout', () {
      const error = AppHttpException(
        'Send timeout',
        code: 'send_timeout',
      );
      final result = classifier.classifyError(error);

      expect(result.category, ErrorCategory.timeout);
    });

    test('10. code connection_error → network', () {
      const error = AppHttpException(
        'Connection failed',
        code: 'connection_error',
      );
      final result = classifier.classifyError(error);

      expect(result.category, ErrorCategory.network);
      expect(result.httpStatus, isNull);
    });

    test('11. 未知 code + 无 statusCode → unknown', () {
      const error = AppHttpException('Something weird', code: 'unknown');
      final result = classifier.classifyError(error);

      expect(result.category, ErrorCategory.unknown);
      expect(result.httpStatus, isNull);
    });
  });

  // ── classifyError：其他异常类型 ─────────────────────────────────────

  // ── classifyError： 上游「模型不可用」（400+文案）──

  group('classifyError - 模型不可用特征', () {
    test('StreamErrorException + AG 实测文案 → server（不再误归 network）', () {
      const error = StreamErrorException(
        'Stream interrupted: AppHttpException: SSE request failed with '
        'status 400 | Response: {"error":{"type":"server_error","message":"Error from provider (Console): Upstream request '
        'failed: Model is unavailable."}}',
        code: 'BAD_REQUEST',
      );
      final result = classifier.classifyError(error);
      expect(result.category, ErrorCategory.server);
    });

    test('toString 含 StreamError 的兜底形态 + 模型不可用文案 → server', () {
      const error = _FakeStreamErrorException(
        'SSE request failed with status 400 | Model is unavailable',
      );
      expect(
        classifier.classifyError(error).category,
        ErrorCategory.server,
      );
    });

    test('E016 + server 分类 → resolveFailureMessage 返回 e016Server 专属文案', () {
      expect(
        classifier.resolveFailureMessage('E016', ErrorCategory.server),
        '模型服务暂时不可用',
      );
      // 真·网络中断（network 分类）仍显示「网络中断」
      expect(
        classifier.resolveFailureMessage('E016', ErrorCategory.network),
        '网络中断',
      );
    });
  });

  group('classifyError - B11 上下文超限（body 模式匹配口径）', () {
    test('400 + OpenAI 文案（responseBody）→ contextOverflow', () {
      const error = AppHttpException(
        'HTTP 400',
        statusCode: 400,
        code: '400',
        responseBody: "This model's maximum context length is 128000 tokens. "
            'However, you requested 200000 tokens',
      );
      final result = classifier.classifyError(error);
      expect(result.category, ErrorCategory.contextOverflow);
      expect(result.httpStatus, 400);
    });

    test('400 + Anthropic prompt is too long（message 本体）→ contextOverflow', () {
      const error = AppHttpException(
        'prompt is too long: 205845 tokens > 200000 maximum',
        statusCode: 400,
        code: '400',
      );
      expect(
        classifier.classifyError(error).category,
        ErrorCategory.contextOverflow,
      );
    });

    test('400 + 中转站中文变体（超过上下文）→ contextOverflow', () {
      const error = AppHttpException(
        '请求失败',
        statusCode: 400,
        code: '400',
        responseBody: '输入超过上下文上限，请缩短后重试',
      );
      expect(
        classifier.classifyError(error).category,
        ErrorCategory.contextOverflow,
      );
    });

    test('普通 400（无超限文案）→ 仍归 server（不误伤）', () {
      const error = AppHttpException(
        'invalid schema',
        statusCode: 400,
        code: '400',
      );
      expect(
        classifier.classifyError(error).category,
        ErrorCategory.server,
      );
    });

    test('StreamErrorException + 超限文案（任意 code）→ contextOverflow', () {
      const error = StreamErrorException(
        "This model's maximum context length is 128000 tokens",
        code: 'BAD_REQUEST',
      );
      expect(
        classifier.classifyError(error).category,
        ErrorCategory.contextOverflow,
      );
    });

    test('审查收官 R3-P2-8：数字语义码（429/401/503）不再落 network', () {
      expect(
        classifier
            .classifyError(
              const StreamErrorException('rate limited', code: '429'),
            )
            .category,
        ErrorCategory.rateLimit,
      );
      expect(
        classifier
            .classifyError(
              const StreamErrorException('unauthorized', code: '401'),
            )
            .category,
        ErrorCategory.auth,
      );
      expect(
        classifier
            .classifyError(
              const StreamErrorException('server error', code: '503'),
            )
            .category,
        ErrorCategory.server,
      );
    });

    test('resolveFailureMessage：contextOverflow → 专属横幅文案', () {
      final message = classifier.resolveFailureMessage(
        'E016',
        ErrorCategory.contextOverflow,
      );
      expect(message, contains('已自动压缩重试仍超限'));
      expect(message, contains('手动压缩或精简输入'));
    });

    test('resolveSuggestion：contextOverflow → 圆环压缩指引', () {
      final suggestion = classifier.resolveSuggestion(
        ErrorCategory.contextOverflow,
      );
      expect(suggestion, contains('立即压缩'));
    });
  });

  group('classifyError - 其他异常类型', () {
    test('12. TimeoutException（dart:async）→ timeout', () {
      final error = TimeoutException('Request timed out');
      final result = classifier.classifyError(error);

      expect(result.category, ErrorCategory.timeout);
      expect(result.httpStatus, isNull);
      expect(result.rawError, isNotNull);
    });

    test('13. StreamErrorException（toString 含 "StreamError"）→ network', () {
      // 模拟 StreamErrorException 的 toString 特征（类型已提取为公开 StreamRunner 模块）
      const error = _FakeStreamErrorException('connection reset');
      final result = classifier.classifyError(error);

      expect(result.category, ErrorCategory.network);
      expect(result.httpStatus, isNull);
    });

    test('13b. B3 真实 StreamErrorException：RATE_LIMIT 语义码 → rateLimit（含冷却）', () {
      const error = StreamErrorException(
        'rate limited',
        code: 'RATE_LIMIT',
        retryAfter: Duration(seconds: 9),
      );
      final result = classifier.classifyError(error);

      expect(result.category, ErrorCategory.rateLimit);
      expect(result.httpStatus, isNull);
    });

    test('13c. B3 真实 StreamErrorException：AUTH 语义码 → auth、SERVER → server', () {
      expect(
        classifier
            .classifyError(
              const StreamErrorException('bad key', code: 'AUTH'),
            )
            .category,
        ErrorCategory.auth,
      );
      expect(
        classifier
            .classifyError(
              const StreamErrorException('upstream', code: 'SERVER'),
            )
            .category,
        ErrorCategory.server,
      );
    });

    test('13d. B3 真实 StreamErrorException：未识别语义码 → network 兜底', () {
      const error = StreamErrorException('connection reset');
      final result = classifier.classifyError(error);

      expect(result.category, ErrorCategory.network);
      expect(result.httpStatus, isNull);
    });

    test('14. 普通异常 → unknown', () {
      final error = Exception('something broke');
      final result = classifier.classifyError(error);

      expect(result.category, ErrorCategory.unknown);
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

  // ── resolveFailureMessage ───────────────────────────────────────────

  group('resolveFailureMessage', () {
    test('17. E010 → 生成失败', () {
      final msg = classifier.resolveFailureMessage(
        'E010',
        ErrorCategory.config,
      );
      expect(msg, '生成失败');
    });

    // E011/E015 为幽灵码（V2 四步重构后
    // 不再产生），文案与分类器映射已删除——幽灵码须回退通用文案，
    // 不得再挂专属文案（防止码被悄悄复活）。
    test('18. 幽灵码 E011 → 回退通用文案（无专属映射）', () {
      final msg = classifier.resolveFailureMessage(
        'E011',
        ErrorCategory.format,
      );
      expect(msg, '发生错误');
    });

    test('19. E012 -> 记忆检索失败', () {
      final msg = classifier.resolveFailureMessage(
        'E012',
        ErrorCategory.unknown,
      );
      expect(msg, '记忆检索失败');
    });

    test('19b. E013 -> 关键词提取失败', () {
      final msg = classifier.resolveFailureMessage(
        'E013',
        ErrorCategory.unknown,
      );
      expect(msg, '关键词提取失败');
    });

    test('20. E014 -> 审查失败', () {
      final msg = classifier.resolveFailureMessage(
        'E014',
        ErrorCategory.unknown,
      );
      expect(msg, '审查失败');
    });

    test('21. 幽灵码 E015 → 回退通用文案（无专属映射）', () {
      final msg = classifier.resolveFailureMessage(
        'E015',
        ErrorCategory.format,
      );
      expect(msg, '发生错误');
    });

    test('22. E016 -> 网络中断', () {
      final msg = classifier.resolveFailureMessage(
        'E016',
        ErrorCategory.network,
      );
      expect(msg, '网络中断');
    });

    test('22b. E017 -> 摘要生成失败', () {
      final msg = classifier.resolveFailureMessage(
        'E017',
        ErrorCategory.unknown,
      );
      expect(msg, '摘要生成失败');
    });

    test('23. E018 -> 保存失败', () {
      final msg = classifier.resolveFailureMessage(
        'E018',
        ErrorCategory.persist,
      );
      expect(msg, '保存失败');
    });

    test('24. 未知 errorCode → 发生错误', () {
      final msg = classifier.resolveFailureMessage(
        'E999',
        ErrorCategory.unknown,
      );
      expect(msg, '发生错误');
    });
  });

  // ── resolveSuggestion ──────────────────────────────────────────────

  group('resolveSuggestion', () {
    test('25. config → 请前往设置配置', () {
      final s = classifier.resolveSuggestion(ErrorCategory.config);
      expect(s, '请前往设置配置 API 供应商和模型');
    });

    test('26. network → 检查网络连接', () {
      final s = classifier.resolveSuggestion(ErrorCategory.network);
      expect(s, '检查网络连接后重试');
    });

    test('27. auth → API Key 无效', () {
      final s = classifier.resolveSuggestion(ErrorCategory.auth);
      expect(s, 'API Key 无效或无权限，请检查供应商配置');
    });

    test('28. rateLimit → 请求过于频繁', () {
      final s = classifier.resolveSuggestion(ErrorCategory.rateLimit);
      expect(s, '请求过于频繁，请稍后重试');
    });

    test('29. server → 服务器异常', () {
      final s = classifier.resolveSuggestion(ErrorCategory.server);
      expect(s, '服务器异常，请稍后重试');
    });

    test('30. timeout → 请求超时', () {
      final s = classifier.resolveSuggestion(ErrorCategory.timeout);
      expect(s, '请求超时，请检查网络后重试');
    });

    test('31. format → 模型输出格式不符', () {
      final s = classifier.resolveSuggestion(ErrorCategory.format);
      expect(s, '模型输出格式不符，可重试或切换模型');
    });

    test('32. persist → 数据库写入失败', () {
      final s = classifier.resolveSuggestion(ErrorCategory.persist);
      expect(s, '数据库写入失败，请重试');
    });

    test('33. unknown → 请重试', () {
      final s = classifier.resolveSuggestion(ErrorCategory.unknown);
      expect(s, '请重试，如持续失败请反馈');
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
