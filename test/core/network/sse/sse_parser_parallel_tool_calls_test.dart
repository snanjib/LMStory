import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/network/sse/sse_parser.dart';

/// v0.3  fixture 回归：官方端点 + 中转站变体的多工具流式 tool_calls
///
/// 覆盖设计报告 §4.3 容错矩阵：
/// - OpenAI 官方：并行 tool_calls 按 index 分片交错
/// - 中转站 A（vLLM 系）：续片缺 index、无 finish_reason、无 `[DONE]`
/// - 中转站 B（SGLang/NIM 系）：finish_reason=stop 先于工具标记到达 +
///   参数 JSON 截断 + 流中 error chunk
void main() {
  group('官方端点回归', () {
    test('OpenAI 官方：两个工具并行，index 分片交错', () async {
      final parser = SseParser();
      final chunks = [
        // 首片：两个工具同时带 id/name
        'data: {"choices":[{"delta":{"role":"assistant","content":null,"tool_calls":[{"index":0,"id":"call_a","type":"function","function":{"name":"search_story","arguments":""}},{"index":1,"id":"call_b","type":"function","function":{"name":"query_facts","arguments":""}}]},"finish_reason":null}]}\n\n',
        // 参数分片交错（仅 index + arguments，缺 id/name 是规范不是 bug）
        'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"query\\":\\"古"}}]},"finish_reason":null}]}\n\n',
        'data: {"choices":[{"delta":{"tool_calls":[{"index":1,"function":{"arguments":"{\\"name\\":\\"苏"}}]},"finish_reason":null}]}\n\n',
        'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"碑\\"}"}}]},"finish_reason":null}]}\n\n',
        'data: {"choices":[{"delta":{"tool_calls":[{"index":1,"function":{"arguments":"明远\\"}"}}]},"finish_reason":null}]}\n\n',
        'data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}\n\n',
        'data: [DONE]\n\n',
      ];

      final events = await parser.parse(Stream.fromIterable(chunks)).toList();

      final starts = events.whereType<ToolCallStart>().toList();
      expect(starts, hasLength(2));
      expect(starts[0].toolCallId, 'call_a');
      expect(starts[0].toolName, 'search_story');
      expect(starts[1].toolCallId, 'call_b');
      expect(starts[1].toolName, 'query_facts');

      final completes = events.whereType<ToolCallComplete>().toList();
      expect(completes, hasLength(2));
      expect(completes[0].toolCallId, 'call_a');
      expect(completes[0].arguments, '{"query":"古碑"}');
      expect(completes[1].toolCallId, 'call_b');
      expect(completes[1].arguments, '{"name":"苏明远"}');

      expect(events.whereType<StreamEnd>(), hasLength(1));
    });

    test('OpenAI 官方：文本 + 工具调用并存（interleaved 合法形态）', () async {
      final parser = SseParser();
      final chunks = [
        'data: {"choices":[{"delta":{"content":"我先查一下。"},"finish_reason":null}]}\n\n',
        'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_c","type":"function","function":{"name":"echo","arguments":"{\\"text\\":\\"hi\\"}"}}]},"finish_reason":null}]}\n\n',
        'data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}\n\n',
        'data: [DONE]\n\n',
      ];

      final events = await parser.parse(Stream.fromIterable(chunks)).toList();

      // 文本照常发出，不再因"tool call 进行中"报错
      expect(events.whereType<TextDelta>(), hasLength(1));
      expect(events.whereType<ToolCallComplete>(), hasLength(1));
      // 不应有 UNEXPECTED_CONTENT 错误
      expect(events.whereType<StreamError>(), isEmpty);
    });
  });

  group('中转站变体回归', () {
    test('中转站 A（vLLM 系）：缺 index 续片 + 无 finish_reason + 无 [DONE]', () async {
      final parser = SseParser();
      final chunks = [
        'data: {"choices":[{"delta":{"tool_calls":[{"id":"call_v","function":{"name":"search_story","arguments":"{\\"query\\":"}}]},"finish_reason":null}]}\n\n',
        // 续片缺 index（vLLM 变体）→ 顺序假设
        'data: {"choices":[{"delta":{"tool_calls":[{"function":{"arguments":"\\"风暴\\"}"}}]},"finish_reason":null}]}\n\n',
        // 流直接关闭：无 finish_reason、无 [DONE]
      ];

      final events = await parser.parse(Stream.fromIterable(chunks)).toList();

      final completes = events.whereType<ToolCallComplete>().toList();
      expect(completes, hasLength(1));
      expect(completes.first.toolCallId, 'call_v');
      expect(completes.first.arguments, '{"query":"风暴"}');
      // 流自然结束兜底 StreamEnd
      expect(events.whereType<StreamEnd>(), hasLength(1));
    });

    test('中转站 A 变体：一次性吐完整 arguments + 无 id', () async {
      final parser = SseParser();
      final chunks = [
        'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"echo","arguments":"{\\"text\\":\\"one-shot\\"}"}}]},"finish_reason":null}]}\n\n',
        'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\n',
      ];

      final events = await parser.parse(Stream.fromIterable(chunks)).toList();

      // stop 先于工具标记到达：不再丢弃，完成累积中的调用
      final completes = events.whereType<ToolCallComplete>().toList();
      expect(completes, hasLength(1));
      expect(completes.first.toolName, 'echo');
      expect(completes.first.arguments, '{"text":"one-shot"}');
    });

    test('中转站 B（SGLang/NIM 系）：参数 JSON 截断 + 修复', () async {
      final parser = SseParser();
      final chunks = [
        'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_s","type":"function","function":{"name":"update_facts","arguments":"{\\"value\\":\\"苏"}}]},"finish_reason":null}]}\n\n',
        'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"明远审查了古"}}]},"finish_reason":null}]}\n\n',
        // 流中断：JSON 截断在字符串中间
      ];

      final events = await parser.parse(Stream.fromIterable(chunks)).toList();

      final completes = events.whereType<ToolCallComplete>().toList();
      expect(completes, hasLength(1));
      // 修复后应包含已收内容（补闭合引号与括号）
      expect(completes.first.arguments, contains('苏明远审查了古'));
    });

    test('中转站 B：流中 error chunk 透传为 StreamError', () async {
      final parser = SseParser();
      final chunks = [
        'data: {"choices":[{"delta":{"content":"Hi"},"finish_reason":null}]}\n\n',
        'data: {"error":{"message":"rate limit exceeded","code":429}}\n\n',
      ];

      final events = await parser.parse(Stream.fromIterable(chunks)).toList();

      final errors = events.whereType<StreamError>().toList();
      expect(errors, hasLength(1));
      expect(errors.first.message, 'rate limit exceeded');
      expect(errors.first.code, '429');
    });
  });
}
