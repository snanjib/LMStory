import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/llm/tool_calling/tool_choice.dart';
import 'package:lmstory/core/llm/tool_calling/tool_definition.dart';
import 'package:lmstory/core/network/llm_adapters/anthropic_adapter.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';

/// v0.3 ：Anthropic 显式缓存断点 + 缓存命中计量测试
void main() {
  const tools = [
    ToolDefinition(
      name: 'search_story',
      description: 'search',
      parameters: {'type': 'object'},
    ),
  ];

  LlmRequest request({required bool withTools}) {
    return LlmRequest(
      baseUrl: 'https://api.anthropic.com',
      apiKey: 'k',
      modelId: 'claude-sonnet-4-6',
      messages: [
        {'role': 'system', 'content': 'SYSTEM-FROZEN'},
        {'role': 'user', 'content': '第一轮'},
        {'role': 'assistant', 'content': '回复'},
        {'role': 'user', 'content': '第二轮'},
      ],
      tools: withTools ? tools : null,
      toolChoice: withTools ? ToolChoice.auto : null,
    );
  }

  test('带工具的请求：system 块与倒数第二条消息打 cache_control 断点', () {
    final body = AnthropicAdapter()
        .buildRequestBody(request(withTools: true), stream: true);

    // system → block 数组，末块带 cache_control
    final system = body['system'] as List;
    expect(system, hasLength(1));
    expect((system.first as Map)['cache_control'], {'type': 'ephemeral'});

    // 倒数第二条消息（assistant '回复'）的 content 末块带断点
    final messages = body['messages'] as List;
    final target = messages[messages.length - 2] as Map;
    final content = target['content'] as List;
    expect((content.last as Map)['cache_control'], {'type': 'ephemeral'});
    // 最后一条消息不打（新内容）
    final last = messages.last as Map;
    expect(jsonEncode(last), isNot(contains('cache_control')));
  });

  test('D8：无工具的请求（普通对话）也打消息区断点（system 保持字符串）', () {
    final body = AnthropicAdapter()
        .buildRequestBody(request(withTools: false), stream: true);
    expect(body['system'], 'SYSTEM-FROZEN');
    //  落地：chat 模式此前完全零断点（跨轮缓存全无）——现消息区
    // 断点开放，锚定上一轮结束边界（倒数第二）；system 保持 join 串
    //（断点前缀已覆盖 system，最小 wire 变化）
    expect(jsonEncode(body), contains('cache_control'));
  });

  test('D8：无工具多轮请求断点恰 1 个且位于倒数第二条消息', () {
    final body = AnthropicAdapter().buildRequestBody(
      const LlmRequest(
        baseUrl: 'https://api.anthropic.com',
        apiKey: 'k',
        modelId: 'claude-sonnet-4-6',
        messages: [
          {'role': 'system', 'content': 'PREFIX'},
          {'role': 'user', 'content': '第一轮输入'},
          {'role': 'assistant', 'content': '第一轮回复'},
          {'role': 'user', 'content': '第二轮输入'},
        ],
      ),
      stream: true,
    );
    expect(body['system'], 'PREFIX');
    final messages = body['messages'] as List;
    expect(messages, hasLength(3));
    // 断点在倒数第二（上轮 assistant 边界），最后一条（本轮输入）无断点
    final secondLast = jsonEncode(messages[1]);
    final last = jsonEncode(messages[2]);
    expect(secondLast, contains('cache_control'));
    expect(last, isNot(contains('cache_control')));
    expect(
      jsonEncode(body).split('cache_control').length - 1,
      1,
      reason: 'D8 预算守卫：无工具请求断点恰 1 个',
    );
  });

  test('D8：带工具+3 system 块+多消息的断点总数锁死 4（上限内不超发）', () {
    final body = AnthropicAdapter().buildRequestBody(
      const LlmRequest(
        baseUrl: 'https://api.anthropic.com',
        apiKey: 'k',
        modelId: 'claude-sonnet-4-6',
        tools: tools,
        messages: [
          {'role': 'system', 'content': 'PREFIX'},
          {'role': 'system', 'content': 'CORE'},
          {'role': 'system', 'content': 'TAIL'},
          {'role': 'user', 'content': '第一轮输入'},
          {'role': 'assistant', 'content': '第一轮回复'},
          {'role': 'user', 'content': '第二轮输入'},
        ],
      ),
      stream: true,
    );
    // 3 system 块逐块断点 + 消息区倒数第二断点 = 4（Anthropic 上限恰满）
    expect(
      jsonEncode(body).split('cache_control').length - 1,
      4,
      reason: '断点预算守卫：任何请求 ≤4，第 5 断点不得硬发',
    );
  });

  test('B1：字符串 user 消息作为断点目标，包成 text 块并打 cache_control', () {
    const req = LlmRequest(
      baseUrl: 'https://api.anthropic.com',
      apiKey: 'k',
      modelId: 'claude-sonnet-4-6',
      messages: [
        {'role': 'system', 'content': 'SYSTEM-FROZEN'},
        {'role': 'user', 'content': '第一轮'},
        {'role': 'assistant', 'content': '回复'},
        {'role': 'user', 'content': '第二轮输入'},
        {'role': 'user', 'content': '尾部提醒'},
      ],
      tools: tools,
      toolChoice: ToolChoice.auto,
    );
    final body = AnthropicAdapter().buildRequestBody(req, stream: true);

    // 断点目标 = 倒数第二条：String content 包成
    // 单个 text 块并打断点，不再被静默跳过
    final messages = (body['messages'] as List).cast<Map<String, dynamic>>();
    final target = messages[messages.length - 2];
    expect(target['role'], 'user');
    final content = (target['content'] as List).cast<Map<String, dynamic>>();
    expect(content, hasLength(1));
    expect(content.first['type'], 'text');
    expect(content.first['text'], '第二轮输入');
    expect(content.first['cache_control'], {'type': 'ephemeral'});
    // 最后一条（新内容）不打断点
    expect(jsonEncode(messages.last), isNot(contains('cache_control')));
    // 请求对象不被原地改写（重试重建请求体不受影响）；body 滤掉了
    // system，req.messages 索引 = body 索引 + 1
    expect(req.messages[messages.length - 1]['content'], '第二轮输入');
  });

  group('多 system 块分离（core blocks 变化不击穿冻结前缀缓存）', () {
    LlmRequest twoSystemRequest(String coreBlocks) {
      return LlmRequest(
        baseUrl: 'https://api.anthropic.com',
        apiKey: 'k',
        modelId: 'claude-sonnet-4-6',
        messages: [
          {'role': 'system', 'content': 'SYSTEM-FROZEN'},
          {'role': 'system', 'content': coreBlocks},
          {'role': 'user', 'content': '第一轮'},
        ],
        tools: tools,
        toolChoice: ToolChoice.auto,
      );
    }

    test('两条 system → 两个内容块保序，各自末尾带断点', () {
      final body = AnthropicAdapter()
          .buildRequestBody(twoSystemRequest('CORE-1'), stream: true);

      final system = (body['system'] as List).cast<Map<String, dynamic>>();
      expect(system, hasLength(2));
      expect(system[0]['text'], 'SYSTEM-FROZEN');
      expect(system[1]['text'], 'CORE-1');
      expect(system[0]['cache_control'], {'type': 'ephemeral'});
      expect(system[1]['cache_control'], {'type': 'ephemeral'});
    });

    test('修改第二条 system 后，第一条块字节不变（冻结前缀缓存可命中）', () {
      final before = AnthropicAdapter()
          .buildRequestBody(twoSystemRequest('CORE-1'), stream: true);
      final after = AnthropicAdapter()
          .buildRequestBody(twoSystemRequest('CORE-2-CHANGED'), stream: true);

      final beforeBlocks =
          (before['system'] as List).cast<Map<String, dynamic>>();
      final afterBlocks =
          (after['system'] as List).cast<Map<String, dynamic>>();
      expect(jsonEncode(beforeBlocks[0]), jsonEncode(afterBlocks[0]));
      expect(afterBlocks[1]['text'], 'CORE-2-CHANGED');
    });

    test('断点预算：4 条 system 只有首块与末块带断点（≤4 断点上限）', () {
      final body = AnthropicAdapter().buildRequestBody(
        LlmRequest(
          baseUrl: 'https://api.anthropic.com',
          apiKey: 'k',
          modelId: 'claude-sonnet-4-6',
          messages: [
            for (final text in ['S1', 'S2', 'S3', 'S4'])
              {'role': 'system', 'content': text},
            {'role': 'user', 'content': '第一轮'},
          ],
          tools: tools,
          toolChoice: ToolChoice.auto,
        ),
        stream: true,
      );

      final system = (body['system'] as List).cast<Map<String, dynamic>>();
      expect(system, hasLength(4));
      expect(system[0]['cache_control'], {'type': 'ephemeral'});
      expect(system[3]['cache_control'], {'type': 'ephemeral'});
      expect(system[1].containsKey('cache_control'), isFalse);
      expect(system[2].containsKey('cache_control'), isFalse);
      // 本请求仅 1 条非 system 消息（消息断点需 ≥2 条），故断点 = 首末
      // system 2 个；叠加消息断点后任何请求 ≤ 4
      expect(jsonEncode(body).split('cache_control').length - 1, 2);
    });

    test(r'无工具路径：两条 system 仍按 \n\n 合并为字符串（故事模式不变）', () {
      final body = AnthropicAdapter().buildRequestBody(
        const LlmRequest(
          baseUrl: 'https://api.anthropic.com',
          apiKey: 'k',
          modelId: 'claude-sonnet-4-6',
          messages: [
            {'role': 'system', 'content': 'PREFIX'},
            {'role': 'system', 'content': 'CORE'},
            {'role': 'user', 'content': '第一轮'},
          ],
        ),
        stream: true,
      );
      expect(body['system'], 'PREFIX\n\nCORE');
    });
  });

  test('非流式响应解析 cache_creation/cache_read usage', () {
    final response = AnthropicAdapter().parseResponse({
      'content': [
        {'type': 'text', 'text': 'hi'},
      ],
      'usage': {
        'input_tokens': 100,
        'output_tokens': 20,
        'cache_read_input_tokens': 80,
        'cache_creation_input_tokens': 20,
      },
    });
    expect(response.usage?.cacheReadTokens, 80);
    expect(response.usage?.cacheCreationTokens, 20);
  });
}
