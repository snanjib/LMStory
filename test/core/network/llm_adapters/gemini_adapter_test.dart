import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/intermediate_prompts_v2.dart';
import 'package:lmstory/core/network/llm_adapters/gemini_adapter.dart';
import 'package:lmstory/features/chat/domain/entities/reasoning_effort.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';

/// Gemini 适配器：非流式 finishReason 上抛与多模态 image_url 转换
void main() {
  LlmRequest buildRequest(Object content) => LlmRequest(
        baseUrl: 'https://generativelanguage.googleapis.com',
        apiKey: 'k',
        modelId: 'gemini-3.6-flash',
        messages: [
          {'role': 'user', 'content': content},
        ],
      );

  group('非流式 parseResponse 上抛 finishReason', () {
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

  group('user 消息 image_url 转 Gemini parts', () {
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
  group('能力探测（极小 maxTokens）不透传 thinkingConfig', () {
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

  group('采样参数协议级停发（Gemini 原生协议全局不发 temperature/topP）', () {
    // 官方对 Gemini 3.6+ 明文忽略自定义采样值并警告未来 400，新 API 形态
    // 已移除采样字段；老代系一并停发（生态整体弃用，需求驱动再议）。
    LlmRequest samplingRequest(String modelId) => LlmRequest(
          baseUrl: 'https://generativelanguage.googleapis.com',
          apiKey: 'k',
          modelId: modelId,
          messages: const [
            {'role': 'user', 'content': 'Hi'},
          ],
          temperature: 0.8,
          topP: 0.95,
          maxTokens: 1024,
        );

    test('gemini-3.6-flash 带 temperature/topP → generationConfig 不含', () {
      final body = GeminiAdapter().buildRequestBody(
        samplingRequest('gemini-3.6-flash'),
        stream: false,
      );
      final config = body['generationConfig'] as Map<String, dynamic>?;
      expect(config, isNotNull);
      expect(config!.containsKey('temperature'), isFalse);
      expect(config.containsKey('topP'), isFalse);
    });

    test('gemini-2.5-flash 同样停发（协议级，不分代次）', () {
      final body = GeminiAdapter().buildRequestBody(
        samplingRequest('gemini-2.5-flash'),
        stream: false,
      );
      final config = body['generationConfig'] as Map<String, dynamic>?;
      expect(config, isNotNull);
      expect(config!.containsKey('temperature'), isFalse);
      expect(config.containsKey('topP'), isFalse);
    });
  });

  group('gemini-4 thinkingConfig 分支（与 3 系同轨）', () {
    LlmRequest thinkingRequest(
      String modelId,
      ReasoningEffort effort, {
      int? maxTokens,
    }) =>
        LlmRequest(
          baseUrl: 'https://generativelanguage.googleapis.com',
          apiKey: 'k',
          modelId: modelId,
          messages: const [
            {'role': 'user', 'content': 'Hi'},
          ],
          maxTokens: maxTokens,
          reasoningEffort: effort,
        );

    test('gemini-4-argon 启用思考 → thinkingLevel', () {
      final body = GeminiAdapter().buildRequestBody(
        thinkingRequest(
          'gemini-4-argon',
          ReasoningEffort.high,
          maxTokens: 8192,
        ),
        stream: false,
      );
      final config = body['generationConfig'] as Map<String, dynamic>;
      expect(config['thinkingConfig'], {'thinkingLevel': 'high'});
    });

    test('gemini-4-argon 显式禁用 → thinkingBudget:0（3 系同轨保守处理）', () {
      final body = GeminiAdapter().buildRequestBody(
        thinkingRequest(
          'gemini-4-argon',
          ReasoningEffort.disabled,
          maxTokens: 8192,
        ),
        stream: false,
      );
      final config = body['generationConfig'] as Map<String, dynamic>;
      expect(config['thinkingConfig'], {'thinkingBudget': 0});
    });
  });

  // 2.5 自动映射的 thinkingBudget
  // 须小于 maxOutputTokens——medium=8192 恰等于常见 maxTokens、
  // high=24576 直接越界，均 400。钳到 maxTokens-1024；钳后低于
  // low 档 1024 则不发 thinkingConfig（交模型默认，好过必 400）。
  group('2.5 thinkingBudget 钳制（< maxOutputTokens）', () {
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

  // Gemini 的 functionDeclarations.parameters / responseSchema 只接受
  // Schema proto 子集：additionalProperties 会让整请求 400 INVALID_ARGUMENT。
  // 工具定义不能直接删键（OpenAI strict 仍需要），只能在出网边界裁剪。
  group('Gemini schema 出网裁剪', () {
    test('工具 parameters 剥离 additionalProperties，原 const 定义不受污染', () {
      final body = GeminiAdapter().buildRequestBody(
        const LlmRequest(
          baseUrl: 'https://generativelanguage.googleapis.com',
          apiKey: 'k',
          modelId: 'gemini-3.6-flash',
          messages: [
            {'role': 'user', 'content': 'Hi'},
          ],
          tools: [kExtractKeywordsToolDefinition],
        ),
        stream: true,
      );

      final tools = body['tools'] as Map<String, dynamic>;
      final declarations = tools['functionDeclarations'] as List<dynamic>;
      final declaration = declarations.single as Map<String, dynamic>;
      final parameters = declaration['parameters'] as Map<String, dynamic>;

      expect(parameters.containsKey('additionalProperties'), isFalse);
      expect(jsonEncode(body), isNot(contains('additionalProperties')));
      expect(
        kExtractKeywordsToolDefinition.parameters['additionalProperties'],
        isFalse,
      );
    });

    test('responseSchema 同样裁剪', () {
      final body = GeminiAdapter().buildRequestBody(
        const LlmRequest(
          baseUrl: 'https://generativelanguage.googleapis.com',
          apiKey: 'k',
          modelId: 'gemini-3.6-flash',
          messages: [
            {'role': 'user', 'content': 'Hi'},
          ],
          responseFormat: LlmResponseFormatJsonSchema(
            name: 'probe',
            schema: {
              'type': 'object',
              'properties': {
                'value': {'type': 'string'},
              },
              'required': ['value'],
              'additionalProperties': false,
            },
          ),
        ),
        stream: false,
      );

      final config = body['generationConfig'] as Map<String, dynamic>;
      final schema = config['responseSchema'] as Map<String, dynamic>;
      expect(schema.containsKey('additionalProperties'), isFalse);
      expect(schema['type'], 'object');
    });
  });

  group('Gemini 3 thought 签名（Part 层级 thoughtSignature）', () {
    test('parseResponse：thought part 签名进 thinkingBlocks，明文进 reasoningContent',
        () {
      final parsed = GeminiAdapter().parseResponse({
        'candidates': [
          {
            'content': {
              'parts': [
                {
                  'thought': true,
                  'text': 'thinking-1',
                  'thoughtSignature': 'sig-1',
                },
                {'text': 'answer'},
                {
                  'thought': true,
                  'text': 'thinking-2',
                  'thoughtSignature': 'sig-2',
                },
              ],
              'role': 'model',
            },
            'finishReason': 'STOP',
            'index': 0,
          },
        ],
      });

      expect(parsed.content, 'answer');
      expect(parsed.reasoningContent, 'thinking-1thinking-2');
      // LlmThinkingBlock 未实现 ==，逐字段断言
      expect(parsed.thinkingBlocks!.length, 2);
      expect(parsed.thinkingBlocks![0].thinking, 'thinking-1');
      expect(parsed.thinkingBlocks![0].signature, 'sig-1');
      expect(parsed.thinkingBlocks![1].thinking, 'thinking-2');
      expect(parsed.thinkingBlocks![1].signature, 'sig-2');
    });

    test('回传：thinkingBlocks → thought parts 原样携带 thoughtSignature', () {
      final body = GeminiAdapter().buildRequestBody(
        const LlmRequest(
          baseUrl: 'https://generativelanguage.googleapis.com',
          apiKey: 'k',
          modelId: 'gemini-3-pro',
          messages: [
            {
              'role': 'assistant',
              'content': 'answer',
              'thinkingBlocks': [
                {'thinking': 't1', 'signature': 'sig-1'},
                {'thinking': 't2'},
              ],
            },
          ],
        ),
        stream: false,
      );

      final parts = ((body['contents'] as List).first
          as Map<String, dynamic>)['parts'] as List;
      expect(parts[0], {
        'thought': true,
        'text': 't1',
        'thoughtSignature': 'sig-1',
      });
      // 无签名的块（旧数据/降级）不带 thoughtSignature 键
      expect(parts[1], {'thought': true, 'text': 't2'});
      expect(parts[2], {'text': 'answer'});
    });
  });
}
