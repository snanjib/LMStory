import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/exceptions/app_exceptions.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';
import 'package:lmstory/features/director_wizard/domain/services/world_prompt_generator.dart';
import 'package:lmstory/features/story_runtime/domain/entities/auxiliary_generation_failure.dart';
import 'package:lmstory/features/story_runtime/domain/services/session_title_generator.dart';
import 'package:lmstory/features/story_runtime/domain/services/suggest_reply_generator.dart';

void main() {
  for (final (error, kind, status) in [
    (
      TimeoutException('fixture timeout'),
      AuxiliaryGenerationFailureKind.timeout,
      null
    ),
    (
      const AppHttpException('fixture auth', statusCode: 401),
      AuxiliaryGenerationFailureKind.auth,
      401
    ),
    (
      const AppHttpException('fixture limit', statusCode: 429),
      AuxiliaryGenerationFailureKind.rateLimit,
      429
    ),
    (
      const AppHttpException(
        'fixture reject',
        statusCode: 400,
        responseBody: '{"message":"presence_penalty is not supported", '
            '"private":"synthetic payload"}',
      ),
      AuxiliaryGenerationFailureKind.requestRejected,
      400
    ),
  ]) {
    test('title failure keeps ${kind.name} and safe HTTP metadata', () async {
      final result = await SessionTitleGenerator(
        llmService: _RecordingLlmService('', failure: error),
      ).generateWithResult(
        userMessage: 'User fixture',
        assistantReply: 'Reply fixture',
        namingConfig: const NamingConfig(
          baseUrl: 'https://story.invalid',
          apiKey: 'synthetic-key',
          modelId: 'model',
        ),
      );
      expect(result.value, isNull);
      expect(result.failure?.kind, kind);
      expect(result.failure?.httpStatus, status);
      expect(
        result.failure?.parameter,
        status == 400 ? 'presence_penalty' : null,
      );
      expect(result.failure?.diagnostic, isNot(contains('synthetic payload')));
    });
  }

  test('invalid suggested replies keep model output out of logs', () async {
    final capture = _AuxiliaryLogCapture();
    Logger.addSink(capture);
    addTearDown(() => Logger.removeSink(capture));
    const privateText = 'private response echoed by the provider';
    final generator = SuggestReplyGenerator(
      llmService: _RecordingLlmService(privateText),
      logger: const Logger('test'),
    );
    expect(
      await generator.generate(
        namingConfig: const NamingConfig(
          baseUrl: 'https://story.invalid',
          apiKey: 'synthetic-key',
          modelId: 'model',
        ),
        systemPrompt: 'System fixture',
        lastUserMessage: 'User fixture',
        lastAssistantReply: 'Reply fixture',
        prevSummaries: const [],
      ),
      isEmpty,
    );
    expect(capture.records, isNotEmpty);
    expect(
      capture.records.map((record) => record.detail).join(),
      isNot(contains(privateText)),
    );
  });

  test('auxiliary failures log only safe request metadata', () async {
    const endpoint = 'https://writer:fake-auth@story.invalid/private';
    const naming = NamingConfig(
      baseUrl: endpoint,
      apiKey: 'test-secret',
      modelId: 'model-x',
    );
    const error = AppHttpException(
      'Provider rejected $endpoint',
      statusCode: 429,
      responseBody: '{"Authorization":"Bearer synthetic","private":"body"}',
    );
    final llm = _RecordingLlmService('', failure: error);
    final capture = _AuxiliaryLogCapture();
    Logger.addSink(capture);
    addTearDown(() => Logger.removeSink(capture));
    const logger = Logger('auxiliary fixture');
    expect(
      await SessionTitleGenerator(llmService: llm, logger: logger).generate(
        userMessage: 'User fixture',
        assistantReply: 'Reply fixture',
        namingConfig: naming,
      ),
      isNull,
    );
    expect(llm.lastRequest?.baseUrl, endpoint);
    expect(
      await WorldPromptGenerator(llmService: llm, logger: logger).generate(
        namingConfig: naming,
        systemPrompt: 'System fixture',
        userPrompt: 'Prompt fixture',
      ),
      isNull,
    );
    expect(llm.lastRequest?.apiKey, naming.apiKey);
    expect(capture.records.map((record) => record.message), [
      'Session title generation failed',
      'World prompt generation failed',
    ]);
    for (final record in capture.records) {
      expect(
        record.detail,
        matches(
          r'^protocol=openaiCompatible, elapsed=\d+ms, '
          r'errorType=AppHttpException, status=429$',
        ),
      );
      expect(record.error, isNull);
    }
  });

  group('SessionTitleGenerator.fallbackTitle', () {
    test('普通消息截取前 20 字符并清理换行', () {
      final title = SessionTitleGenerator.fallbackTitle(
        '第一行内容\n第二行内容超出二十个字符部分省略',
        defaultTitle: '新建会话',
      );
      expect(title, '第一行内容 第二行内容超出二十个字符部分');
      expect(title.length, 20);
    });

    test('空消息或纯空白回退到 defaultTitle', () {
      expect(
        SessionTitleGenerator.fallbackTitle(
          '',
          defaultTitle: '新建会话',
        ),
        '新建会话',
      );
      expect(
        SessionTitleGenerator.fallbackTitle(
          '   \n\t  ',
          defaultTitle: 'New Session',
        ),
        'New Session',
      );
    });
  });

  test('温度统一键：普通模型 0.3，禁发名单模型 null', () async {
    final llm = _RecordingLlmService('标题');
    final generator = SessionTitleGenerator(llmService: llm);

    await generator.generate(
      userMessage: '你好',
      assistantReply: '你好呀',
      namingConfig: const NamingConfig(
        baseUrl: 'https://a.com',
        apiKey: 'k',
        modelId: 'deepseek-chat',
      ),
    );
    expect(llm.lastRequest!.temperature, 0.3);

    await generator.generate(
      userMessage: '你好',
      assistantReply: '你好呀',
      namingConfig: const NamingConfig(
        baseUrl: 'https://a.com',
        apiKey: 'k',
        modelId: 'kimi-k2.6',
      ),
    );
    expect(llm.lastRequest!.temperature, isNull);
  });
}

class _RecordingLlmService implements LlmService {
  _RecordingLlmService(this.reply, {this.failure});

  final String reply;
  final Exception? failure;
  LlmRequest? lastRequest;

  @override
  Future<LlmResponse> chat(LlmRequest request) async {
    lastRequest = request;
    if (failure case final error?) throw error;
    return LlmResponse(content: reply);
  }

  @override
  Stream<LlmStreamEvent> streamChat(LlmRequest request) {
    throw UnimplementedError();
  }
}

class _AuxiliaryLogCapture extends LogSink {
  final records = <LogRecord>[];

  @override
  void write(LogRecord record) => records.add(record);

  @override
  Future<void> flush() async {}

  @override
  Future<void> dispose() async {}
}
