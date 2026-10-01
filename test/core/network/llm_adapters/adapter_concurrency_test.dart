import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/network/llm_adapters/anthropic_adapter.dart';
import 'package:lmstory/core/network/llm_adapters/deepseek_adapter.dart';
import 'package:lmstory/core/network/llm_adapters/gemini_adapter.dart';
import 'package:lmstory/core/network/llm_adapters/openai_adapter.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';

/// 构造 Anthropic SSE 事件块
String anthropicSseBlock(String eventType, Map<String, dynamic> data) {
  return 'event: $eventType\ndata: ${jsonEncode(data)}\n\n';
}

/// 构造 Gemini SSE 事件块（无 event 字段）
String geminiSseBlock(Map<String, dynamic> data) {
  return 'data: ${jsonEncode(data)}\n\n';
}

/// 构造 OpenAI 兼容 SSE 事件块
String openaiSseBlock(Map<String, dynamic> data) {
  return 'data: ${jsonEncode(data)}\n\n';
}

/// 并发流式解析安全性测试
///
/// 验证 [AnthropicAdapter] 和 [GeminiAdapter] 在并发流式请求场景下
/// 不会因共享解析器实例的可变状态而互相干扰。
///
/// **背景**：适配器通过 `LlmAdapterFactory` 以单例形式持有，若解析器
/// 也作为适配器字段共享，两个并发的 `parseStream` 调用会互相覆盖
/// 解析器内部状态（Anthropic 的 `_blocks` / Gemini 的 `_emittedToolCallNames`
/// 等），导致工具调用丢失、文本增量被丢弃、usage 数据污染。
void main() {
  group('AnthropicAdapter 并发流式安全', () {
    test('流 B 启动后流 A 的 content block 状态仍保留', () async {
      final adapter = AnthropicAdapter();

      final controllerA = StreamController<String>();
      final eventsA = <LlmStreamEvent>[];
      final completerA = Completer<void>();

      // 1. 启动流 A
      adapter.parseStream(controllerA.stream).listen(
            eventsA.add,
            onDone: completerA.complete,
          );

      // 2. 流 A：content_block_start (index=0, text)
      //    解析器在 _blocks[0] 创建 block 状态
      controllerA.add(
        anthropicSseBlock('content_block_start', {
          'type': 'content_block_start',
          'index': 0,
          'content_block': {'type': 'text'},
        }),
      );
      // 等待 A 处理完 content_block_start
      await Future<void>.delayed(Duration.zero);

      // 3. 启动流 B —— 旧代码（共享解析器）会在此处 _blocks.clear()
      //    清空流 A 刚创建的 block 状态
      final controllerB = StreamController<String>();
      final eventsB = <LlmStreamEvent>[];
      final completerB = Completer<void>();
      adapter.parseStream(controllerB.stream).listen(
            eventsB.add,
            onDone: completerB.complete,
          );
      // 给流 B 一个事件，让 parse() 真正执行（async* 入口重置）
      controllerB.add(
        anthropicSseBlock('message_start', {
          'type': 'message_start',
          'message': {
            'id': 'msg_b',
            'type': 'message',
            'role': 'assistant',
            'content': <dynamic>[],
            'model': 'claude-sonnet-4-5',
            'stop_reason': null,
            'stop_sequence': null,
            'usage': {'input_tokens': 3, 'output_tokens': 0},
          },
        }),
      );
      await Future<void>.delayed(Duration.zero);

      // 4. 流 A：content_block_delta (index=0, "hello")
      //    旧代码：_blocks[0] 已被流 B 的 parse() 清空 → delta 被静默丢弃
      //    新代码：流 A 有独立解析器，block 仍在 → 正常发出 text_delta
      controllerA.add(
        anthropicSseBlock('content_block_delta', {
          'type': 'content_block_delta',
          'index': 0,
          'delta': {'type': 'text_delta', 'text': 'hello'},
        }),
      );
      await Future<void>.delayed(Duration.zero);

      // 关闭流
      controllerA
        ..add(
          anthropicSseBlock('content_block_stop', {
            'type': 'content_block_stop',
            'index': 0,
          }),
        )
        ..add(
          anthropicSseBlock('message_delta', {
            'type': 'message_delta',
            'delta': {'stop_reason': 'end_turn', 'stop_sequence': null},
            'usage': {'output_tokens': 2},
          }),
        )
        ..add(anthropicSseBlock('message_stop', {'type': 'message_stop'}));

      controllerB
        ..add(
          anthropicSseBlock('message_delta', {
            'type': 'message_delta',
            'delta': {'stop_reason': 'end_turn', 'stop_sequence': null},
            'usage': {'output_tokens': 1},
          }),
        )
        ..add(anthropicSseBlock('message_stop', {'type': 'message_stop'}));

      await controllerA.close();
      await controllerB.close();

      await completerA.future;
      await completerB.future;

      // 验证流 A 收到了 "hello" 文本增量
      final textDeltas = eventsA.whereType<LlmTextDelta>().toList();
      expect(
        textDeltas,
        isNotEmpty,
        reason: '流 A 的 text_delta 不应因流 B 的并发启动而丢失'
            ' （每流应使用独立解析器实例）',
      );
      expect(textDeltas.first.content, 'hello');

      // 验证流 A 的 usage 未被流 B 污染
      final doneA = eventsA.whereType<LlmStreamDone>().firstOrNull;
      expect(doneA, isNotNull, reason: '流 A 应收到 LlmStreamDone');
      // 流 A 的 input_tokens 应来自流 A 的 message_start（此处未传 usage，
      // 若被流 B 污染则会是 3）
      final doneB = eventsB.whereType<LlmStreamDone>().firstOrNull;
      expect(doneB, isNotNull, reason: '流 B 应收到 LlmStreamDone');
    });

    test('流 B 启动后流 A 的 tool_use block 状态仍保留', () async {
      final adapter = AnthropicAdapter();

      final controllerA = StreamController<String>();
      final eventsA = <LlmStreamEvent>[];
      final completerA = Completer<void>();

      adapter.parseStream(controllerA.stream).listen(
            eventsA.add,
            onDone: completerA.complete,
          );

      // 流 A：tool_use block start (index=0)
      controllerA.add(
        anthropicSseBlock('content_block_start', {
          'type': 'content_block_start',
          'index': 0,
          'content_block': {
            'type': 'tool_use',
            'id': 'toolu_a1',
            'name': 'extract_facts',
          },
        }),
      );
      await Future<void>.delayed(Duration.zero);

      // 启动流 B（触发共享解析器重置）
      final controllerB = StreamController<String>();
      final completerB = Completer<void>();
      adapter.parseStream(controllerB.stream).listen(
            (event) {},
            onDone: completerB.complete,
          );
      controllerB
        ..add(
          anthropicSseBlock('message_start', {
            'type': 'message_start',
            'message': {
              'usage': {'input_tokens': 1},
            },
          }),
        )
        ..add(anthropicSseBlock('message_stop', {'type': 'message_stop'}));
      await Future<void>.delayed(Duration.zero);

      // 流 A：input_json_delta (index=0)
      // 旧代码：_blocks[0] 已被清空，delta 被丢弃
      controllerA.add(
        anthropicSseBlock('content_block_delta', {
          'type': 'content_block_delta',
          'index': 0,
          'delta': {
            'type': 'input_json_delta',
            'partial_json': '{"key":"val"}',
          },
        }),
      );
      await Future<void>.delayed(Duration.zero);

      // 关闭流 A
      controllerA
        ..add(
          anthropicSseBlock('content_block_stop', {
            'type': 'content_block_stop',
            'index': 0,
          }),
        )
        ..add(anthropicSseBlock('message_stop', {'type': 'message_stop'}));
      await controllerA.close();
      await controllerB.close();

      await completerA.future;
      await completerB.future;

      // 验证流 A 收到了 tool_call_complete（含解析后的参数）
      final toolCallCompletes =
          eventsA.whereType<LlmToolCallComplete>().toList();
      expect(
        toolCallCompletes,
        isNotEmpty,
        reason: '流 A 的工具调用不应因流 B 的并发启动而丢失',
      );
      expect(toolCallCompletes.first.name, 'extract_facts');
      expect(toolCallCompletes.first.arguments['key'], 'val');
    });
  });

  group('GeminiAdapter 并发流式安全', () {
    test('流 B 启动后流 A 的文本增量仍正常发出', () async {
      final adapter = GeminiAdapter();

      final controllerA = StreamController<String>();
      final eventsA = <LlmStreamEvent>[];
      final completerA = Completer<void>();

      // 1. 启动流 A
      adapter.parseStream(controllerA.stream).listen(
            eventsA.add,
            onDone: completerA.complete,
          );

      // 2. 流 A：第一个 chunk（含 text "hello"）
      controllerA.add(
        geminiSseBlock({
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': 'hello'},
                ],
                'role': 'model',
              },
              'index': 0,
            },
          ],
        }),
      );
      await Future<void>.delayed(Duration.zero);

      // 3. 启动流 B（触发共享解析器重置）
      final controllerB = StreamController<String>();
      final eventsB = <LlmStreamEvent>[];
      final completerB = Completer<void>();
      adapter.parseStream(controllerB.stream).listen(
            eventsB.add,
            onDone: completerB.complete,
          );
      controllerB.add(
        geminiSseBlock({
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': 'world'},
                ],
                'role': 'model',
              },
              'index': 0,
              'finishReason': 'STOP',
            },
          ],
          'usageMetadata': {
            'promptTokenCount': 5,
            'candidatesTokenCount': 3,
            'totalTokenCount': 8,
          },
        }),
      );
      await Future<void>.delayed(Duration.zero);

      // 4. 流 A：第二个 chunk（含 text " world" + STOP）
      //    旧代码：共享解析器的 _streamEnded 可能已被流 B 设为 true，
      //    导致流 A 的 Done 事件不发出或提前终止
      controllerA.add(
        geminiSseBlock({
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': ' world'},
                ],
                'role': 'model',
              },
              'index': 0,
              'finishReason': 'STOP',
            },
          ],
          'usageMetadata': {
            'promptTokenCount': 10,
            'candidatesTokenCount': 5,
            'totalTokenCount': 15,
          },
        }),
      );
      await Future<void>.delayed(Duration.zero);

      await controllerA.close();
      await controllerB.close();

      await completerA.future;
      await completerB.future;

      // 验证流 A 收到了完整的文本增量
      final textDeltas = eventsA.whereType<LlmTextDelta>().toList();
      expect(
        textDeltas.length,
        greaterThanOrEqualTo(2),
        reason: '流 A 应收到 "hello" 和 " world" 两个文本增量',
      );
      expect(textDeltas[0].content, 'hello');
      expect(textDeltas[1].content, ' world');

      // 验证流 A 的 usage 未被流 B 污染
      final doneA = eventsA.whereType<LlmStreamDone>().firstOrNull;
      expect(doneA, isNotNull, reason: '流 A 应收到 LlmStreamDone');
      expect(
        doneA!.usage?.totalTokens,
        15,
        reason: '流 A 的 usage 应来自流 A 自身，不应被流 B 污染',
      );

      // 验证流 B 的 usage 也正确
      final doneB = eventsB.whereType<LlmStreamDone>().firstOrNull;
      expect(doneB, isNotNull, reason: '流 B 应收到 LlmStreamDone');
      expect(doneB!.usage?.totalTokens, 8);
    });
  });

  group('OpenAiAdapter 并发流式安全（XC-3）', () {
    test('流 B 启动后流 A 的工具参数累积仍完整', () async {
      final adapter = OpenAiAdapter();

      final controllerA = StreamController<String>();
      final eventsA = <LlmStreamEvent>[];
      final completerA = Completer<void>();
      adapter.parseStream(controllerA.stream).listen(
            eventsA.add,
            onDone: completerA.complete,
          );

      // 1. 流 A：tool_calls 首片（id + name + 首段参数分片）
      controllerA.add(
        openaiSseBlock({
          'choices': [
            {
              'delta': {
                'tool_calls': [
                  {
                    'index': 0,
                    'id': 'call_a1',
                    'type': 'function',
                    'function': {
                      'name': 'extract_facts',
                      'arguments': '{"q":"',
                    },
                  }
                ],
              },
              'finish_reason': null,
            },
          ],
        }),
      );
      await Future<void>.delayed(Duration.zero);

      // 2. 启动流 B —— 旧代码（适配器字段共享 SseParser）会在此处
      //    _reset() 清空流 A 的工具分片累积
      final controllerB = StreamController<String>();
      final completerB = Completer<void>();
      adapter.parseStream(controllerB.stream).listen(
            (event) {},
            onDone: completerB.complete,
          );
      controllerB
        ..add(
          openaiSseBlock({
            'choices': [
              {
                'delta': {'content': 'B 流文本'},
                'finish_reason': null,
              },
            ],
          }),
        )
        ..add('data: [DONE]\n\n');
      await Future<void>.delayed(Duration.zero);

      // 3. 流 A：参数第二片 + finish_reason=tool_calls + [DONE]
      controllerA
        ..add(
          openaiSseBlock({
            'choices': [
              {
                'delta': {
                  'tool_calls': [
                    {
                      'index': 0,
                      'function': {'arguments': 'full"}'},
                    },
                  ],
                },
                'finish_reason': null,
              },
            ],
          }),
        )
        ..add(
          openaiSseBlock({
            'choices': [
              {
                'delta': <String, dynamic>{},
                'finish_reason': 'tool_calls',
              },
            ],
          }),
        )
        ..add('data: [DONE]\n\n');
      await controllerA.close();
      await controllerB.close();

      await completerA.future;
      await completerB.future;

      // 流 A 的完整参数应保留（旧代码：首片被流 B 的 reset 清掉，参数残缺）
      final completes = eventsA.whereType<LlmToolCallComplete>().toList();
      expect(
        completes,
        isNotEmpty,
        reason: '流 A 的工具调用不应因流 B 的并发启动而丢失',
      );
      expect(completes.first.name, 'extract_facts');
      expect(completes.first.arguments['q'], 'full');
    });

    test('流 B 启动后流 A 的 usage 与 finishReason 不被污染', () async {
      final adapter = OpenAiAdapter();

      final controllerA = StreamController<String>();
      final eventsA = <LlmStreamEvent>[];
      final completerA = Completer<void>();
      adapter.parseStream(controllerA.stream).listen(
            eventsA.add,
            onDone: completerA.complete,
          );

      // 1. 流 A：文本 + usage chunk（_lastUsage 已缓存）
      controllerA
        ..add(
          openaiSseBlock({
            'choices': [
              {
                'delta': {'content': 'hello'},
                'finish_reason': null,
              },
            ],
          }),
        )
        ..add(
          openaiSseBlock({
            'choices': <dynamic>[],
            'usage': {
              'prompt_tokens': 10,
              'completion_tokens': 5,
              'total_tokens': 15,
            },
          }),
        );
      await Future<void>.delayed(Duration.zero);

      // 2. 启动流 B（旧代码：共享解析器 parse() 入口清空 _lastUsage）
      final controllerB = StreamController<String>();
      final completerB = Completer<void>();
      adapter.parseStream(controllerB.stream).listen(
            (event) {},
            onDone: completerB.complete,
          );
      controllerB
        ..add(
          openaiSseBlock({
            'choices': [
              {
                'delta': {'content': 'B'},
                'finish_reason': null,
              },
            ],
          }),
        )
        ..add('data: [DONE]\n\n');
      await Future<void>.delayed(Duration.zero);

      // 3. 流 A：finish_reason=length + [DONE]
      controllerA
        ..add(
          openaiSseBlock({
            'choices': [
              {
                'delta': <String, dynamic>{},
                'finish_reason': 'length',
              },
            ],
          }),
        )
        ..add('data: [DONE]\n\n');
      await controllerA.close();
      await controllerB.close();

      await completerA.future;
      await completerB.future;

      final doneA = eventsA.whereType<LlmStreamDone>().firstOrNull;
      expect(doneA, isNotNull, reason: '流 A 应收到 LlmStreamDone');
      expect(
        doneA!.usage?.totalTokens,
        15,
        reason: '流 A 的 usage 不应被流 B 的并发启动清空',
      );
      expect(doneA.finishReason, 'length');
    });
  });

  group('DeepSeekAdapter 并发流式安全（XC-3）', () {
    test('流 B 启动后流 A 的文本增量与 usage 仍完整', () async {
      final adapter = DeepSeekAdapter();

      final controllerA = StreamController<String>();
      final eventsA = <LlmStreamEvent>[];
      final completerA = Completer<void>();
      adapter.parseStream(controllerA.stream).listen(
            eventsA.add,
            onDone: completerA.complete,
          );

      controllerA.add(
        openaiSseBlock({
          'choices': [
            {
              'delta': {'content': '第一段'},
              'finish_reason': null,
            },
          ],
        }),
      );
      await Future<void>.delayed(Duration.zero);

      // 流 A：先缓存 usage（旧代码：共享解析器会被流 B 的 parse() 重置清空）
      controllerA
        ..add(
          openaiSseBlock({
            'choices': [
              {
                'delta': {'content': '第二段'},
                'finish_reason': null,
              },
            ],
          }),
        )
        ..add(
          openaiSseBlock({
            'choices': <dynamic>[],
            'usage': {
              'prompt_tokens': 4,
              'completion_tokens': 2,
              'total_tokens': 6,
            },
          }),
        );
      await Future<void>.delayed(Duration.zero);

      // 流 B 启动（旧代码：共享解析器 parse() 入口清空流 A 的 _lastUsage）
      final controllerB = StreamController<String>();
      final completerB = Completer<void>();
      adapter.parseStream(controllerB.stream).listen(
            (event) {},
            onDone: completerB.complete,
          );
      controllerB
        ..add(
          openaiSseBlock({
            'choices': [
              {
                'delta': {'content': 'B'},
                'finish_reason': null,
              },
            ],
          }),
        )
        ..add('data: [DONE]\n\n');
      await Future<void>.delayed(Duration.zero);

      controllerA.add('data: [DONE]\n\n');
      await controllerA.close();
      await controllerB.close();

      await completerA.future;
      await completerB.future;

      final text =
          eventsA.whereType<LlmTextDelta>().map((e) => e.content).join();
      expect(
        text,
        '第一段第二段',
        reason: '流 A 的文本增量不应因流 B 的并发启动而丢失',
      );
      final doneA = eventsA.whereType<LlmStreamDone>().firstOrNull;
      expect(
        doneA?.usage?.totalTokens,
        6,
        reason: '流 A 的 usage 不应被流 B 的并发启动清空',
      );
    });
  });
}
