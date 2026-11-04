import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/llm/llm_content_block.dart';
import 'package:lmstory/core/network/sse/anthropic_sse_parser.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';

/// 构造 Anthropic SSE 事件块
String sseBlock(String eventType, Map<String, dynamic> data) {
  return 'event: $eventType\ndata: ${jsonEncode(data)}\n\n';
}

void main() {
  group('AnthropicSseParser', () {
    late AnthropicSseParser parser;

    setUp(() {
      parser = AnthropicSseParser();
    });

    test('块开始携带的完整思考和文本同时进入可见增量', () async {
      final events = await parser
          .parse(
            Stream.fromIterable([
              sseBlock('content_block_start', {
                'type': 'content_block_start',
                'index': 0,
                'content_block': {
                  'type': 'thinking',
                  'thinking': '先核对。',
                  'signature': 'sig',
                },
              }),
              sseBlock(
                'content_block_stop',
                {'type': 'content_block_stop', 'index': 0},
              ),
              sseBlock('content_block_start', {
                'type': 'content_block_start',
                'index': 1,
                'content_block': {'type': 'text', 'text': '现在查阅。'},
              }),
              sseBlock(
                'content_block_stop',
                {'type': 'content_block_stop', 'index': 1},
              ),
              sseBlock('message_stop', {'type': 'message_stop'}),
            ]),
          )
          .toList();
      expect(
        events.whereType<LlmThinkingDelta>().map((e) => e.content),
        ['先核对。'],
      );
      expect(events.whereType<LlmTextDelta>().map((e) => e.content), ['现在查阅。']);
      expect(
        events.whereType<LlmThinkingBlockComplete>().single.signature,
        'sig',
      );
    });

    test('解析完整文本流（text block + usage）', () async {
      final sseStream = Stream.fromIterable([
        sseBlock('message_start', {
          'type': 'message_start',
          'message': {
            'id': 'msg_1',
            'type': 'message',
            'role': 'assistant',
            'content': <dynamic>[],
            'model': 'claude-sonnet-4-5',
            'stop_reason': null,
            'stop_sequence': null,
            'usage': {'input_tokens': 10, 'output_tokens': 0},
          },
        }),
        sseBlock('content_block_start', {
          'type': 'content_block_start',
          'index': 0,
          'content_block': {'type': 'text', 'text': ''},
        }),
        sseBlock('content_block_delta', {
          'type': 'content_block_delta',
          'index': 0,
          'delta': {'type': 'text_delta', 'text': 'Hello'},
        }),
        sseBlock('content_block_delta', {
          'type': 'content_block_delta',
          'index': 0,
          'delta': {'type': 'text_delta', 'text': ' world'},
        }),
        sseBlock('content_block_stop', {
          'type': 'content_block_stop',
          'index': 0,
        }),
        sseBlock('message_delta', {
          'type': 'message_delta',
          'delta': {'stop_reason': 'end_turn', 'stop_sequence': null},
          'usage': {'output_tokens': 5},
        }),
        sseBlock('message_stop', {'type': 'message_stop'}),
      ]);

      final events = await parser.parse(sseStream).toList();

      // 事件序列：text_delta×2 + content_block_complete(text) + stream_done
      expect(events.length, 4);
      expect(events[0], isA<LlmTextDelta>());
      expect((events[0] as LlmTextDelta).content, 'Hello');
      expect(events[1], isA<LlmTextDelta>());
      expect((events[1] as LlmTextDelta).content, ' world');
      expect(events[2], isA<LlmContentBlockComplete>());
      final textBlock = (events[2] as LlmContentBlockComplete).block;
      expect(textBlock, isA<LlmTextContentBlock>());
      expect((textBlock as LlmTextContentBlock).text, 'Hello world');
      expect(events[3], isA<LlmStreamDone>());
      // 验证 usage（input_tokens=10 from message_start, output_tokens=5 from message_delta）
      final done = events[3] as LlmStreamDone;
      expect(done.usage?.promptTokens, 10);
      expect(done.usage?.completionTokens, 5);
      expect(done.usage?.totalTokens, 15);
    });

    test('解析 thinking block（含 signature 累积）', () async {
      final sseStream = Stream.fromIterable([
        sseBlock('content_block_start', {
          'type': 'content_block_start',
          'index': 0,
          'content_block': {'type': 'thinking', 'thinking': ''},
        }),
        sseBlock('content_block_delta', {
          'type': 'content_block_delta',
          'index': 0,
          'delta': {'type': 'thinking_delta', 'thinking': 'Hmm...'},
        }),
        sseBlock('content_block_delta', {
          'type': 'content_block_delta',
          'index': 0,
          'delta': {'type': 'signature_delta', 'signature': 'WaUjz'},
        }),
        sseBlock('content_block_delta', {
          'type': 'content_block_delta',
          'index': 0,
          'delta': {'type': 'signature_delta', 'signature': 'k9X='},
        }),
        sseBlock('content_block_stop', {
          'type': 'content_block_stop',
          'index': 0,
        }),
        sseBlock('message_stop', {'type': 'message_stop'}),
      ]);

      final events = await parser.parse(sseStream).toList();

      // thinking_delta + thinking_block_complete + content_block_complete
      // + stream_done
      expect(events.length, 4);
      expect(events[0], isA<LlmThinkingDelta>());
      expect((events[0] as LlmThinkingDelta).content, 'Hmm...');
      expect(events[1], isA<LlmThinkingBlockComplete>());
      final tbComplete = events[1] as LlmThinkingBlockComplete;
      expect(tbComplete.thinking, 'Hmm...');
      expect(tbComplete.signature, 'WaUjzk9X=');
      expect(events[2], isA<LlmContentBlockComplete>());
      final thinkingBlock = (events[2] as LlmContentBlockComplete).block;
      expect(thinkingBlock, isA<LlmThinkingContentBlock>());
      expect((thinkingBlock as LlmThinkingContentBlock).signature, 'WaUjzk9X=');
      expect(events[3], isA<LlmStreamDone>());
    });

    test('解析 tool_use block（input_json_delta 累积）', () async {
      final sseStream = Stream.fromIterable([
        sseBlock('content_block_start', {
          'type': 'content_block_start',
          'index': 0,
          'content_block': {
            'type': 'tool_use',
            'id': 'toolu_abc',
            'name': 'get_weather',
            'input': <String, dynamic>{},
          },
        }),
        sseBlock('content_block_delta', {
          'type': 'content_block_delta',
          'index': 0,
          'delta': {
            'type': 'input_json_delta',
            'partial_json': '{"location":',
          },
        }),
        sseBlock('content_block_delta', {
          'type': 'content_block_delta',
          'index': 0,
          'delta': {
            'type': 'input_json_delta',
            'partial_json': '"NYC"}',
          },
        }),
        sseBlock('content_block_stop', {
          'type': 'content_block_stop',
          'index': 0,
        }),
        sseBlock('message_stop', {'type': 'message_stop'}),
      ]);

      final events = await parser.parse(sseStream).toList();

      // 事件序列：
      // 1. tool_call_start (content_block_start 时发出)
      // 2. tool_call_args (第一个 delta)
      // 3. tool_call_args (第二个 delta)
      // 4. content_block_complete (tool_use 有序块)
      // 5. tool_call_complete (content_block_stop 时解析累积的 args)
      // 6. stream_done
      expect(events.length, 6);
      expect(events[0], isA<LlmToolCallStart>());
      expect((events[0] as LlmToolCallStart).toolCallId, 'toolu_abc');
      expect((events[0] as LlmToolCallStart).name, 'get_weather');
      expect(events[1], isA<LlmToolCallArgs>());
      expect(events[2], isA<LlmToolCallArgs>());
      expect(events[3], isA<LlmContentBlockComplete>());
      expect(events[4], isA<LlmToolCallComplete>());
      final tc = events[4] as LlmToolCallComplete;
      expect(tc.toolCallId, 'toolu_abc');
      expect(tc.name, 'get_weather');
      expect(tc.arguments['location'], 'NYC');
    });

    test('忽略未知事件类型（如 ping）', () async {
      final sseStream = Stream.fromIterable([
        sseBlock('ping', {'type': 'ping'}),
        sseBlock('message_stop', {'type': 'message_stop'}),
      ]);

      final events = await parser.parse(sseStream).toList();

      // 只应有 LlmStreamDone
      expect(events.length, 1);
      expect(events[0], isA<LlmStreamDone>());
    });

    test('流中场 block 未闭合 → StreamError 而非成功 Done', () async {
      final sseStream = Stream.fromIterable([
        sseBlock('content_block_start', {
          'type': 'content_block_start',
          'index': 0,
          'content_block': {'type': 'text', 'text': ''},
        }),
        sseBlock('content_block_delta', {
          'type': 'content_block_delta',
          'index': 0,
          'delta': {'type': 'text_delta', 'text': 'Hi'},
        }),
        // 流突然结束，无 content_block_stop / message_stop
      ]);

      final events = await parser.parse(sseStream).toList();

      expect(events.length, 2);
      expect(events[0], isA<LlmTextDelta>());
      expect(events[1], isA<LlmStreamError>());
      expect((events[1] as LlmStreamError).code, 'STREAM_ERROR');
    });

    test('block 全闭合但缺 message_stop → 保留 Done 兜底', () async {
      final sseStream = Stream.fromIterable([
        sseBlock('content_block_start', {
          'type': 'content_block_start',
          'index': 0,
          'content_block': {'type': 'text', 'text': ''},
        }),
        sseBlock('content_block_delta', {
          'type': 'content_block_delta',
          'index': 0,
          'delta': {'type': 'text_delta', 'text': 'Hi'},
        }),
        sseBlock('content_block_stop', {
          'type': 'content_block_stop',
          'index': 0,
        }),
        // 缺 message_stop
      ]);

      final events = await parser.parse(sseStream).toList();

      expect(events.length, 3);
      expect(events[0], isA<LlmTextDelta>());
      expect(events[1], isA<LlmContentBlockComplete>());
      expect(events[2], isA<LlmStreamDone>());
    });

    test('解析错误 JSON 时发出 LlmStreamError', () async {
      final sseStream = Stream.fromIterable([
        'event: content_block_delta\ndata: {invalid json}\n\n',
        sseBlock('message_stop', {'type': 'message_stop'}),
      ]);

      final events = await parser.parse(sseStream).toList();

      // 应有：stream_error + stream_done
      expect(events.length, 2);
      expect(events[0], isA<LlmStreamError>());
      expect(events[1], isA<LlmStreamDone>());
    });

    test('多 block 场景：thinking + text + tool_use 混合', () async {
      final sseStream = Stream.fromIterable([
        // thinking block (index=0)
        sseBlock('content_block_start', {
          'type': 'content_block_start',
          'index': 0,
          'content_block': {'type': 'thinking', 'thinking': ''},
        }),
        sseBlock('content_block_delta', {
          'type': 'content_block_delta',
          'index': 0,
          'delta': {'type': 'thinking_delta', 'thinking': 'Let me think'},
        }),
        sseBlock('content_block_delta', {
          'type': 'content_block_delta',
          'index': 0,
          'delta': {'type': 'signature_delta', 'signature': 'sig123'},
        }),
        sseBlock('content_block_stop', {
          'type': 'content_block_stop',
          'index': 0,
        }),
        // text block (index=1)
        sseBlock('content_block_start', {
          'type': 'content_block_start',
          'index': 1,
          'content_block': {'type': 'text', 'text': ''},
        }),
        sseBlock('content_block_delta', {
          'type': 'content_block_delta',
          'index': 1,
          'delta': {'type': 'text_delta', 'text': 'I will help'},
        }),
        sseBlock('content_block_stop', {
          'type': 'content_block_stop',
          'index': 1,
        }),
        // tool_use block (index=2)
        sseBlock('content_block_start', {
          'type': 'content_block_start',
          'index': 2,
          'content_block': {
            'type': 'tool_use',
            'id': 'toolu_1',
            'name': 'search',
            'input': <String, dynamic>{},
          },
        }),
        sseBlock('content_block_delta', {
          'type': 'content_block_delta',
          'index': 2,
          'delta': {
            'type': 'input_json_delta',
            'partial_json': '{"q":"test"}',
          },
        }),
        sseBlock('content_block_stop', {
          'type': 'content_block_stop',
          'index': 2,
        }),
        sseBlock('message_stop', {'type': 'message_stop'}),
      ]);

      final events = await parser.parse(sseStream).toList();

      // 事件序列（每个 block 在 stop 时补一条有序内容块事件）：
      // 1. thinking_delta
      // 2. thinking_block_complete
      // 3. content_block_complete(thinking)
      // 4. text_delta
      // 5. content_block_complete(text)
      // 6. tool_call_start
      // 7. tool_call_args
      // 8. content_block_complete(tool_use)
      // 9. tool_call_complete
      // 10. stream_done
      expect(events.length, 10);
      expect(events[0], isA<LlmThinkingDelta>());
      expect(events[1], isA<LlmThinkingBlockComplete>());
      expect(events[2], isA<LlmContentBlockComplete>());
      expect(events[3], isA<LlmTextDelta>());
      expect(events[4], isA<LlmContentBlockComplete>());
      expect(events[5], isA<LlmToolCallStart>());
      expect(events[6], isA<LlmToolCallArgs>());
      expect(events[7], isA<LlmContentBlockComplete>());
      expect(events[8], isA<LlmToolCallComplete>());
      expect(events[9], isA<LlmStreamDone>());

      final tbComplete = events[1] as LlmThinkingBlockComplete;
      expect(tbComplete.thinking, 'Let me think');
      expect(tbComplete.signature, 'sig123');

      final ordered = events
          .whereType<LlmContentBlockComplete>()
          .map((e) => e.block)
          .toList();
      expect(ordered, hasLength(3));
      expect(ordered[0], isA<LlmThinkingContentBlock>());
      expect(ordered[1], isA<LlmTextContentBlock>());
      expect(ordered[2], isA<LlmToolUseContentBlock>());

      final tc = events[8] as LlmToolCallComplete;
      expect(tc.arguments['q'], 'test');
    });

    test('实例可复用：多次 parse 调用状态隔离', () async {
      // 第一次解析
      final stream1 = Stream.fromIterable([
        sseBlock('message_stop', {'type': 'message_stop'}),
      ]);
      final events1 = await parser.parse(stream1).toList();
      expect(events1.length, 1);
      expect(events1.first, isA<LlmStreamDone>());

      // 第二次解析（实例复用，状态应已重置）
      final stream2 = Stream.fromIterable([
        sseBlock('content_block_start', {
          'type': 'content_block_start',
          'index': 0,
          'content_block': {'type': 'text', 'text': ''},
        }),
        sseBlock('content_block_delta', {
          'type': 'content_block_delta',
          'index': 0,
          'delta': {'type': 'text_delta', 'text': 'Second'},
        }),
        sseBlock('content_block_stop', {
          'type': 'content_block_stop',
          'index': 0,
        }),
        sseBlock('message_stop', {'type': 'message_stop'}),
      ]);
      final events2 = await parser.parse(stream2).toList();

      // 不应有第一次的状态泄漏
      expect(events2.length, 3);
      expect(events2[0], isA<LlmTextDelta>());
      expect((events2[0] as LlmTextDelta).content, 'Second');
      expect(events2[1], isA<LlmContentBlockComplete>());
      expect(events2[2], isA<LlmStreamDone>());
    });

    group('流中 error 事件', () {
      test('error 事件发出 LlmStreamError 且不再兜底 LlmStreamDone', () async {
        final sseStream = Stream.fromIterable([
          sseBlock('message_start', {
            'type': 'message_start',
            'message': {
              'usage': {'input_tokens': 3, 'output_tokens': 0},
            },
          }),
          sseBlock('content_block_start', {
            'type': 'content_block_start',
            'index': 0,
            'content_block': {'type': 'text', 'text': ''},
          }),
          sseBlock('content_block_delta', {
            'type': 'content_block_delta',
            'index': 0,
            'delta': {'type': 'text_delta', 'text': 'partial'},
          }),
          sseBlock('error', {
            'type': 'error',
            'error': {'type': 'overloaded_error', 'message': 'Overloaded'},
          }),
        ]);

        final events = await parser.parse(sseStream).toList();

        // 应有：text_delta + stream_error；不得再发出兜底 LlmStreamDone
        expect(events, hasLength(2));
        expect(events[0], isA<LlmTextDelta>());
        expect(events[1], isA<LlmStreamError>());
        final error = events[1] as LlmStreamError;
        expect(error.message, 'Overloaded');
        expect(error.code, 'SERVER');
      });

      test('error 事件（无 event 字段，仅 data.type）同样上抛', () async {
        final errorData = jsonEncode({
          'type': 'error',
          'error': {'type': 'rate_limit_error', 'message': 'Too many requests'},
        });
        final sseStream = Stream.fromIterable(['data: $errorData\n\n']);

        final events = await parser.parse(sseStream).toList();

        expect(events, hasLength(1));
        expect(events[0], isA<LlmStreamError>());
        final error = events[0] as LlmStreamError;
        expect(error.message, 'Too many requests');
        expect(error.code, 'RATE_LIMIT');
      });
    });

    group('messageDelta stop_reason 上抛 finishReason', () {
      test('stop_reason=max_tokens 映射为 length 随 LlmStreamDone 上抛', () async {
        final sseStream = Stream.fromIterable([
          sseBlock('message_delta', {
            'type': 'message_delta',
            'delta': {'stop_reason': 'max_tokens', 'stop_sequence': null},
            'usage': {'output_tokens': 5},
          }),
          sseBlock('message_stop', {'type': 'message_stop'}),
        ]);

        final events = await parser.parse(sseStream).toList();

        final done = events.whereType<LlmStreamDone>().single;
        expect(done.finishReason, 'length');
      });

      test('stop_reason=end_turn 映射为 stop', () async {
        final sseStream = Stream.fromIterable([
          sseBlock('message_delta', {
            'type': 'message_delta',
            'delta': {'stop_reason': 'end_turn', 'stop_sequence': null},
          }),
          sseBlock('message_stop', {'type': 'message_stop'}),
        ]);

        final events = await parser.parse(sseStream).toList();

        final done = events.whereType<LlmStreamDone>().single;
        expect(done.finishReason, 'stop');
      });

      test('流中断（无 message_stop）时兜底 Done 同样携带 finishReason', () async {
        final sseStream = Stream.fromIterable([
          sseBlock('message_delta', {
            'type': 'message_delta',
            'delta': {'stop_reason': 'max_tokens', 'stop_sequence': null},
          }),
          // 流突然结束
        ]);

        final events = await parser.parse(sseStream).toList();

        final done = events.whereType<LlmStreamDone>().single;
        expect(done.finishReason, 'length');
      });

      test('无 stop_reason 时 finishReason 为 null（不误报）', () async {
        final sseStream = Stream.fromIterable([
          sseBlock('message_stop', {'type': 'message_stop'}),
        ]);

        final events = await parser.parse(sseStream).toList();

        final done = events.whereType<LlmStreamDone>().single;
        expect(done.finishReason, isNull);
      });
    });

    test('实例复用时缓存计量字段随 parse 重置', () async {
      // 第一次解析：携带 cache_read_input_tokens / cache_creation_input_tokens
      final stream1 = Stream.fromIterable([
        sseBlock('message_start', {
          'type': 'message_start',
          'message': {
            'usage': {
              'input_tokens': 10,
              'output_tokens': 0,
              'cache_read_input_tokens': 5,
              'cache_creation_input_tokens': 2,
            },
          },
        }),
        sseBlock('message_stop', {'type': 'message_stop'}),
      ]);
      final events1 = await parser.parse(stream1).toList();
      final done1 = events1.whereType<LlmStreamDone>().single;
      expect(done1.usage?.cacheReadTokens, 5);
      expect(done1.usage?.cacheCreationTokens, 2);

      // 第二次解析（复用实例）：无 message_start usage、仅 message_delta
      // output_tokens——此时 _buildUsage 仍会读取缓存字段，不应残留上一流的
      // 缓存计量
      final stream2 = Stream.fromIterable([
        sseBlock('content_block_delta', {
          'type': 'content_block_delta',
          'index': 0,
          'delta': {'type': 'text_delta', 'text': 'Second'},
        }),
        sseBlock('message_delta', {
          'type': 'message_delta',
          'delta': {'stop_reason': 'end_turn', 'stop_sequence': null},
          'usage': {'output_tokens': 3},
        }),
        sseBlock('message_stop', {'type': 'message_stop'}),
      ]);
      final events2 = await parser.parse(stream2).toList();
      final done2 = events2.whereType<LlmStreamDone>().single;
      expect(done2.usage?.completionTokens, 3);
      expect(done2.usage?.cacheReadTokens, isNull);
      expect(done2.usage?.cacheCreationTokens, isNull);
    });

    test('解析 redacted_thinking block（data 原样保留）', () async {
      final sseStream = Stream.fromIterable([
        sseBlock('content_block_start', {
          'type': 'content_block_start',
          'index': 0,
          'content_block': {
            'type': 'redacted_thinking',
            'data': 'encrypted-data',
          },
        }),
        sseBlock('content_block_stop', {
          'type': 'content_block_stop',
          'index': 0,
        }),
        sseBlock('message_stop', {'type': 'message_stop'}),
      ]);

      final events = await parser.parse(sseStream).toList();

      expect(events.whereType<LlmThinkingBlockComplete>(), isEmpty);
      final complete = events.whereType<LlmContentBlockComplete>().single;
      final block = complete.block;
      expect(block, isA<LlmRedactedThinkingContentBlock>());
      expect((block as LlmRedactedThinkingContentBlock).data, 'encrypted-data');
    });

    test('usage.totalInputTokens 含 cache read/creation', () async {
      final sseStream = Stream.fromIterable([
        sseBlock('message_start', {
          'type': 'message_start',
          'message': {
            'usage': {
              'input_tokens': 10,
              'output_tokens': 0,
              'cache_read_input_tokens': 5,
              'cache_creation_input_tokens': 2,
            },
          },
        }),
        sseBlock('message_delta', {
          'type': 'message_delta',
          'delta': {'stop_reason': 'end_turn', 'stop_sequence': null},
          'usage': {'output_tokens': 3},
        }),
        sseBlock('message_stop', {'type': 'message_stop'}),
      ]);

      final events = await parser.parse(sseStream).toList();
      final done = events.whereType<LlmStreamDone>().single;
      expect(done.usage?.totalInputTokens, 17);
      expect(done.usage?.promptTokens, 10);
    });

    test('新 stop_reason 映射', () async {
      for (final (raw, mapped) in [
        ('model_context_window_exceeded', 'context_window_exceeded'),
        ('pause_turn', 'pause_turn'),
      ]) {
        final sseStream = Stream.fromIterable([
          sseBlock('message_delta', {
            'type': 'message_delta',
            'delta': {'stop_reason': raw, 'stop_sequence': null},
          }),
          sseBlock('message_stop', {'type': 'message_stop'}),
        ]);

        final events = await parser.parse(sseStream).toList();
        final done = events.whereType<LlmStreamDone>().single;
        expect(done.finishReason, mapped);
      }
    });

    test('tool_use 参数非法 JSON → FORMAT_ERROR 且不兜底 Done', () async {
      final sseStream = Stream.fromIterable([
        sseBlock('content_block_start', {
          'type': 'content_block_start',
          'index': 0,
          'content_block': {
            'type': 'tool_use',
            'id': 'toolu_bad',
            'name': 'echo',
            'input': <String, dynamic>{},
          },
        }),
        sseBlock('content_block_delta', {
          'type': 'content_block_delta',
          'index': 0,
          'delta': {
            'type': 'input_json_delta',
            'partial_json': '{invalid',
          },
        }),
        sseBlock('content_block_stop', {
          'type': 'content_block_stop',
          'index': 0,
        }),
        sseBlock('message_stop', {'type': 'message_stop'}),
      ]);

      final events = await parser.parse(sseStream).toList();

      expect(events.whereType<LlmStreamDone>(), isEmpty);
      expect(
        events.whereType<LlmStreamError>().single.code,
        'FORMAT_ERROR',
      );
    });
  });
}
