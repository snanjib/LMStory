import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/network/llm_adapters/anthropic_adapter.dart';
import 'package:lmstory/core/network/llm_adapters/anthropic_compat_options.dart';
import 'package:lmstory/core/network/llm_adapters/gemini_adapter.dart';
import 'package:lmstory/core/network/llm_adapters/openai_adapter.dart';
import 'package:lmstory/core/network/llm_adapters/sampling_params.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';

/// 采样参数出网清洗测试
///
/// **背景**：设置界面的滑块按「min + 段长 × 档位」离散化取值，双精度
/// 段长乘法会留下浮点尾差（如拖到 0.57 实际写入 0.5700000000000001），
/// 持久化后原样进入请求体。部分厂商校验小数位数并直接 400：
/// 「top_p参数非法：限制小数点[2]位」。
///
/// **修复策略**：出网前在适配器层统一取整到 2 位小数（各设置界面均按
/// 0.01 步进展示，无信息损失）。
void main() {
  LlmRequest buildRequest({
    String modelId = 'test-model',
    double? temperature,
    double? topP,
    double? presencePenalty,
    double? frequencyPenalty,
    int? maxTokens,
    Map<String, dynamic>? providerOptions,
  }) {
    return LlmRequest(
      baseUrl: 'https://api.test.com',
      apiKey: 'sk-test',
      modelId: modelId,
      messages: const [
        {'role': 'user', 'content': 'hi'},
      ],
      temperature: temperature,
      topP: topP,
      presencePenalty: presencePenalty,
      frequencyPenalty: frequencyPenalty,
      maxTokens: maxTokens,
      providerOptions: providerOptions,
    );
  }

  group('sanitizeSamplingParam', () {
    test('null 原样返回', () {
      expect(sanitizeSamplingParam(null), isNull);
    });

    test('干净值保持不变', () {
      expect(sanitizeSamplingParam(0.95), 0.95);
      expect(sanitizeSamplingParam(0.7), 0.7);
      expect(sanitizeSamplingParam(1), 1.0);
      expect(sanitizeSamplingParam(0), 0.0);
      expect(sanitizeSamplingParam(-0.3), -0.3);
      expect(sanitizeSamplingParam(2), 2.0);
    });

    test('滑块浮点尾差取整到 2 位小数', () {
      // 实测 Flutter Slider divisions=100 时 index=57 产生的值
      expect(sanitizeSamplingParam(0.5700000000000001), 0.57);
      // divisions=20 时 index=19 产生的值（导演全局 topP 滑块）
      expect(sanitizeSamplingParam(0.9500000000000001), 0.95);
      // divisions=40 时 temperature index=14 产生的值
      expect(sanitizeSamplingParam(0.7000000000000001), 0.7);
      // penalty 滑块常见的 +0 尾差
      expect(sanitizeSamplingParam(0.30000000000000004), 0.3);
      expect(sanitizeSamplingParam(-0.30000000000000004), -0.3);
    });

    test('负零归一为 0.0，避免序列化出 "-0.0"', () {
      final result = sanitizeSamplingParam(-0.0000001);
      expect(result, 0.0);
      expect(result!.isNegative, isFalse);
      expect(jsonEncode(result), '0.0');
    });
  });

  group('isSamplingUnsupportedModel', () {
    test('识别 OpenAI o-series 与 Claude 5 / 新一代推理模型', () {
      expect(isSamplingUnsupportedModel('o1'), isTrue);
      expect(isSamplingUnsupportedModel('o1-mini'), isTrue);
      expect(isSamplingUnsupportedModel('o3-mini'), isTrue);
      expect(isSamplingUnsupportedModel('o4-mini'), isTrue);
      expect(isSamplingUnsupportedModel('openai/o1'), isTrue);
      expect(isSamplingUnsupportedModel('claude-sonnet-5-5'), isTrue);
      expect(isSamplingUnsupportedModel('claude-sonnet-5'), isTrue);
      expect(isSamplingUnsupportedModel('claude-opus-5'), isTrue);
      expect(isSamplingUnsupportedModel('claude-haiku-5'), isTrue);
      expect(isSamplingUnsupportedModel('claude-opus-4.7'), isTrue);
      expect(isSamplingUnsupportedModel('claude-opus-4-7'), isTrue);
    });

    test('识别 GPT-5.x / GPT-6 系推理模型（effort 非 none 时采样参数会 400）', () {
      expect(isSamplingUnsupportedModel('gpt-5'), isTrue);
      expect(isSamplingUnsupportedModel('gpt-5-mini'), isTrue);
      expect(isSamplingUnsupportedModel('gpt-5.5'), isTrue);
      expect(isSamplingUnsupportedModel('gpt-5.4'), isTrue);
      expect(isSamplingUnsupportedModel('gpt-5.6-terra'), isTrue);
      expect(isSamplingUnsupportedModel('gpt-5.6-sol'), isTrue);
      expect(isSamplingUnsupportedModel('gpt-6-astra'), isTrue);
      expect(isSamplingUnsupportedModel('gpt-6.1-sol'), isTrue);
      expect(isSamplingUnsupportedModel('gpt-6.1-terra'), isTrue);
      expect(isSamplingUnsupportedModel('GPT-6 Astra'), isTrue);
      expect(isSamplingUnsupportedModel('openai/gpt-5.5'), isTrue);
    });

    test('归一化匹配分隔符与厂商前缀变体', () {
      expect(isSamplingUnsupportedModel('claude-sonnet-5.5'), isTrue);
      expect(isSamplingUnsupportedModel('claude-sonnet_5_5'), isTrue);
      expect(isSamplingUnsupportedModel('Claude Sonnet 5.5'), isTrue);
      expect(isSamplingUnsupportedModel('sonnet5.5'), isTrue);
      expect(isSamplingUnsupportedModel('anthropic/claude-sonnet-5.5'), isTrue);
      expect(isSamplingUnsupportedModel('claude-5.5-sonnet'), isTrue);
      expect(isSamplingUnsupportedModel('deepseek-reasoner'), isTrue);
    });

    test('通用对话模型正常支持采样参数', () {
      expect(isSamplingUnsupportedModel('deepseek-chat'), isFalse);
      expect(isSamplingUnsupportedModel('gpt-4o'), isFalse);
      expect(isSamplingUnsupportedModel('gpt-4o-mini'), isFalse);
      expect(isSamplingUnsupportedModel('claude-3-5-sonnet-20241022'), isFalse);
      expect(isSamplingUnsupportedModel('claude-3-opus-20240229'), isFalse);
      expect(isSamplingUnsupportedModel('claude-sonnet-4-5'), isFalse);
      expect(isSamplingUnsupportedModel('claude-sonnet-4.6'), isFalse);
      expect(isSamplingUnsupportedModel('claude-opus-4-1'), isFalse);
      expect(isSamplingUnsupportedModel('claude-haiku-4-5'), isFalse);
    });

    test('识别 Kimi K 系固定值模型（传非固定值采样参数会报错）', () {
      expect(isSamplingUnsupportedModel('kimi-k3.1-pro'), isTrue);
      expect(isSamplingUnsupportedModel('kimi-k3'), isTrue);
      expect(isSamplingUnsupportedModel('kimi-k2.6'), isTrue);
      expect(isSamplingUnsupportedModel('kimi-k2-thinking'), isTrue);
      expect(isSamplingUnsupportedModel('Kimi-K2.7-Code'), isTrue);
      expect(
        isSamplingUnsupportedModel('moonshot/kimi-k3.1-pro-highspeed'),
        isTrue,
      );
    });

    test('moonshot-v1 系标准对话模型不受 Kimi 名单误伤', () {
      expect(isSamplingUnsupportedModel('moonshot-v1-8k'), isFalse);
      expect(isSamplingUnsupportedModel('moonshot-v1-32k'), isFalse);
      expect(isSamplingUnsupportedModel('moonshot-v1-thinking'), isFalse);
      expect(isSamplingUnsupportedModel('moonshot-v1-a1'), isFalse);
    });
  });

  group('shouldOmitSamplingParams · moonshot 官方端点家族', () {
    test('moonshot.cn / moonshot.ai 端点上的任意模型停发采样参数', () {
      expect(
        shouldOmitSamplingParams(
          modelId: 'moonshot-v1-8k',
          baseUrl: 'https://api.moonshot.cn/v1',
        ),
        isTrue,
      );
      expect(
        shouldOmitSamplingParams(
          modelId: 'custom-model',
          baseUrl: 'https://api.moonshot.ai/v1',
        ),
        isTrue,
      );
    });

    test('非 moonshot 端点不触发家族停发，仅名单生效', () {
      expect(
        shouldOmitSamplingParams(
          modelId: 'moonshot-v1-8k',
          baseUrl: 'https://api.openai.com/v1',
        ),
        isFalse,
      );
      expect(
        shouldOmitSamplingParams(
          modelId: 'kimi-k2.6',
          baseUrl: 'https://relay.example.com/v1',
        ),
        isTrue,
      );
    });

    test('供应商开关仍最优先于端点家族判定', () {
      expect(
        shouldOmitSamplingParams(
          modelId: 'gpt-4o',
          providerOptions: const {kOmitSamplingParamsOption: true},
          baseUrl: 'https://api.openai.com/v1',
        ),
        isTrue,
      );
    });
  });

  group('shouldOmitSamplingParams', () {
    test('供应商开关为 true 时无条件省略', () {
      expect(
        shouldOmitSamplingParams(
          modelId: 'gpt-4o',
          providerOptions: const {kOmitSamplingParamsOption: true},
        ),
        isTrue,
      );
    });

    test('只认严格 bool true，字符串与数字不生效', () {
      expect(
        shouldOmitSamplingParams(
          modelId: 'gpt-4o',
          providerOptions: const {kOmitSamplingParamsOption: 'true'},
        ),
        isFalse,
      );
      expect(
        shouldOmitSamplingParams(
          modelId: 'gpt-4o',
          providerOptions: const {kOmitSamplingParamsOption: 1},
        ),
        isFalse,
      );
    });

    test('开关为 false 不强制发送，模型能力仍可命中', () {
      expect(
        shouldOmitSamplingParams(
          modelId: 'gpt-4o',
          providerOptions: const {kOmitSamplingParamsOption: false},
        ),
        isFalse,
      );
      expect(
        shouldOmitSamplingParams(
          modelId: 'claude-sonnet-5.5',
          providerOptions: const {kOmitSamplingParamsOption: false},
        ),
        isTrue,
      );
    });
  });

  group('isOpenAIOSeriesModel · o 系单源判定', () {
    test('o1/o3/o4 前缀与路径变体命中（大小写归一）', () {
      expect(isOpenAIOSeriesModel('o1'), isTrue);
      expect(isOpenAIOSeriesModel('o1-mini'), isTrue);
      expect(isOpenAIOSeriesModel('o3-mini'), isTrue);
      expect(isOpenAIOSeriesModel('o4-mini'), isTrue);
      expect(isOpenAIOSeriesModel('OpenAI/O1'), isTrue);
      expect(isOpenAIOSeriesModel('openai/o1-mini'), isTrue);
      expect(isOpenAIOSeriesModel('azure/o3'), isTrue);
    });

    test('非 o 系不误伤', () {
      expect(isOpenAIOSeriesModel('gpt-4o'), isFalse);
      expect(isOpenAIOSeriesModel('gpt-4o-mini'), isFalse);
      expect(isOpenAIOSeriesModel('deepseek-v4-pro'), isFalse);
      expect(isOpenAIOSeriesModel('qwen3.8-max'), isFalse);
      expect(isOpenAIOSeriesModel('llama-3'), isFalse);
    });

    test('OpenAI 兼容协议：o 系路径变体走 max_completion_tokens（归一化判定）', () {
      final body = OpenAiAdapter().buildRequestBody(
        buildRequest(modelId: 'openai/o1-mini', maxTokens: 1024),
        stream: false,
      );
      expect(body['max_completion_tokens'], 1024);
      expect(body.containsKey('max_tokens'), isFalse);
    });

    test('OpenAI 兼容协议：普通模型仍走 max_tokens', () {
      final body = OpenAiAdapter().buildRequestBody(
        buildRequest(modelId: 'gpt-4o', maxTokens: 1024),
        stream: false,
      );
      expect(body['max_tokens'], 1024);
      expect(body.containsKey('max_completion_tokens'), isFalse);
    });
  });

  group('resolveAuxiliaryTemperature · 辅助调用统一温度', () {
    test('禁发判定命中（名单/端点/开关）→ null 不发参', () {
      expect(
        resolveAuxiliaryTemperature(
          modelId: 'kimi-k2.6',
          configuredTemperature: 0.3,
        ),
        isNull,
      );
      expect(
        resolveAuxiliaryTemperature(
          modelId: 'gpt-4o',
          configuredTemperature: 0.3,
          providerOptions: const {kOmitSamplingParamsOption: true},
        ),
        isNull,
      );
      expect(
        resolveAuxiliaryTemperature(
          modelId: 'custom-model',
          configuredTemperature: 0.3,
          baseUrl: 'https://api.moonshot.cn/v1',
        ),
        isNull,
      );
    });

    test('普通模型 → 统一键配置值原样透传', () {
      expect(
        resolveAuxiliaryTemperature(
          modelId: 'deepseek-chat',
          configuredTemperature: 0.3,
        ),
        0.3,
      );
      expect(
        resolveAuxiliaryTemperature(
          modelId: 'deepseek-chat',
          configuredTemperature: 0.1,
        ),
        0.1,
      );
    });
  });

  group('适配器出网取整', () {
    test('OpenAI 兼容协议：四个采样参数全部取整', () {
      final body = OpenAiAdapter().buildRequestBody(
        buildRequest(
          temperature: 0.7000000000000001,
          topP: 0.5700000000000001,
          presencePenalty: 0.6000000000000001,
          frequencyPenalty: -0.30000000000000004,
        ),
        stream: false,
      );

      expect(body['temperature'], 0.7);
      expect(body['top_p'], 0.57);
      expect(body['presence_penalty'], 0.6);
      expect(body['frequency_penalty'], -0.3);
      // 序列化后不含长尾
      expect(jsonEncode(body), isNot(contains('0000000000000001')));
    });

    test('OpenAI 兼容协议：null 参数仍不出现在请求体', () {
      final body = OpenAiAdapter().buildRequestBody(
        buildRequest(),
        stream: false,
      );

      expect(body.containsKey('temperature'), isFalse);
      expect(body.containsKey('top_p'), isFalse);
      expect(body.containsKey('presence_penalty'), isFalse);
      expect(body.containsKey('frequency_penalty'), isFalse);
    });

    test('OpenAI 兼容协议：Sonnet 5.5 自动剥离 temperature 与 top_p', () {
      final body = OpenAiAdapter().buildRequestBody(
        buildRequest(
          modelId: 'claude-sonnet-5-5',
          temperature: 0.3,
          topP: 0.95,
        ),
        stream: false,
      );

      expect(body.containsKey('temperature'), isFalse);
      expect(body.containsKey('top_p'), isFalse);
    });

    test('Anthropic 协议：默认省略 temperature/top_p', () {
      final body = AnthropicAdapter().buildRequestBody(
        buildRequest(temperature: 0.9500000000000001, topP: 0.5700000000000001),
        stream: false,
      );

      expect(body.containsKey('temperature'), isFalse);
      expect(body.containsKey('top_p'), isFalse);
    });

    test('Anthropic 协议：显式开启后取整发送', () {
      final body = AnthropicAdapter().buildRequestBody(
        buildRequest(
          temperature: 0.9500000000000001,
          topP: 0.5700000000000001,
          providerOptions: const {kAnthropicSendSamplingOption: true},
        ),
        stream: false,
      );

      expect(body['temperature'], 0.95);
      expect(body['top_p'], 0.57);
    });

    test('Anthropic 协议：模型名不再影响采样默认', () {
      final body = AnthropicAdapter().buildRequestBody(
        buildRequest(
          modelId: 'claude-sonnet-5-5',
          temperature: 0.3,
          topP: 0.95,
        ),
        stream: false,
      );

      expect(body.containsKey('temperature'), isFalse);
      expect(body.containsKey('top_p'), isFalse);
    });

    test('Gemini 协议：协议级停发，temperature/topP 不出网', () {
      final body = GeminiAdapter().buildRequestBody(
        buildRequest(temperature: 0.9500000000000001, topP: 0.5700000000000001),
        stream: false,
      );

      // 仅带采样参数的请求在协议停发后不再产出 generationConfig；
      // 即便存在（携带 maxOutputTokens 等），也不含采样键。
      final generationConfig =
          body['generationConfig'] as Map<String, dynamic>?;
      if (generationConfig != null) {
        expect(generationConfig.containsKey('temperature'), isFalse);
        expect(generationConfig.containsKey('topP'), isFalse);
      } else {
        expect(body.containsKey('generationConfig'), isFalse);
      }
    });

    test('供应商开关开启：Anthropic 省略 temperature/top_p', () {
      final body = AnthropicAdapter().buildRequestBody(
        buildRequest(
          modelId: 'claude-sonnet-4-6',
          temperature: 0.8,
          topP: 0.95,
          providerOptions: const {kOmitSamplingParamsOption: true},
        ),
        stream: false,
      );

      expect(body.containsKey('temperature'), isFalse);
      expect(body.containsKey('top_p'), isFalse);
    });

    test('供应商开关开启：OpenAI 兼容协议省略全部采样参数', () {
      final body = OpenAiAdapter().buildRequestBody(
        buildRequest(
          modelId: 'gpt-4o',
          temperature: 0.8,
          topP: 0.95,
          presencePenalty: 0.1,
          frequencyPenalty: 0.2,
          providerOptions: const {
            kOmitSamplingParamsOption: true,
            'extra_body': {'custom_flag': true},
          },
        ),
        stream: false,
      );

      expect(body.containsKey('temperature'), isFalse);
      expect(body.containsKey('top_p'), isFalse);
      expect(body.containsKey('presence_penalty'), isFalse);
      expect(body.containsKey('frequency_penalty'), isFalse);
      // extra_body 的显式透传语义不变
      expect(body['custom_flag'], isTrue);
    });

    test('供应商开关开启：Gemini 仅省略采样参数', () {
      final body = GeminiAdapter().buildRequestBody(
        buildRequest(
          modelId: 'gemini-3.6-flash',
          temperature: 0.8,
          topP: 0.95,
          maxTokens: 1024,
          providerOptions: const {kOmitSamplingParamsOption: true},
        ),
        stream: false,
      );

      final generationConfig = body['generationConfig'] as Map<String, dynamic>;
      expect(generationConfig.containsKey('temperature'), isFalse);
      expect(generationConfig.containsKey('topP'), isFalse);
      expect(generationConfig['maxOutputTokens'], 1024);
    });

    test('归一化命中：Claude Sonnet 5.5 变体在 Anthropic 协议下省略', () {
      final body = AnthropicAdapter().buildRequestBody(
        buildRequest(
          modelId: 'Claude Sonnet 5.5',
          temperature: 0.8,
          topP: 0.95,
        ),
        stream: false,
      );

      expect(body.containsKey('temperature'), isFalse);
      expect(body.containsKey('top_p'), isFalse);
    });

    test('OpenAI 兼容协议：Kimi K 系模型名单命中，剥离全部采样参数', () {
      final body = OpenAiAdapter().buildRequestBody(
        buildRequest(
          modelId: 'kimi-k2.6',
          temperature: 0.8,
          topP: 0.95,
          presencePenalty: 0.6,
          frequencyPenalty: 0.3,
        ),
        stream: false,
      );

      expect(body.containsKey('temperature'), isFalse);
      expect(body.containsKey('top_p'), isFalse);
      expect(body.containsKey('presence_penalty'), isFalse);
      expect(body.containsKey('frequency_penalty'), isFalse);
    });

    test('OpenAI 兼容协议：moonshot 官方端点家族停发，名单外模型同样省略', () {
      final request = buildRequest(
        modelId: 'moonshot-v1-8k',
        temperature: 0.7,
        topP: 1,
      );
      final body = OpenAiAdapter().buildRequestBody(
        LlmRequest(
          baseUrl: 'https://api.moonshot.cn/v1',
          apiKey: request.apiKey,
          modelId: request.modelId,
          messages: request.messages,
          temperature: request.temperature,
          topP: request.topP,
        ),
        stream: false,
      );

      expect(body.containsKey('temperature'), isFalse);
      expect(body.containsKey('top_p'), isFalse);
    });
  });
}
