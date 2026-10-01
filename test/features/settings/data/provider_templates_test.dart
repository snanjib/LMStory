import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/settings/data/provider_templates.dart';
import 'package:lmstory/features/settings/domain/entities/llm_protocol.dart';

void main() {
  group('ProviderTemplates', () {
    test('all 包含 7 个模板', () {
      expect(ProviderTemplates.all.length, 7);
    });

    test('每个 templateId 唯一', () {
      final ids = ProviderTemplates.all.map((t) => t.templateId).toSet();
      expect(ids.length, 7);
    });

    test('每个 builtInPresetId 唯一', () {
      final ids = ProviderTemplates.all.map((t) => t.builtInPresetId).toSet();
      expect(ids.length, 7);
    });

    test('findById 正确查找', () {
      final t = ProviderTemplates.findById('tpl-openai');
      expect(t, isNotNull);
      expect(t!.name, 'OpenAI');
      expect(t.protocol, LlmProtocol.openaiCompatible);
      expect(t.defaultBaseUrl, 'https://api.openai.com');
    });

    test('findById 不存在时返回 null', () {
      expect(ProviderTemplates.findById('tpl-notexist'), isNull);
    });

    test('findByBuiltInPresetId 正确反查', () {
      final t = ProviderTemplates.findByBuiltInPresetId('builtin-anthropic');
      expect(t, isNotNull);
      expect(t!.templateId, 'tpl-anthropic');
      expect(t.protocol, LlmProtocol.anthropic);
    });

    test('builtInPresetId 推导：tpl-openai → builtin-openai', () {
      final t = ProviderTemplates.findById('tpl-openai')!;
      expect(t.builtInPresetId, 'builtin-openai');
    });

    group('模板内容验证', () {
      test('OpenAI 模板', () {
        final t = ProviderTemplates.findById('tpl-openai')!;
        expect(t.name, 'OpenAI');
        expect(t.protocol, LlmProtocol.openaiCompatible);
        expect(t.defaultBaseUrl, 'https://api.openai.com');
        expect(t.websiteUrl, 'https://openai.com');
        expect(t.docsUrl, 'https://platform.openai.com/docs');
        expect(t.apiKeyUrl, 'https://platform.openai.com/api-keys');
      });

      test('DeepSeek 模板', () {
        final t = ProviderTemplates.findById('tpl-deepseek')!;
        expect(t.name, 'DeepSeek');
        expect(t.protocol, LlmProtocol.openaiCompatible);
        expect(t.defaultBaseUrl, 'https://api.deepseek.com');
      });

      test('OpenRouter 模板 baseUrl 必须带 /v1', () {
        // 修复历史 bug：原硬编码 baseUrl 为 https://openrouter.ai/api（缺 /v1）
        // 导致 API 请求 404
        final t = ProviderTemplates.findById('tpl-openrouter')!;
        expect(t.defaultBaseUrl, 'https://openrouter.ai/api/v1');
      });

      test('Anthropic 模板', () {
        final t = ProviderTemplates.findById('tpl-anthropic')!;
        expect(t.name, 'Anthropic Claude');
        expect(t.protocol, LlmProtocol.anthropic);
        expect(t.defaultBaseUrl, 'https://api.anthropic.com');
      });

      test('Gemini 模板', () {
        final t = ProviderTemplates.findById('tpl-gemini')!;
        expect(t.name, 'Google Gemini');
        expect(t.protocol, LlmProtocol.geminiNative);
        expect(t.defaultBaseUrl, 'https://generativelanguage.googleapis.com');
      });

      test('NVIDIA NIM 模板', () {
        final t = ProviderTemplates.findById('tpl-nvidia-nim')!;
        expect(t.name, 'NVIDIA NIM');
        expect(t.protocol, LlmProtocol.openaiCompatible);
        expect(t.defaultBaseUrl, 'https://integrate.api.nvidia.com');
      });

      test('Agnes AI 模板', () {
        final t = ProviderTemplates.findById('tpl-agnes')!;
        expect(t.name, 'Agnes AI');
        expect(t.protocol, LlmProtocol.openaiCompatible);
        expect(t.defaultBaseUrl, 'https://apihub.agnes-ai.com');
      });
    });

    group('协议分布', () {
      test('openaiCompatible 协议有 5 个模板', () {
        final count = ProviderTemplates.all
            .where((t) => t.protocol == LlmProtocol.openaiCompatible)
            .length;
        expect(count, 5);
      });

      test('anthropic 协议有 1 个模板', () {
        final count = ProviderTemplates.all
            .where((t) => t.protocol == LlmProtocol.anthropic)
            .length;
        expect(count, 1);
      });

      test('geminiNative 协议有 1 个模板', () {
        final count = ProviderTemplates.all
            .where((t) => t.protocol == LlmProtocol.geminiNative)
            .length;
        expect(count, 1);
      });
    });
  });
}
