import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/output_token_policy.dart';
import 'package:lmstory/core/network/llm_adapters/anthropic_adapter.dart';
import 'package:lmstory/core/network/llm_adapters/gemini_adapter.dart';
import 'package:lmstory/core/network/llm_adapters/openai_adapter.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';

LlmRequest _request({
  String modelId = 'test-model',
  int? maxTokens,
  int? modelMaxOutputTokens,
}) {
  return LlmRequest(
    baseUrl: 'https://example.com/v1',
    modelId: modelId,
    messages: const [
      {'role': 'user', 'content': 'hello'},
    ],
    maxTokens: maxTokens,
    modelMaxOutputTokens: modelMaxOutputTokens,
  );
}

void main() {
  group('OutputTokenPolicy', () {
    test('positive limits are clamped to model metadata', () {
      expect(OutputTokenPolicy.clampToModel(16384, 8192), 8192);
      expect(OutputTokenPolicy.clampToModel(4096, 8192), 4096);
      expect(OutputTokenPolicy.clampToModel(16384, null), 16384);
    });

    test('zero keeps API unlimited but reserves context space', () {
      expect(OutputTokenPolicy.clampToModel(0, 32768), 0);
      expect(
        OutputTokenPolicy.contextReserve(
          configured: 0,
          modelMaxOutput: 32768,
        ),
        OutputTokenPolicy.unlimitedContextReserve,
      );
      expect(
        OutputTokenPolicy.contextReserve(
          configured: 0,
          modelMaxOutput: 4096,
        ),
        4096,
      );
    });
  });

  group('OpenAI output-token request mapping', () {
    final adapter = OpenAiAdapter();

    test('zero omits the output-token field', () {
      final body = adapter.buildRequestBody(
        _request(maxTokens: 0, modelMaxOutputTokens: 32768),
        stream: true,
      );

      expect(body, isNot(contains('max_tokens')));
      expect(body, isNot(contains('max_completion_tokens')));
    });

    test('positive limit is clamped to model max output', () {
      final body = adapter.buildRequestBody(
        _request(maxTokens: 16384, modelMaxOutputTokens: 8192),
        stream: true,
      );

      expect(body['max_tokens'], 8192);
    });

    test('o-series uses max_completion_tokens', () {
      final body = adapter.buildRequestBody(
        _request(modelId: 'o3', maxTokens: 8192),
        stream: true,
      );

      expect(body['max_completion_tokens'], 8192);
      expect(body, isNot(contains('max_tokens')));
    });
  });

  group('Gemini output-token request mapping', () {
    final adapter = GeminiAdapter();

    test('zero omits maxOutputTokens', () {
      final body = adapter.buildRequestBody(
        _request(maxTokens: 0, modelMaxOutputTokens: 32768),
        stream: true,
      );
      final generationConfig = body['generationConfig'];

      expect(
        generationConfig is Map<String, dynamic>
            ? generationConfig
            : const <String, dynamic>{},
        isNot(contains('maxOutputTokens')),
      );
    });

    test('positive limit is clamped to model max output', () {
      final body = adapter.buildRequestBody(
        _request(maxTokens: 16384, modelMaxOutputTokens: 8192),
        stream: true,
      );
      final generationConfig = body['generationConfig'] as Map<String, dynamic>;

      expect(generationConfig['maxOutputTokens'], 8192);
    });
  });

  group('Anthropic output-token request mapping', () {
    final adapter = AnthropicAdapter();

    test('zero uses model max output because max_tokens is required', () {
      final body = adapter.buildRequestBody(
        _request(maxTokens: 0, modelMaxOutputTokens: 32768),
        stream: true,
      );

      expect(body['max_tokens'], 32768);
    });

    test('zero without model metadata fails explicitly', () {
      expect(
        () => adapter.buildRequestBody(_request(maxTokens: 0), stream: true),
        throwsArgumentError,
      );
    });

    test('positive limit is clamped to model max output', () {
      final body = adapter.buildRequestBody(
        _request(maxTokens: 16384, modelMaxOutputTokens: 8192),
        stream: true,
      );

      expect(body['max_tokens'], 8192);
    });
  });
}
