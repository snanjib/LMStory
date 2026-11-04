import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/llm/tool_calling/tool_choice.dart';
import 'package:lmstory/core/llm/tool_calling/tool_definition.dart';
import 'package:lmstory/core/network/llm_adapters/anthropic_adapter.dart';
import 'package:lmstory/core/network/llm_adapters/anthropic_compat_options.dart';
import 'package:lmstory/features/advanced/domain/services/agent_system_prompt.dart';
import 'package:lmstory/features/chat/domain/entities/reasoning_effort.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';

/// 长会话退化治理 /：Anthropic 适配器消息转换回归。
///
///  的角色约定（轮尾 harness 内容用 role=user + workbench-reminder 标记）
/// 与  的跨轮工作痕迹（assistant 正文后紧跟 user trace）都依赖：
/// 1. user 消息不上提到顶层 system 字段，保住 recency 位；
/// 2. 连续 user 消息原样透传，不被丢弃或合并（Anthropic 官方语义：
///    连续同角色消息由服务端自动合并为一个 turn）；
/// 3. 既有 system 上提行为不回退。
void main() {
  const tools = [
    ToolDefinition(
      name: 'search_story',
      description: 'search',
      parameters: {'type': 'object'},
    ),
  ];

  LlmRequest buildRequest(List<Map<String, dynamic>> messages) => LlmRequest(
        baseUrl: 'https://api.anthropic.com',
        apiKey: 'k',
        modelId: 'claude-sonnet-4-6',
        messages: messages,
        tools: tools,
        toolChoice: ToolChoice.auto,
      );

  test('S2：role=user 的轮尾契约留在 messages 原位，不上提 system', () {
    final body = AnthropicAdapter().buildRequestBody(
      buildRequest([
        {'role': 'system', 'content': 'SYSTEM-FROZEN'},
        {'role': 'user', 'content': '导演输入'},
        //  工作痕迹 +  尾部契约：连续 user 合成消息
        {'role': 'assistant', 'content': '正文。'},
        {'role': 'user', 'content': '〈round-work n=12〉查记忆×2〈/round-work〉'},
        {
          'role': 'user',
          'content': wrapWorkbenchReminder('【工作契约】记忆/事实/锚点/技能工具本轮随时可用。'),
        },
        {
          'role': 'user',
          'content': wrapWorkbenchReminder('【文风铁律】禁破折号。'),
        },
      ]),
      stream: true,
    );

    // system 顶层只有冻结前缀，未被轮尾内容污染
    final system = (body['system'] as List).cast<Map<String, dynamic>>();
    expect(system, hasLength(1));
    expect(jsonEncode(system), isNot(contains('workbench-reminder')));
    expect(jsonEncode(system), isNot(contains('round-work')));

    // messages 顺序与角色完整保留：user 消息一条不丢、位置不变
    final messages = (body['messages'] as List).cast<Map<String, dynamic>>();
    expect(messages, hasLength(5));
    expect(messages.map((m) => m['role']).toList(), [
      'user',
      'assistant',
      'user',
      'user',
      'user',
    ]);
    // 尾部契约在最后（recency 位），内容带标记原样到达
    expect(
      (messages.last['content'] as String).startsWith(kWorkbenchReminderOpen),
      isTrue,
    );
  });

  test('S1：连续 user 消息（trace + 下一轮输入）原样透传不合并', () {
    final body = AnthropicAdapter().buildRequestBody(
      buildRequest([
        {'role': 'system', 'content': 'SYSTEM-FROZEN'},
        {'role': 'user', 'content': '第一轮输入'},
        {'role': 'assistant', 'content': '第一轮正文。'},
        {'role': 'user', 'content': '〈round-work n=1〉本轮无工具调用〈/round-work〉'},
        {'role': 'user', 'content': '第二轮输入'},
      ]),
      stream: true,
    );

    final messages = (body['messages'] as List).cast<Map<String, dynamic>>();
    // 适配器不做合并（服务端负责合并同角色 turn）；丢弃或错序会破坏
    // 轮次边界与 trace 语义。
    // 倒数第二条（trace）作为断点目标被包成 text 块，文本原样保留
    expect(messages, hasLength(4));
    final traceContent = messages[2]['content'];
    final traceText = traceContent is List
        ? (traceContent.last as Map)['text'] as String
        : traceContent as String;
    expect(traceText, contains('round-work'));
    expect(messages[3]['content'], '第二轮输入');
  });

  test('既有行为不回退：system 消息仍上提到顶层字段', () {
    final body = AnthropicAdapter().buildRequestBody(
      buildRequest([
        {'role': 'system', 'content': 'PREFIX'},
        {'role': 'system', 'content': 'CORE-BLOCKS'},
        {'role': 'user', 'content': '输入'},
      ]),
      stream: true,
    );

    expect(jsonEncode(body['system']), contains('PREFIX'));
    expect(jsonEncode(body['system']), contains('CORE-BLOCKS'));
    final messages = (body['messages'] as List).cast<Map<String, dynamic>>();
    expect(messages, hasLength(1));
    expect(messages.single['role'], 'user');
  });

  group('user 消息 image_url 转 Anthropic image block', () {
    LlmRequest visionRequest(Object content) => LlmRequest(
          baseUrl: 'https://api.anthropic.com',
          apiKey: 'k',
          modelId: 'claude-sonnet-4-6',
          messages: [
            {'role': 'user', 'content': content},
          ],
        );

    test('data: base64 URL → source{type:base64}，text 块保序', () {
      final body = AnthropicAdapter().buildRequestBody(
        visionRequest([
          {'type': 'text', 'text': '这张图里有什么？'},
          {
            'type': 'image_url',
            'image_url': {'url': 'data:image/png;base64,aGVsbG8='},
          },
        ]),
        stream: true,
      );

      final content = ((body['messages'] as List).first
          as Map<String, dynamic>)['content'] as List<dynamic>;
      expect(content, hasLength(2));
      expect(content[0], {'type': 'text', 'text': '这张图里有什么？'});
      expect(content[1], {
        'type': 'image',
        'source': {
          'type': 'base64',
          'media_type': 'image/png',
          'data': 'aGVsbG8=',
        },
      });
      // 不应残留 OpenAI 风格 image_url（原样透传必 400）
      expect(jsonEncode(body), isNot(contains('image_url')));
    });

    test('http(s) URL → source{type:url}', () {
      final body = AnthropicAdapter().buildRequestBody(
        visionRequest([
          {
            'type': 'image_url',
            'image_url': {'url': 'https://example.com/pic.jpg'},
          },
        ]),
        stream: true,
      );

      final content = ((body['messages'] as List).first
          as Map<String, dynamic>)['content'] as List<dynamic>;
      expect(content.single, {
        'type': 'image',
        'source': {'type': 'url', 'url': 'https://example.com/pic.jpg'},
      });
    });

    test('不含 image_url 的 user 消息保持原样透传（零行为差异）', () {
      final original = [
        {'type': 'text', 'text': '纯文本'},
      ];
      final body = AnthropicAdapter().buildRequestBody(
        visionRequest(original),
        stream: true,
      );

      expect(
        ((body['messages'] as List).first as Map<String, dynamic>)['content'],
        same(original),
      );
    });

    test('String content 的 user 消息保持字符串直传', () {
      final body = AnthropicAdapter().buildRequestBody(
        visionRequest('纯字符串输入'),
        stream: true,
      );

      expect(
        ((body['messages'] as List).first as Map<String, dynamic>)['content'],
        '纯字符串输入',
      );
    });
  });

  group('非流式 parseResponse 上抛 finishReason', () {
    Map<String, dynamic> response(String? stopReason) => {
          'id': 'msg_1',
          'type': 'message',
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': 'hi'},
          ],
          'stop_reason': stopReason,
          'usage': {'input_tokens': 3, 'output_tokens': 2},
        };

    test('stop_reason=max_tokens 映射为 length（截断诊断可用）', () {
      final parsed = AnthropicAdapter().parseResponse(response('max_tokens'));
      expect(parsed.finishReason, 'length');
    });

    test('stop_reason=end_turn 映射为 stop', () {
      final parsed = AnthropicAdapter().parseResponse(response('end_turn'));
      expect(parsed.finishReason, 'stop');
    });

    test('stop_reason 缺失时 finishReason 为 null', () {
      final parsed = AnthropicAdapter().parseResponse(response(null));
      expect(parsed.finishReason, isNull);
    });
  });

  group('S-2：能力探测（极小 maxTokens）不透传 thinking', () {
    LlmRequest probe({int? maxTokens, Map<String, dynamic>? providerOptions}) =>
        LlmRequest(
          baseUrl: 'https://api.anthropic.com',
          apiKey: 'k',
          modelId: 'claude-sonnet-4-6',
          messages: const [
            {'role': 'user', 'content': 'Hi'},
          ],
          maxTokens: maxTokens,
          providerOptions: providerOptions,
        );

    test('maxTokens=1 + providerOptions.thinking → 不发 thinking', () {
      final body = AnthropicAdapter().buildRequestBody(
        probe(
          maxTokens: 1,
          providerOptions: {
            'thinking': {'type': 'enabled', 'budget_tokens': 2000},
          },
        ),
        stream: false,
      );
      expect(
        body.containsKey('thinking'),
        isFalse,
        reason: 'thinking 要求 max_tokens > budget_tokens ≥ 1024，'
            ' max_tokens=1 时任何 thinking 配置都必然 400，'
            ' 模型实测会误判「模型不可用」',
      );
    });

    test('maxTokens=1 + reasoningEffort 自动映射 → 同样不发 thinking', () {
      final body = AnthropicAdapter().buildRequestBody(
        const LlmRequest(
          baseUrl: 'https://api.anthropic.com',
          apiKey: 'k',
          modelId: 'claude-sonnet-4-6',
          messages: [
            {'role': 'user', 'content': 'Hi'},
          ],
          maxTokens: 1,
          reasoningEffort: ReasoningEffort.high,
        ),
        stream: false,
      );
      expect(body.containsKey('thinking'), isFalse);
    });

    test('正常 maxTokens 时 providerOptions.thinking 照常透传（不回退）', () {
      final body = AnthropicAdapter().buildRequestBody(
        probe(
          maxTokens: 4096,
          providerOptions: {
            'thinking': {'type': 'enabled', 'budget_tokens': 2000},
          },
        ),
        stream: false,
      );
      expect(body['thinking'], isNotNull);
    });
  });

  // 官方端点：reasoningEffort 映射为 adaptive + output_config.effort；
  // 不再发送已废弃的 enabled + budget_tokens。
  group('official adaptive thinking + effort', () {
    Map<String, dynamic> bodyOf({
      required int maxTokens,
      required ReasoningEffort effort,
    }) =>
        AnthropicAdapter().buildRequestBody(
          LlmRequest(
            baseUrl: 'https://api.anthropic.com',
            apiKey: 'k',
            modelId: 'claude-sonnet-4-6',
            messages: const [
              {'role': 'user', 'content': 'Hi'},
            ],
            maxTokens: maxTokens,
            reasoningEffort: effort,
          ),
          stream: false,
        );

    test('maxTokens=8192 + medium → adaptive + effort=medium', () {
      final body = bodyOf(maxTokens: 8192, effort: ReasoningEffort.medium);
      expect(body['thinking'], {'type': 'adaptive'});
      expect(body['output_config'], {'effort': 'medium'});
    });

    test('maxTokens=65536 + high → adaptive + effort=high', () {
      final body = bodyOf(maxTokens: 65536, effort: ReasoningEffort.high);
      expect(body['thinking'], {'type': 'adaptive'});
      expect(body['output_config'], {'effort': 'high'});
    });

    test('maxTokens=2048 + high → adaptive 不再需要预算钳制', () {
      final body = bodyOf(maxTokens: 2048, effort: ReasoningEffort.high);
      expect(body['thinking'], {'type': 'adaptive'});
    });

    test('maxTokens=1500 + low → 仍发 adaptive（>1024）', () {
      final body = bodyOf(maxTokens: 1500, effort: ReasoningEffort.low);
      expect(body['thinking'], {'type': 'adaptive'});
      expect(body['output_config'], {'effort': 'low'});
    });

    test('maxTokens=1024 → 极小预算探测不发 thinking', () {
      final body = bodyOf(maxTokens: 1024, effort: ReasoningEffort.high);
      expect(body.containsKey('thinking'), isFalse);
    });

    test('disabled → 官方发送 {type:disabled}', () {
      final body = bodyOf(maxTokens: 8192, effort: ReasoningEffort.disabled);
      expect(body['thinking'], {'type': 'disabled'});
      expect(body.containsKey('output_config'), isFalse);
    });
  });

  group('端点画像：tool_choice / headers / 默认值', () {
    LlmRequest request({
      String baseUrl = 'https://api.anthropic.com',
      ToolChoice? toolChoice,
      double? temperature,
      double? topP,
      ReasoningEffort? reasoningEffort,
      Map<String, dynamic>? providerOptions,
    }) =>
        LlmRequest(
          baseUrl: baseUrl,
          apiKey: 'k',
          modelId: 'claude-opus-5-5',
          messages: const [
            {'role': 'user', 'content': 'Hi'},
          ],
          tools: tools,
          toolChoice: toolChoice,
          temperature: temperature,
          topP: topP,
          maxTokens: 8192,
          reasoningEffort: reasoningEffort,
          providerOptions: providerOptions,
        );

    test('official none → {type:none}', () {
      final body = AnthropicAdapter().buildRequestBody(
        request(toolChoice: ToolChoice.none),
        stream: false,
      );
      expect(body['tool_choice'], {'type': 'none'});
    });

    test('third-party none 默认降级 auto，可声明支持', () {
      final fallback = AnthropicAdapter().buildRequestBody(
        request(
          baseUrl: 'https://relay.example.com',
          toolChoice: ToolChoice.none,
        ),
        stream: false,
      );
      expect(fallback['tool_choice'], {'type': 'auto'});

      final declared = AnthropicAdapter().buildRequestBody(
        request(
          baseUrl: 'https://relay.example.com',
          toolChoice: ToolChoice.none,
          providerOptions: const {
            kAnthropicCapabilitiesOption: {'tool_choice_none': true},
          },
        ),
        stream: false,
      );
      expect(declared['tool_choice'], {'type': 'none'});
    });

    test('required → any', () {
      final body = AnthropicAdapter().buildRequestBody(
        request(toolChoice: ToolChoice.required),
        stream: false,
      );
      expect(body['tool_choice'], {'type': 'any'});
    });

    test('extra_headers 合并，计算出的 version 优先', () {
      final headers = AnthropicAdapter().buildHeaders(
        request(
          providerOptions: const {
            'extra_headers': {
              'X-Custom': 'v',
              'Authorization': 'Bearer proxy',
              'anthropic-version': '2099-01-01',
            },
          },
        ),
      );
      expect(headers['X-Custom'], 'v');
      expect(headers['Authorization'], 'Bearer proxy');
      expect(headers['anthropic-version'], '2026-10-21');
    });

    test('third-party 默认 2023-06-01', () {
      final headers = AnthropicAdapter().buildHeaders(
        request(baseUrl: 'https://relay.example.com'),
      );
      expect(headers['anthropic-version'], '2023-06-01');
    });

    test('third-party 默认省略采样与 thinking，显式开启后生效', () {
      final defaults = AnthropicAdapter().buildRequestBody(
        request(
          baseUrl: 'https://relay.example.com',
          temperature: 0.7,
          topP: 1,
          reasoningEffort: ReasoningEffort.high,
        ),
        stream: false,
      );
      expect(defaults.containsKey('temperature'), isFalse);
      expect(defaults.containsKey('top_p'), isFalse);
      expect(defaults.containsKey('thinking'), isFalse);
      expect(defaults.containsKey('output_config'), isFalse);

      final optedIn = AnthropicAdapter().buildRequestBody(
        request(
          baseUrl: 'https://relay.example.com',
          temperature: 0.7,
          topP: 1,
          reasoningEffort: ReasoningEffort.high,
          providerOptions: const {
            kAnthropicSendSamplingOption: true,
            kAnthropicThinkingModeOption: 'adaptive',
          },
        ),
        stream: false,
      );
      expect(optedIn['temperature'], 0.7);
      expect(optedIn['top_p'], 1.0);
      expect(optedIn['thinking'], {'type': 'adaptive'});
      expect(optedIn['output_config'], {'effort': 'high'});
    });

    test('有序 anthropicBlocks 原样保序并包含 redacted_thinking', () {
      final body = AnthropicAdapter().buildRequestBody(
        const LlmRequest(
          baseUrl: 'https://api.anthropic.com',
          apiKey: 'k',
          modelId: 'claude-opus-5-5',
          messages: [
            {'role': 'user', 'content': 'Hi'},
            {
              'role': 'assistant',
              'content': 'parallel-text',
              'thinkingBlocks': [
                {'thinking': 'legacy', 'signature': 'legacy-sig'},
              ],
              'tool_calls': [
                {
                  'id': 'legacy-call',
                  'type': 'function',
                  'function': {'name': 'legacy', 'arguments': '{}'},
                },
              ],
              'anthropicBlocks': [
                {
                  'type': 'thinking',
                  'thinking': 't1',
                  'signature': 's1',
                },
                {'type': 'text', 'text': 'text-1'},
                {'type': 'redacted_thinking', 'data': 'redacted-1'},
                {
                  'type': 'tool_use',
                  'id': 'call_1',
                  'name': 'search',
                  'input': {'q': 'x'},
                },
              ],
            },
          ],
          tools: tools,
          toolChoice: ToolChoice.auto,
          maxTokens: 4096,
        ),
        stream: false,
      );

      final assistant =
          (body['messages'] as List).cast<Map<String, dynamic>>()[1];
      final blocks =
          (assistant['content'] as List).cast<Map<String, dynamic>>();
      expect(
        blocks.map((b) => b['type']).toList(),
        ['thinking', 'text', 'redacted_thinking', 'tool_use'],
      );
      expect(blocks[0]['signature'], 's1');
      expect(blocks[2]['data'], 'redacted-1');
    });

    test('非流式 parseResponse 保留 redacted_thinking 顺序', () {
      final response = AnthropicAdapter().parseResponse({
        'content': [
          {'type': 'thinking', 'thinking': 't', 'signature': 's'},
          {'type': 'redacted_thinking', 'data': 'd'},
          {'type': 'text', 'text': 'hi'},
        ],
        'stop_reason': 'end_turn',
        'usage': {'input_tokens': 1, 'output_tokens': 2},
      });

      expect(
        response.contentBlocks?.map((b) => b.toAnthropicJson()['type']),
        ['thinking', 'redacted_thinking', 'text'],
      );
    });

    test('不支持的图片 MIME 被丢弃，image/jpg 归一为 jpeg', () {
      final bmp = AnthropicAdapter().buildRequestBody(
        const LlmRequest(
          baseUrl: 'https://api.anthropic.com',
          apiKey: 'k',
          modelId: 'claude-opus-5-5',
          messages: [
            {
              'role': 'user',
              'content': [
                {
                  'type': 'image_url',
                  'image_url': {'url': 'data:image/bmp;base64,AAA'},
                },
              ],
            },
          ],
          maxTokens: 1024,
        ),
        stream: false,
      );
      final bmpContent = (bmp['messages'] as List)
          .cast<Map<String, dynamic>>()
          .first['content'] as List<dynamic>;
      expect(bmpContent, isEmpty);

      final jpg = AnthropicAdapter().buildRequestBody(
        const LlmRequest(
          baseUrl: 'https://api.anthropic.com',
          apiKey: 'k',
          modelId: 'claude-opus-5-5',
          messages: [
            {
              'role': 'user',
              'content': [
                {
                  'type': 'image_url',
                  'image_url': {'url': 'data:image/jpg;base64,AAA'},
                },
              ],
            },
          ],
          maxTokens: 1024,
        ),
        stream: false,
      );
      final jpgContent = (jpg['messages'] as List)
          .cast<Map<String, dynamic>>()
          .first['content'] as List<dynamic>;
      expect(
        (jpgContent.single as Map<String, dynamic>)['source'],
        containsPair('media_type', 'image/jpeg'),
      );
    });
  });
}
