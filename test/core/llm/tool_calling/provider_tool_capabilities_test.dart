import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/llm/tool_calling/provider_tool_capabilities.dart';
import 'package:lmstory/core/llm/tool_calling/tool_choice.dart';
import 'package:lmstory/features/settings/domain/entities/llm_protocol.dart';

void main() {
  group('ProviderToolCapabilities.resolve', () {
    test('OpenAI 官方端点 → full', () {
      final caps = ProviderToolCapabilities.resolve(
        protocol: LlmProtocol.openaiCompatible,
        baseUrl: 'https://api.openai.com/v1',
        modelId: 'gpt-5.6',
      );
      expect(caps.parallelToolCalls, isTrue);
      expect(caps.streamingToolCallsReliable, isTrue);
      expect(caps.supportedToolChoices, containsAll(ToolChoice.values));
    });

    test('GLM 直连域名 → zhipu 画像（tool_stream + 仅 auto）', () {
      final caps = ProviderToolCapabilities.resolve(
        protocol: LlmProtocol.openaiCompatible,
        baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
        modelId: 'glm-5',
      );
      expect(caps.requiresToolStreamFlag, isTrue);
      expect(caps.supportedToolChoices, {ToolChoice.auto, ToolChoice.none});
      expect(
        caps.resolveToolChoice(ToolChoice.required),
        ToolChoice.auto,
      );
    });

    test('GLM 模型指纹（自定义端点 + glm- 前缀）→ zhipu 画像', () {
      final caps = ProviderToolCapabilities.resolve(
        protocol: LlmProtocol.openaiCompatible,
        baseUrl: 'https://my-relay.example.com/v1',
        modelId: 'GLM-5-Plus',
      );
      expect(caps.requiresToolStreamFlag, isTrue);
    });

    test('Qwen 百炼域名 → alibaba 画像（并行默认关）', () {
      final caps = ProviderToolCapabilities.resolve(
        protocol: LlmProtocol.openaiCompatible,
        baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
        modelId: 'qwen3-max',
      );
      expect(caps.parallelToolCalls, isFalse);
      expect(caps.supportedToolChoices, contains(ToolChoice.required));
    });

    test('DeepSeek 域名 → deepseek 画像', () {
      final caps = ProviderToolCapabilities.resolve(
        protocol: LlmProtocol.openaiCompatible,
        baseUrl: 'https://api.deepseek.com/v1',
        modelId: 'deepseek-v4',
      );
      expect(caps.parallelToolCalls, isFalse);
      expect(caps.resolveToolChoice(ToolChoice.required), ToolChoice.auto);
    });

    test('Gemini 原生协议 → 本地 id + thoughtSignature', () {
      final caps = ProviderToolCapabilities.resolve(
        protocol: LlmProtocol.geminiNative,
        baseUrl: 'https://generativelanguage.googleapis.com',
        modelId: 'gemini-3.6-pro',
      );
      expect(caps.idStrategy, ToolCallIdStrategy.locallyGenerated);
      expect(caps.preservesThoughtSignature, isTrue);
      expect(caps.parallelToolCalls, isFalse);
    });

    test('Anthropic 协议 → full（server id）', () {
      final caps = ProviderToolCapabilities.resolve(
        protocol: LlmProtocol.anthropic,
        baseUrl: 'https://api.anthropic.com',
        modelId: 'claude-sonnet-4-6',
      );
      expect(caps.idStrategy, ToolCallIdStrategy.serverProvided);
      expect(caps.parallelToolCalls, isTrue);
    });

    test('未知中转站 → 保守档（工具步回退非流式）', () {
      final caps = ProviderToolCapabilities.resolve(
        protocol: LlmProtocol.openaiCompatible,
        baseUrl: 'https://relay.unknown.io/v1',
        modelId: 'some-model',
      );
      expect(caps.streamingToolCallsReliable, isFalse);
      expect(caps.parallelToolCalls, isFalse);
    });

    test('OpenRouter → full（中间层已抹平）', () {
      final caps = ProviderToolCapabilities.resolve(
        protocol: LlmProtocol.openaiCompatible,
        baseUrl: 'https://openrouter.ai/api/v1',
        modelId: 'deepseek/deepseek-v4',
      );
      expect(caps.streamingToolCallsReliable, isTrue);
    });
  });
}
