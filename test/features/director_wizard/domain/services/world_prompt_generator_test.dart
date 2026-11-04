import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/chat/domain/entities/reasoning_effort.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';
import 'package:lmstory/features/director_wizard/domain/services/world_prompt_generator.dart';

/// 世界观生成器（一次性调用，仿标题生成先例）：
/// 成功/空内容/异常/超时四态 + 请求参数与超时地板断言。
void main() {
  const naming = NamingConfig(
    baseUrl: 'https://example.com',
    apiKey: 'sk-test',
    modelId: 'model-x',
  );

  _FakeLlmService fake(Future<LlmResponse> Function(LlmRequest) responder) =>
      _FakeLlmService(responder);

  test('成功：返回 trim 后的正文，请求参数符合一次性调用先例', () async {
    final service = fake(
      (r) async => const LlmResponse(content: '  这是一个世界。\n'),
    );
    final generator = WorldPromptGenerator(llmService: service);

    final result = await generator.generate(
      namingConfig: naming,
      systemPrompt: 'SYS',
      userPrompt: 'USER',
    );

    expect(result, '这是一个世界。');
    final request = service.lastRequest!;
    expect(request.stream, isFalse, reason: '非流式');
    expect(
      request.reasoningEffort,
      ReasoningEffort.disabled,
      reason: '生成禁思考，对齐标题先例',
    );
    expect(request.messages, [
      {'role': 'system', 'content': 'SYS'},
      {'role': 'user', 'content': 'USER'},
    ]);
    expect(request.modelId, 'model-x');
  });

  test('空内容：返回 null（调用方走拼装兜底）', () async {
    final generator = WorldPromptGenerator(
      llmService: fake((r) async => const LlmResponse(content: '   ')),
    );
    final result = await generator.generate(
      namingConfig: naming,
      systemPrompt: 'S',
      userPrompt: 'U',
    );
    expect(result, isNull);
  });

  test('异常：吞掉并返回 null', () async {
    final generator = WorldPromptGenerator(
      llmService: fake((r) async => throw Exception('boom')),
    );
    final result = await generator.generate(
      namingConfig: naming,
      systemPrompt: 'S',
      userPrompt: 'U',
    );
    expect(result, isNull);
  });

  test('外层超时：返回 null（默认 90s 帽）', () async {
    final generator = WorldPromptGenerator(
      llmService: fake(
        (r) => Completer<LlmResponse>().future,
      ),
    );
    final result = await generator.generate(
      namingConfig: naming,
      systemPrompt: 'S',
      userPrompt: 'U',
      outerTimeout: const Duration(milliseconds: 50),
    );
    expect(result, isNull);
  });

  test('readTimeout 地板 60s：短于 60s 的解析值被抬高', () async {
    final service = fake((r) async => const LlmResponse(content: 'x'));
    final generator = WorldPromptGenerator(llmService: service);
    await generator.generate(
      namingConfig: naming,
      systemPrompt: 'S',
      userPrompt: 'U',
      connectTimeout: const Duration(seconds: 15),
      readTimeout: const Duration(seconds: 30),
    );
    expect(
      service.lastRequest!.readTimeout,
      const Duration(seconds: 60),
      reason: '生成几百字需要更长读超时（启动决策轮口径）',
    );
    expect(service.lastRequest!.connectTimeout, const Duration(seconds: 15));
  });
  test('温度统一键：普通模型 0.3，禁发名单模型 null', () async {
    final normal =
        _FakeLlmService((r) async => const LlmResponse(content: '正文'));
    await WorldPromptGenerator(llmService: normal).generate(
      namingConfig: naming,
      systemPrompt: 'S',
      userPrompt: 'U',
    );
    expect(normal.lastRequest!.temperature, 0.3);

    final kimi = _FakeLlmService((r) async => const LlmResponse(content: '正文'));
    await WorldPromptGenerator(llmService: kimi).generate(
      namingConfig: const NamingConfig(
        baseUrl: 'https://example.com',
        apiKey: 'sk-test',
        modelId: 'kimi-k3.1-pro',
      ),
      systemPrompt: 'S',
      userPrompt: 'U',
    );
    expect(kimi.lastRequest!.temperature, isNull);
  });
}

class _FakeLlmService implements LlmService {
  _FakeLlmService(this.responder);

  final Future<LlmResponse> Function(LlmRequest request) responder;
  LlmRequest? lastRequest;

  @override
  Future<LlmResponse> chat(LlmRequest request) {
    lastRequest = request;
    return responder(request);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
