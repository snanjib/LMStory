import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/network/http_client.dart' show CancellationToken;
import 'package:lmstory/features/chat/domain/services/llm_service.dart';

/// LlmService Domain 接口单元测试（Stage 1）
///
/// 验证值对象的行为契约：
/// - [LlmRequest.copyWith] 仅覆盖 cancelToken，其余字段原样保留
/// - [LlmResponseFormat] 枚举仅含 jsonObject（jsonSchema 推迟到 v0.3）
/// - [LlmStreamEvent] sealed class 各子类的字段携带
/// - [LlmResponse] / [LlmUsage] 的构造与默认值
///
/// LlmRemoteDataSource 的集成测试由 intermediate_chat_controller_integration_test.dart
/// 间接覆盖（通过 LlmRemoteDataSource 包装 _SseHttpClient 跑完整状态机链路）。
void main() {
  group('LlmRequest', () {
    test('copyWith 不传 cancelToken 时保持原 cancelToken', () {
      final token = CancellationToken();
      final request = LlmRequest(
        baseUrl: 'https://api.test.com',
        apiKey: 'key',
        modelId: 'gpt-4',
        messages: const [
          {'role': 'user', 'content': 'hello'},
        ],
        temperature: 0.8,
        topP: 0.9,
        maxTokens: 4096,
        cancelToken: token,
      );
      final copied = request.copyWith();
      expect(copied.cancelToken, same(token));
      expect(copied.baseUrl, 'https://api.test.com');
      expect(copied.modelId, 'gpt-4');
      expect(copied.temperature, 0.8);
    });

    test('copyWith 传入新 cancelToken 时覆盖原值', () {
      final token1 = CancellationToken();
      final token2 = CancellationToken();
      final request = LlmRequest(
        baseUrl: 'https://api.test.com',
        modelId: 'gpt-4',
        messages: const [],
        cancelToken: token1,
      );
      final copied = request.copyWith(cancelToken: token2);
      expect(copied.cancelToken, same(token2));
      expect(copied.cancelToken, isNot(same(token1)));
    });

    test('copyWith 保留其他所有字段不变', () {
      const request = LlmRequest(
        baseUrl: 'https://api.test.com',
        apiKey: 'key',
        modelId: 'gpt-4',
        messages: [
          {'role': 'system', 'content': 'sys'},
          {'role': 'user', 'content': 'hi'},
        ],
        temperature: 0.7,
        topP: 0.8,
        maxTokens: 2048,
        includeUsage: true,
        responseFormat: LlmResponseFormatJsonObject(),
      );
      final token = CancellationToken();
      final copied = request.copyWith(cancelToken: token);

      // 所有原字段应原样保留
      expect(copied.baseUrl, request.baseUrl);
      expect(copied.apiKey, request.apiKey);
      expect(copied.modelId, request.modelId);
      expect(copied.messages, request.messages);
      expect(copied.temperature, request.temperature);
      expect(copied.topP, request.topP);
      expect(copied.maxTokens, request.maxTokens);
      expect(copied.stream, request.stream);
      expect(copied.includeUsage, request.includeUsage);
      expect(copied.responseFormat, request.responseFormat);
      // 仅 cancelToken 被新值覆盖
      expect(copied.cancelToken, same(token));
    });

    test('默认值：stream=true, includeUsage=false, 其余可空字段为 null', () {
      const request = LlmRequest(
        baseUrl: 'https://api.test.com',
        modelId: 'gpt-4',
        messages: [],
      );
      expect(request.stream, isTrue);
      expect(request.includeUsage, isFalse);
      expect(request.responseFormat, isNull);
      expect(request.apiKey, isNull);
      expect(request.temperature, isNull);
      expect(request.topP, isNull);
      expect(request.maxTokens, isNull);
      expect(request.cancelToken, isNull);
      expect(request.connectTimeout, isNull);
      expect(request.readTimeout, isNull);
    });
  });

  group('LlmResponseFormat', () {
    test('B4-1：sealed class 含两个子类 JsonObject 和 JsonSchema', () {
      //  改造：从 enum 改为 sealed class，支持 json_schema strict 模式
      const jsonObject = LlmResponseFormatJsonObject();
      const jsonSchema = LlmResponseFormatJsonSchema(
        name: 'test',
        schema: {'type': 'object'},
      );
      expect(jsonObject, isA<LlmResponseFormat>());
      expect(jsonSchema, isA<LlmResponseFormat>());
      expect(jsonSchema.name, 'test');
      expect(jsonSchema.schema, {'type': 'object'});
      expect(jsonSchema.strict, isTrue); // 默认严格模式
    });
  });

  group('LlmStreamEvent', () {
    test('LlmTextDelta 携带 content 且为 LlmStreamEvent 子类', () {
      const event = LlmTextDelta('hello');
      expect(event.content, 'hello');
      expect(event, isA<LlmStreamEvent>());
    });

    test('LlmThinkingDelta 携带 content', () {
      const event = LlmThinkingDelta('thinking...');
      expect(event.content, 'thinking...');
      expect(event, isA<LlmStreamEvent>());
    });

    test('LlmStreamDone 可携带 usage', () {
      const usage = LlmUsage(
        promptTokens: 10,
        completionTokens: 20,
        totalTokens: 30,
      );
      const event = LlmStreamDone(usage: usage);
      expect(event.usage, isNotNull);
      expect(event.usage!.promptTokens, 10);
      expect(event.usage!.completionTokens, 20);
      expect(event.usage!.totalTokens, 30);
    });

    test('LlmStreamDone usage 可为 null', () {
      const event = LlmStreamDone();
      expect(event.usage, isNull);
    });

    test('LlmStreamError 携带 message 和可选 code', () {
      const event1 = LlmStreamError('network error');
      expect(event1.message, 'network error');
      expect(event1.code, isNull);

      const event2 = LlmStreamError('timeout', code: 'TIMEOUT');
      expect(event2.message, 'timeout');
      expect(event2.code, 'TIMEOUT');
    });
  });

  group('LlmResponse', () {
    test('构造含 content 和 usage', () {
      const usage = LlmUsage(totalTokens: 100);
      const response = LlmResponse(content: 'hello', usage: usage);
      expect(response.content, 'hello');
      expect(response.usage, isNotNull);
      expect(response.usage!.totalTokens, 100);
    });

    test('usage 默认为 null', () {
      const response = LlmResponse(content: 'hi');
      expect(response.usage, isNull);
    });
  });
}
