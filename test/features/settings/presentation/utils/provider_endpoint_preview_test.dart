import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/settings/domain/entities/llm_protocol.dart';
import 'package:lmstory/features/settings/presentation/utils/provider_endpoint_preview.dart';

/// 供应商 baseUrl 预览 URL 按协议分流测试（CF-3）
///
/// 预览必须与真实出网同源：经 LlmAdapterFactory 分发到对应适配器的
/// buildUrl，而不是硬编码 /chat/completions。期望值与各适配器实现
/// 逐一对齐（openai/deepseek→/chat/completions、anthropic→/messages、
/// gemini→/v1beta/models/{model}:generateContent）。
void main() {
  group('buildProviderEndpointPreview（CF-3 协议分流预览）', () {
    test('openaiCompatible：版本号自动补全 + /chat/completions', () {
      expect(
        buildProviderEndpointPreview(
          protocol: LlmProtocol.openaiCompatible,
          baseUrl: 'https://api.openai.com',
        ),
        'https://api.openai.com/v1/chat/completions',
      );
    });

    test('openaiCompatible：baseUrl 已含 /v1 时不重复补版本号', () {
      expect(
        buildProviderEndpointPreview(
          protocol: LlmProtocol.openaiCompatible,
          baseUrl: 'https://openrouter.ai/api/v1',
        ),
        'https://openrouter.ai/api/v1/chat/completions',
      );
    });

    test('anthropic：端点为 /messages 而非 /chat/completions', () {
      expect(
        buildProviderEndpointPreview(
          protocol: LlmProtocol.anthropic,
          baseUrl: 'https://api.anthropic.com',
        ),
        'https://api.anthropic.com/v1/messages',
      );
    });

    test('geminiNative：端点为 /v1beta/models/{model}:generateContent', () {
      expect(
        buildProviderEndpointPreview(
          protocol: LlmProtocol.geminiNative,
          baseUrl: 'https://generativelanguage.googleapis.com',
        ),
        'https://generativelanguage.googleapis.com'
        '/v1beta/models/{model}:generateContent',
      );
    });

    test('openaiResponses：适配器未实现，回退 OpenAI 兼容路径不抛错', () {
      expect(
        buildProviderEndpointPreview(
          protocol: LlmProtocol.openaiResponses,
          baseUrl: 'https://api.openai.com',
        ),
        'https://api.openai.com/v1/chat/completions',
      );
    });
  });
}
