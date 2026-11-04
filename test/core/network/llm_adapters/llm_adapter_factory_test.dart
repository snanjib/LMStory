import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/network/llm_adapters/anthropic_adapter.dart';
import 'package:lmstory/core/network/llm_adapters/deepseek_adapter.dart';
import 'package:lmstory/core/network/llm_adapters/gemini_adapter.dart';
import 'package:lmstory/core/network/llm_adapters/llm_adapter_factory.dart';
import 'package:lmstory/core/network/llm_adapters/openai_adapter.dart';
import 'package:lmstory/core/network/llm_adapters/responses_adapter.dart';
import 'package:lmstory/features/settings/domain/entities/llm_protocol.dart';

void main() {
  group('LlmAdapterFactory', () {
    late LlmAdapterFactory factory;

    setUp(() {
      factory = LlmAdapterFactory();
    });

    group('基础协议分发', () {
      test('openaiCompatible 协议 + 非 DeepSeek 端点 → 返回 OpenAiAdapter', () {
        final adapter = factory.getAdapter(
          protocol: LlmProtocol.openaiCompatible,
          baseUrl: 'https://api.openai.com',
          modelId: 'gpt-5',
        );
        expect(adapter, isA<OpenAiAdapter>());
        expect(adapter, isNot(isA<DeepSeekAdapter>()));
      });

      test('anthropic 协议 → 返回 AnthropicAdapter', () {
        final adapter = factory.getAdapter(
          protocol: LlmProtocol.anthropic,
          baseUrl: 'https://api.anthropic.com',
          modelId: 'claude-sonnet-4-6',
        );
        expect(adapter, isA<AnthropicAdapter>());
      });

      test('geminiNative 协议 → 返回 GeminiAdapter', () {
        final adapter = factory.getAdapter(
          protocol: LlmProtocol.geminiNative,
          baseUrl: 'https://generativelanguage.googleapis.com',
          modelId: 'gemini-2.5-pro',
        );
        expect(adapter, isA<GeminiAdapter>());
      });

      test('openaiResponses 协议 → 返回 ResponsesAdapter', () {
        final adapter = factory.getAdapter(
          protocol: LlmProtocol.openaiResponses,
          baseUrl: 'https://api.openai.com',
          modelId: 'gpt-6-astra',
        );
        expect(adapter, isA<ResponsesAdapter>());
      });
    });

    group('DeepSeek 端点路由（2026-07-28 新增）', () {
      test('openaiCompatible + DeepSeek 官方端点 → 返回 DeepSeekAdapter', () {
        final adapter = factory.getAdapter(
          protocol: LlmProtocol.openaiCompatible,
          baseUrl: 'https://api.deepseek.com',
          modelId: 'deepseek-v4-pro',
        );
        expect(adapter, isA<DeepSeekAdapter>());
      });

      test('openaiCompatible + DeepSeek beta 端点 → 返回 DeepSeekAdapter', () {
        final adapter = factory.getAdapter(
          protocol: LlmProtocol.openaiCompatible,
          baseUrl: 'https://api.deepseek.com/beta',
          modelId: 'deepseek-chat',
        );
        expect(adapter, isA<DeepSeekAdapter>());
      });

      test(
          'openaiCompatible + 第三方中转 + deepseek- 前缀 modelId → 返回 DeepSeekAdapter',
          () {
        // 用户可能在第三方中转站配置 deepseek-xxx 模型，仍按 DeepSeek 处理
        final adapter = factory.getAdapter(
          protocol: LlmProtocol.openaiCompatible,
          baseUrl: 'https://some-relay.example.com',
          modelId: 'deepseek-v4-pro',
        );
        expect(adapter, isA<DeepSeekAdapter>());
      });

      test('openaiCompatible + OpenRouter 路由的 deepseek/xxx → 返回 OpenAiAdapter',
          () {
        // OpenRouter 作为中间层会自行处理兼容性，不路由到 DeepSeekAdapter
        final adapter = factory.getAdapter(
          protocol: LlmProtocol.openaiCompatible,
          baseUrl: 'https://openrouter.ai/api/v1',
          modelId: 'deepseek/deepseek-v4-pro',
        );
        expect(adapter, isA<OpenAiAdapter>());
        expect(adapter, isNot(isA<DeepSeekAdapter>()));
      });

      test('大小写不敏感：API.DEEPSEEK.COM + DeepSeek-V4-Pro → 返回 DeepSeekAdapter',
          () {
        final adapter = factory.getAdapter(
          protocol: LlmProtocol.openaiCompatible,
          baseUrl: 'https://API.DEEPSEEK.COM',
          modelId: 'DeepSeek-V4-Pro',
        );
        expect(adapter, isA<DeepSeekAdapter>());
      });
    });

    group('单例语义', () {
      test('同协议同端点多次获取返回同一实例', () {
        final a1 = factory.getAdapter(
          protocol: LlmProtocol.openaiCompatible,
          baseUrl: 'https://api.openai.com',
          modelId: 'gpt-5',
        );
        final a2 = factory.getAdapter(
          protocol: LlmProtocol.openaiCompatible,
          baseUrl: 'https://api.openai.com',
          modelId: 'gpt-5',
        );
        expect(identical(a1, a2), isTrue);

        final b1 = factory.getAdapter(
          protocol: LlmProtocol.openaiCompatible,
          baseUrl: 'https://api.deepseek.com',
          modelId: 'deepseek-v4-pro',
        );
        final b2 = factory.getAdapter(
          protocol: LlmProtocol.openaiCompatible,
          baseUrl: 'https://api.deepseek.com',
          modelId: 'deepseek-v4-pro',
        );
        expect(identical(b1, b2), isTrue);

        final c1 = factory.getAdapter(
          protocol: LlmProtocol.anthropic,
          baseUrl: 'https://api.anthropic.com',
          modelId: 'claude-sonnet-4-6',
        );
        final c2 = factory.getAdapter(
          protocol: LlmProtocol.anthropic,
          baseUrl: 'https://api.anthropic.com',
          modelId: 'claude-sonnet-4-6',
        );
        expect(identical(c1, c2), isTrue);

        final d1 = factory.getAdapter(
          protocol: LlmProtocol.geminiNative,
          baseUrl: 'https://generativelanguage.googleapis.com',
          modelId: 'gemini-2.5-pro',
        );
        final d2 = factory.getAdapter(
          protocol: LlmProtocol.geminiNative,
          baseUrl: 'https://generativelanguage.googleapis.com',
          modelId: 'gemini-2.5-pro',
        );
        expect(identical(d1, d2), isTrue);
      });
    });

    group('依赖注入', () {
      test('注入自定义适配器时使用注入的实例', () {
        final customOpenAi = OpenAiAdapter();
        final customDeepSeek = DeepSeekAdapter();
        final customAnthropic = AnthropicAdapter();
        final customGemini = GeminiAdapter();

        final factory = LlmAdapterFactory(
          openaiAdapter: customOpenAi,
          deepSeekAdapter: customDeepSeek,
          anthropicAdapter: customAnthropic,
          geminiAdapter: customGemini,
        );

        expect(
          identical(
            factory.getAdapter(
              protocol: LlmProtocol.openaiCompatible,
              baseUrl: 'https://api.openai.com',
              modelId: 'gpt-5',
            ),
            customOpenAi,
          ),
          isTrue,
        );
        expect(
          identical(
            factory.getAdapter(
              protocol: LlmProtocol.openaiCompatible,
              baseUrl: 'https://api.deepseek.com',
              modelId: 'deepseek-v4-pro',
            ),
            customDeepSeek,
          ),
          isTrue,
        );
        expect(
          identical(
            factory.getAdapter(
              protocol: LlmProtocol.anthropic,
              baseUrl: 'https://api.anthropic.com',
              modelId: 'claude-sonnet-4-6',
            ),
            customAnthropic,
          ),
          isTrue,
        );
        expect(
          identical(
            factory.getAdapter(
              protocol: LlmProtocol.geminiNative,
              baseUrl: 'https://generativelanguage.googleapis.com',
              modelId: 'gemini-2.5-pro',
            ),
            customGemini,
          ),
          isTrue,
        );
      });
    });

    group('协议覆盖完整性', () {
      test('所有已实现协议都能正确分发', () {
        // 遍历所有协议枚举值，确保已实现的协议都能正确分发
        for (final protocol in LlmProtocol.values) {
          final adapter = factory.getAdapter(
            protocol: protocol,
            baseUrl: 'https://api.openai.com',
            modelId: 'gpt-5',
          );
          expect(adapter, isNotNull);
        }
      });
    });
  });
}
