import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/llm/tool_calling/tool_choice.dart';
import 'package:lmstory/core/llm/tool_calling/tool_definition.dart';
import 'package:lmstory/core/network/llm_adapters/anthropic_adapter.dart';
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

  group('CF-1：user 消息 image_url 转 Anthropic image block', () {
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

  group('XC-2：非流式 parseResponse 上抛 finishReason', () {
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

  // 自动映射的 budget 必须钳到
  // max_tokens-1024——medium=10000/high=32000 在常见 maxTokens（如 8192）
  // 下越界必 400；钳后低于硬下限 1024 则放弃 thinking。
  group('CF12-1：thinking 预算钳制（budget < max_tokens）', () {
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

    test('maxTokens=8192 + medium → 预算钳到 7168（不是 10000）', () {
      final body = bodyOf(maxTokens: 8192, effort: ReasoningEffort.medium);
      expect((body['thinking'] as Map)['budget_tokens'], 7168);
    });

    test('maxTokens=65536 + high → 预算 32000 不受影响（远低于帽）', () {
      final body = bodyOf(maxTokens: 65536, effort: ReasoningEffort.high);
      expect((body['thinking'] as Map)['budget_tokens'], 32000);
    });

    test('maxTokens=2048 + high → 钳到 1024（硬下限）', () {
      final body = bodyOf(maxTokens: 2048, effort: ReasoningEffort.high);
      expect((body['thinking'] as Map)['budget_tokens'], 1024);
    });

    test('maxTokens=1500 + low → 钳后低于 1024 → 不发 thinking', () {
      final body = bodyOf(maxTokens: 1500, effort: ReasoningEffort.low);
      expect(
        body.containsKey('thinking'),
        isFalse,
        reason: 'maxTokens-1024=476 < 硬下限 1024，思考无处安放',
      );
    });
  });
}
