import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/network/llm_adapters/anthropic_adapter.dart';
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
    double? temperature,
    double? topP,
    double? presencePenalty,
    double? frequencyPenalty,
  }) {
    return LlmRequest(
      baseUrl: 'https://api.test.com',
      apiKey: 'sk-test',
      modelId: 'test-model',
      messages: const [
        {'role': 'user', 'content': 'hi'},
      ],
      temperature: temperature,
      topP: topP,
      presencePenalty: presencePenalty,
      frequencyPenalty: frequencyPenalty,
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

    test('Anthropic 协议：temperature/top_p 取整', () {
      final body = AnthropicAdapter().buildRequestBody(
        buildRequest(temperature: 0.9500000000000001, topP: 0.5700000000000001),
        stream: false,
      );

      expect(body['temperature'], 0.95);
      expect(body['top_p'], 0.57);
    });

    test('Gemini 协议：generationConfig 内 temperature/topP 取整', () {
      final body = GeminiAdapter().buildRequestBody(
        buildRequest(temperature: 0.9500000000000001, topP: 0.5700000000000001),
        stream: false,
      );

      final generationConfig = body['generationConfig'] as Map<String, dynamic>;
      expect(generationConfig['temperature'], 0.95);
      expect(generationConfig['topP'], 0.57);
    });
  });
}
