import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/network/llm_adapters/gemini_adapter.dart';
import 'package:lmstory/features/chat/domain/entities/reasoning_effort.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';

/// Gemini 适配器：非流式 finishReason 上抛（XC-2）与多模态 image_url 转换（CF-2）
void main() {
  LlmRequest buildRequest(Object content) => LlmRequest(
        baseUrl: 'https://generativelanguage.googleapis.com',
        apiKey: 'k',
        modelId: 'gemini-3.6-flash',
        messages: [
          {'role': 'user', 'content': content},
        ],
      );

  group('XC-2：非流式 parseResponse 上抛 finishReason', () {
    Map<String, dynamic> response(String? finishReason) => {
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': 'hi'},
                ],
                'role': 'model',
              },
              'finishReason': finishReason,
              'index': 0,
            },
          ],
          'usageMetadata': {
            'promptTokenCount': 3,
            'candidatesTokenCount': 2,
            'totalTokenCount': 5,
          },
        };

    test('finishReason=MAX_TOKENS 原样上抛（与流式 B5-6 词表一致）', () {
      final parsed = GeminiAdapter().parseResponse(response('MAX_TOKENS'));
      expect(parsed.finishReason, 'MAX_TOKENS');
    });

    test('finishReason=STOP 原样上抛', () {
      final parsed = GeminiAdapter().parseResponse(response('STOP'));
      expect(parsed.finishReason, 'STOP');
    });

    test('finishReason 缺失时为 null', () {
      final parsed = GeminiAdapter().parseResponse(response(null));
      expect(parsed.finishReason, isNull);
    });

    test('SAFETY 分支的空响应同样携带 finishReason', () {
      final parsed = GeminiAdapter().parseResponse(response('SAFETY'));
      expect(parsed.content, isEmpty);
      expect(parsed.finishReason, 'SAFETY');
    });
  });

  group('CF-2：user 消息 image_url 转 Gemini parts', () {
    test('data: base64 URL → inlineData（mimeType + data）', () {
      final body = GeminiAdapter().buildRequestBody(
        buildRequest([
          {'type': 'text', 'text': '这张图里有什么？'},
          {
            'type': 'image_url',
            'image_url': {'url': 'data:image/png;base64,aGVsbG8='},
          },
        ]),
        stream: false,
      );

      final parts = ((body['contents'] as List).first
          as Map<String, dynamic>)['parts'] as List<dynamic>;
      expect(parts, hasLength(2));
      expect(parts[0], {'text': '这张图里有什么？'});
      expect(parts[1], {
        'inlineData': {'mimeType': 'image/png', 'data': 'aGVsbG8='},
      });
    });

    test('http(s) URL 无法直传（fileData 仅接受 Files API / gs://），降级为文本提示', () {
      final body = GeminiAdapter().buildRequestBody(
        buildRequest([
          {
            'type': 'image_url',
            'image_url': {'url': 'https://example.com/pic.jpg'},
          },
        ]),
        stream: false,
      );

      final parts = ((body['contents'] as List).first
          as Map<String, dynamic>)['parts'] as List<dynamic>;
      expect(parts, hasLength(1));
      // 不得静默丢弃：模型至少要知道有一张图未被发送
      final text = (parts.single as Map)['text'] as String;
      expect(text, contains('https://example.com/pic.jpg'));
    });

    test('纯文本 user 消息不受影响（零行为差异）', () {
      final body = GeminiAdapter().buildRequestBody(
        buildRequest('纯文本输入'),
        stream: false,
      );

      final parts = ((body['contents'] as List).first
          as Map<String, dynamic>)['parts'] as List<dynamic>;
      expect(parts.single, {'text': '纯文本输入'});
    });
  });

  // Gemini 侧补 S-2 同款护栏——模型实测探针
  // （maxTokens=1/10/50）携带 preset 的 providerOptions 出网，用户配
  // thinkingBudget:8192 之类时违反「thinkingBudget 须小于 maxOutputTokens」
  // 约束，探测 400 误判「模型不可用」（与 S-2 修复前的 Anthropic 同构）。
  group('CF7-5：能力探测（极小 maxTokens）不透传 thinkingConfig', () {
    LlmRequest probe({
      int? maxTokens,
      Map<String, dynamic>? providerOptions,
      ReasoningEffort? reasoningEffort,
      String modelId = 'gemini-2.5-flash',
    }) =>
        LlmRequest(
          baseUrl: 'https://generativelanguage.googleapis.com',
          apiKey: 'k',
          modelId: modelId,
          messages: const [
            {'role': 'user', 'content': 'Hi'},
          ],
          maxTokens: maxTokens,
          providerOptions: providerOptions,
          reasoningEffort: reasoningEffort,
        );

    Object? thinkingConfigOf(Map<String, dynamic> body) =>
        (body['generationConfig'] as Map<String, dynamic>?)?['thinkingConfig'];

    test('maxTokens=1 + providerOptions.thinkingConfig 大预算 → 不发', () {
      final body = GeminiAdapter().buildRequestBody(
        probe(
          maxTokens: 1,
          providerOptions: {
            'thinkingConfig': {'thinkingBudget': 8192},
          },
        ),
        stream: false,
      );
      expect(
        thinkingConfigOf(body),
        isNull,
        reason: 'thinkingBudget 须小于 maxOutputTokens，maxTokens=1 时'
            ' 任何正预算都必然 400，模型实测会误判「模型不可用」',
      );
    });

    test('maxTokens=50 探针档 + thinkingConfig → 同样不发', () {
      final body = GeminiAdapter().buildRequestBody(
        probe(
          maxTokens: 50,
          providerOptions: {
            'thinkingConfig': {'thinkingBudget': 8192},
          },
        ),
        stream: false,
      );
      expect(thinkingConfigOf(body), isNull);
    });

    test('maxTokens=1 + reasoningEffort 自动映射 → 不发 thinkingConfig', () {
      final body = GeminiAdapter().buildRequestBody(
        probe(maxTokens: 1, reasoningEffort: ReasoningEffort.high),
        stream: false,
      );
      expect(thinkingConfigOf(body), isNull);
    });

    test('正常 maxTokens 时 providerOptions.thinkingConfig 照常透传（不回退）', () {
      final body = GeminiAdapter().buildRequestBody(
        probe(
          maxTokens: 8192,
          providerOptions: {
            'thinkingConfig': {'thinkingBudget': 8192},
          },
        ),
        stream: false,
      );
      expect(
        thinkingConfigOf(body),
        {
          'thinkingBudget': 8192,
        },
      );
    });

    test('显式禁用不受护栏影响（thinkingBudget:0 恒合法）', () {
      final body = GeminiAdapter().buildRequestBody(
        probe(
          maxTokens: 1,
          reasoningEffort: ReasoningEffort.disabled,
        ),
        stream: false,
      );
      expect(thinkingConfigOf(body), {'thinkingBudget': 0});
    });

    // 2026-09-08 修复：gemini-3* 显式禁用改发 thinkingBudget:0——真机
    // 实测 gemini-3.8-flash 对 thinkingLevel:"off" 返回 400 INVALID_ARGUMENT
    // （ThinkingLevel 枚举仅 low/medium/high），用户侧表现为带该配置的
    // 每次生成都失败。2.5 分支同参（既有行为保持）。
    test('gemini-3.8 显式禁用 → thinkingBudget:0（thinkingLevel:off 必 400）', () {
      final body = GeminiAdapter().buildRequestBody(
        probe(
          maxTokens: 8192,
          reasoningEffort: ReasoningEffort.disabled,
          modelId: 'gemini-3.8-flash',
        ),
        stream: false,
      );
      expect(thinkingConfigOf(body), {'thinkingBudget': 0});
    });
  });

  // 2.5 自动映射的 thinkingBudget
  // 须小于 maxOutputTokens——medium=8192 恰等于常见 maxTokens、
  // high=24576 直接越界，均 400。钳到 maxTokens-1024；钳后低于
  // low 档 1024 则不发 thinkingConfig（交模型默认，好过必 400）。
  group('CF12-2：2.5 thinkingBudget 钳制（< maxOutputTokens）', () {
    Object? thinkingConfigOf(Map<String, dynamic> body) =>
        (body['generationConfig'] as Map<String, dynamic>?)?['thinkingConfig'];

    Map<String, dynamic> bodyOf({
      required int? maxTokens,
      required ReasoningEffort effort,
    }) =>
        GeminiAdapter().buildRequestBody(
          LlmRequest(
            baseUrl: 'https://generativelanguage.googleapis.com',
            apiKey: 'k',
            modelId: 'gemini-2.5-flash',
            messages: const [
              {'role': 'user', 'content': 'Hi'},
            ],
            maxTokens: maxTokens,
            reasoningEffort: effort,
          ),
          stream: false,
        );

    test('maxTokens=8192 + medium → 预算钳到 7168（不是恰等的 8192）', () {
      final body = bodyOf(maxTokens: 8192, effort: ReasoningEffort.medium);
      expect(thinkingConfigOf(body), {'thinkingBudget': 7168});
    });

    test('maxTokens=4096 + high → 钳到 3072（不是 24576）', () {
      final body = bodyOf(maxTokens: 4096, effort: ReasoningEffort.high);
      expect(thinkingConfigOf(body), {'thinkingBudget': 3072});
    });

    test('maxTokens=1500 + low → 钳后低于 1024 → 不发 thinkingConfig', () {
      final body = bodyOf(maxTokens: 1500, effort: ReasoningEffort.low);
      expect(thinkingConfigOf(body), isNull);
    });

    test('maxTokens=null + high → 预算 24576 原样（无上界可依）', () {
      final body = bodyOf(maxTokens: null, effort: ReasoningEffort.high);
      expect(thinkingConfigOf(body), {'thinkingBudget': 24576});
    });

    test('gemini-3 走 thinkingLevel 不受钳制影响', () {
      final body = GeminiAdapter().buildRequestBody(
        const LlmRequest(
          baseUrl: 'https://generativelanguage.googleapis.com',
          apiKey: 'k',
          modelId: 'gemini-3.8-flash',
          messages: [
            {'role': 'user', 'content': 'Hi'},
          ],
          maxTokens: 4096,
          reasoningEffort: ReasoningEffort.high,
        ),
        stream: false,
      );
      expect(thinkingConfigOf(body), {'thinkingLevel': 'high'});
    });
  });
}
