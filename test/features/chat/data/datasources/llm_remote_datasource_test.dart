import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lmstory/core/exceptions/app_exceptions.dart';
import 'package:lmstory/core/network/http_client.dart';
import 'package:lmstory/core/network/llm_adapters/llm_adapter_factory.dart';
import 'package:lmstory/features/chat/data/datasources/llm_remote_datasource.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';

/// XC-5：非流式 chat() 的取消令牌与 connect/read 双段超时回归。
///
/// 流式路径（streamChat → HttpClient.streamPost）两者齐备；chat() 此前用
/// 裸 http.post + 单一 readTimeout，既不检查取消令牌也无独立连接超时。
/// 连接超时用例的墙钟上限：旧实现（无连接超时）会拖到 readTimeout，
/// 用短上限让回归失败快速暴露。
const _testWallClockLimit = Timeout(Duration(seconds: 15));

void main() {
  LlmRequest buildRequest({
    CancellationToken? cancelToken,
    Duration? connectTimeout,
    Duration? readTimeout,
  }) =>
      LlmRequest(
        baseUrl: 'https://api.openai.com/v1',
        apiKey: 'k',
        modelId: 'gpt-test',
        messages: [
          {'role': 'user', 'content': 'hi'},
        ],
        cancelToken: cancelToken,
        connectTimeout: connectTimeout,
        readTimeout: readTimeout,
      );

  LlmRemoteDataSource buildDataSource(http.Client chatClient) =>
      LlmRemoteDataSource(
        httpClient: HttpClient(),
        adapterFactory: LlmAdapterFactory(),
        chatClient: chatClient,
      );

  test('请求前取消令牌已取消：直接抛 CancelledException，不出网', () async {
    var requestCount = 0;
    final client = MockClient((request) async {
      requestCount++;
      return http.Response('{}', 200);
    });
    final dataSource = buildDataSource(client);

    final token = CancellationToken()..cancel();

    await expectLater(
      dataSource.chat(buildRequest(cancelToken: token)),
      throwsA(isA<CancelledException>()),
    );
    expect(requestCount, 0, reason: '已取消的请求不应发出网络调用');
  });

  test(
    '连接阶段超时走 connectTimeout（不受长 readTimeout 拖累）',
    () async {
      final never = Completer<http.Response>();
      final client = MockClient((request) => never.future);
      final dataSource = buildDataSource(client);

      final stopwatch = Stopwatch()..start();
      await expectLater(
        dataSource.chat(
          buildRequest(
            connectTimeout: const Duration(milliseconds: 100),
            readTimeout: const Duration(seconds: 30),
          ),
        ),
        throwsA(
          isA<AppHttpException>().having(
            (e) => e.code,
            'code',
            'connection_timeout',
          ),
        ),
      );
      stopwatch.stop();
      expect(
        stopwatch.elapsed,
        lessThan(const Duration(seconds: 10)),
        reason: '连接超时应由 connectTimeout（100ms）触发，而非等到 readTimeout',
      );
    },
    timeout: _testWallClockLimit,
  );

  test('正常 200 响应仍经适配器解析（行为不回退）', () async {
    http.Request? captured;
    final client = MockClient((request) async {
      captured = request;
      return http.Response(
        '{"choices":[{"message":{"role":"assistant","content":"ok"},'
        '"finish_reason":"stop"}]}',
        200,
      );
    });
    final dataSource = buildDataSource(client);

    final response = await dataSource.chat(buildRequest());

    expect(response.content, 'ok');
    expect(response.finishReason, 'stop');
    expect(
      captured!.url.toString(),
      'https://api.openai.com/v1/chat/completions',
    );
    expect(captured!.headers['authorization'], 'Bearer k');
  });
}
