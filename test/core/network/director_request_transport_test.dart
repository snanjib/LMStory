import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lmstory/core/agent/agent_cancellation.dart';
import 'package:lmstory/core/agent/agent_llm_gateway.dart';
import 'package:lmstory/core/exceptions/app_exceptions.dart';
import 'package:lmstory/core/network/http_client.dart';
import 'package:lmstory/core/network/llm_adapters/llm_adapter_factory.dart';
import 'package:lmstory/core/network/stream_post_native.dart';
import 'package:lmstory/core/network/transport_client_native.dart';
import 'package:lmstory/features/chat/data/agent/llm_service_agent_gateway.dart';
import 'package:lmstory/features/chat/data/datasources/llm_remote_datasource.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';

const _json =
    '{"choices":[{"message":{"content":"ok","reasoning_content":"thought"},"finish_reason":"stop"}]}';

class _DeadlineClient extends HttpClient {
  @override
  Stream<String> streamPost(
    String url,
    Map<String, String> headers, {
    String? body,
    Encoding encoding = utf8,
    CancellationToken? cancelToken,
    Duration? connectTimeout,
    Duration? readTimeout,
    Duration? responseStartTimeout,
  }) =>
      Stream.error(
        const AppHttpException(
          'First response timed out',
          code: 'response_start_timeout',
        ),
      );
}

void main() {
  LlmRequest request({
    CancellationToken? token,
    Duration? first,
    Duration? total,
    Duration read = const Duration(milliseconds: 5),
  }) =>
      LlmRequest(
        baseUrl: 'https://relay.example/v1',
        modelId: 'test',
        messages: const [],
        cancelToken: token,
        connectTimeout: const Duration(milliseconds: 5),
        readTimeout: read,
        responseStartTimeout: first,
        nonStreamingTimeout: total,
      );
  LlmRemoteDataSource source(http.Client client) => LlmRemoteDataSource(
        httpClient: HttpClient(),
        adapterFactory: LlmAdapterFactory(),
        chatClient: client,
      );

  test('非流式长响应不受旧连接和读取短时限中断', () async {
    final client = MockClient.streaming((_, __) async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      Stream<List<int>> body() async* {
        for (final fragment in [_json.substring(0, 20), _json.substring(20)]) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          yield utf8.encode(fragment);
        }
      }

      return http.StreamedResponse(body(), 200);
    });
    final response = await source(client).chat(
      request(
        first: const Duration(seconds: 1),
        total: const Duration(seconds: 1),
      ),
    );
    expect(response.content, 'ok');
    expect(response.reasoningContent, 'thought');
  });

  test('非流式完成时限包含响应头等待且不因数据续期', () async {
    final never = StreamController<List<int>>();
    final client = MockClient.streaming((_, __) async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      never.add(utf8.encode('{'));
      return http.StreamedResponse(never.stream, 200);
    });
    await expectLater(
      source(client).chat(
        request(
          first: const Duration(seconds: 1),
          total: const Duration(milliseconds: 60),
        ),
      ),
      throwsA(
        isA<AppHttpException>()
            .having((e) => e.code, 'code', 'non_streaming_timeout'),
      ),
    );
    await never.close();
  });

  test('无首响应使用独立终态错误码', () async {
    final gate = Completer<http.Response>();
    await expectLater(
      source(MockClient((_) => gate.future)).chat(
        request(
          first: const Duration(milliseconds: 30),
          total: const Duration(seconds: 1),
        ),
      ),
      throwsA(
        isA<AppHttpException>()
            .having((e) => e.code, 'code', 'response_start_timeout'),
      ),
    );
  });

  test('读取响应体时取消不等待完整结果', () async {
    final started = Completer<void>();
    final body = StreamController<List<int>>();
    final token = CancellationToken();
    final client = MockClient.streaming((_, __) async {
      started.complete();
      return http.StreamedResponse(body.stream, 200);
    });
    final pending = source(client).chat(
      request(
        token: token,
        first: const Duration(seconds: 1),
        total: const Duration(seconds: 1),
      ),
    );
    final assertion = expectLater(pending, throwsA(isA<CancelledException>()));
    await started.future;
    token.cancel();
    await assertion;
    unawaited(body.close());
  });

  for (final protocol in ['openaiCompatible', 'anthropic', 'gemini']) {
    test('$protocol 首响应错误经过解析器和网关仍为不可重试', () async {
      final gateway = LlmServiceAgentGateway(
        llmService: LlmRemoteDataSource(
          httpClient: _DeadlineClient(),
          adapterFactory: LlmAdapterFactory(),
        ),
      );
      await expectLater(
        gateway.completeStep(
          endpoint: AgentModelEndpoint(
            baseUrl: 'https://example.com',
            modelId: 'test',
            protocol: protocol,
          ),
          request: const AgentStepRequest(
            messages: [],
            tools: [],
            config: AgentCallConfig(),
          ),
          cancellation: AgentCancellationToken(),
        ),
        throwsA(
          isA<AgentLlmException>()
              .having((e) => e.code, 'code', 'response_start_timeout')
              .having((e) => e.retryable, 'retryable', false),
        ),
      );
    });
  }

  test('原生连接配置按超时分池', () {
    final first = transportClient(const Duration(seconds: 5));
    expect(
      identical(first, transportClient(const Duration(seconds: 5))),
      isTrue,
    );
    expect(
      identical(first, transportClient(const Duration(seconds: 10))),
      isFalse,
    );
  });

  test('原生流式先等待首数据再启动空闲计时', () async {
    final server = await io.HttpServer.bind(io.InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      await request.drain<void>();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      request.response.headers.contentType = io.ContentType.text;
      request.response.write('first');
      await request.response.flush();
      await Future<void>.delayed(const Duration(milliseconds: 15));
      request.response.write('second');
      await request.response.close();
    });
    try {
      final chunks = await platformStreamPost(
        'http://127.0.0.1:${server.port}',
        {},
        responseStartTimeout: const Duration(seconds: 1),
        connectTimeout: const Duration(milliseconds: 5),
        readTimeout: const Duration(milliseconds: 30),
      ).toList();
      expect(chunks.join(), 'firstsecond');
    } finally {
      await server.close(force: true);
    }
  });
}
