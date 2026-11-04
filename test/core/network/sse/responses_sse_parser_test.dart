import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/network/sse/responses_sse_parser.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';

/// 构造 Responses SSE 事件块（event: + data: 双行）
String sseEvent(String event, Map<String, dynamic> data) {
  return 'event: $event\ndata: ${jsonEncode(data)}\n\n';
}

void main() {
  group('ResponsesSseParser', () {
    late ResponsesSseParser parser;

    setUp(() {
      parser = ResponsesSseParser();
    });

    test('文本增量流 + completed 携带 usage（input/output 命名映射）', () async {
      final stream = Stream.fromIterable([
        sseEvent('response.output_text.delta', {'delta': 'Hello'}),
        sseEvent('response.output_text.delta', {'delta': ' world'}),
        sseEvent('response.completed', {
          'response': {
            'status': 'completed',
            'usage': {
              'input_tokens': 10,
              'output_tokens': 5,
              'total_tokens': 15,
              'input_tokens_details': {'cached_tokens': 4},
            },
          },
        }),
      ]);

      final events = await parser.parse(stream).toList();

      expect(events.length, 3);
      expect((events[0] as LlmTextDelta).content, 'Hello');
      expect((events[1] as LlmTextDelta).content, ' world');
      final done = events[2] as LlmStreamDone;
      expect(done.usage!.promptTokens, 10);
      expect(done.usage!.completionTokens, 5);
      expect(done.usage!.totalTokens, 15);
      expect(done.usage!.cacheReadTokens, 4);
      expect(done.finishReason, isNull);
    });

    test('工具调用全流程：item.added → args.delta → args.done（完整串）→ completed',
        () async {
      final stream = Stream.fromIterable([
        sseEvent('response.output_item.added', {
          'item': {
            'type': 'function_call',
            'id': 'fc_1',
            'call_id': 'call_abc',
            'name': 'get_weather',
          },
        }),
        sseEvent('response.function_call_arguments.delta', {
          'item_id': 'fc_1',
          'delta': '{"loc',
        }),
        sseEvent('response.function_call_arguments.delta', {
          'item_id': 'fc_1',
          'delta': 'ation":"NYC"}',
        }),
        sseEvent('response.function_call_arguments.done', {
          'item_id': 'fc_1',
          'arguments': '{"location":"NYC"}',
        }),
        sseEvent('response.output_item.done', {
          'item': {
            'type': 'function_call',
            'id': 'fc_1',
            'call_id': 'call_abc',
            'name': 'get_weather',
            'arguments': '{"location":"NYC"}',
          },
        }),
        sseEvent('response.completed', {
          'response': {'status': 'completed'},
        }),
      ]);

      final events = await parser.parse(stream).toList();

      // start / args / args / complete（done 与 output_item.done 不重复完成）
      // / done
      expect(events.length, 5);
      final start = events[0] as LlmToolCallStart;
      expect(start.toolCallId, 'call_abc');
      expect(start.name, 'get_weather');
      expect((events[1] as LlmToolCallArgs).argsDelta, '{"loc');
      expect((events[2] as LlmToolCallArgs).argsDelta, 'ation":"NYC"}');
      final complete = events[3] as LlmToolCallComplete;
      expect(complete.toolCallId, 'call_abc');
      expect(complete.arguments['location'], 'NYC');
      expect(events[4], isA<LlmStreamDone>());
    });

    test('无 args.done 的实现：output_item.done 兜底完成', () async {
      final stream = Stream.fromIterable([
        sseEvent('response.output_item.added', {
          'item': {
            'type': 'function_call',
            'id': 'fc_2',
            'call_id': 'call_xyz',
            'name': 'search',
          },
        }),
        sseEvent('response.output_item.done', {
          'item': {
            'type': 'function_call',
            'id': 'fc_2',
            'call_id': 'call_xyz',
            'name': 'search',
            'arguments': '{"q":1}',
          },
        }),
        sseEvent('response.completed', {
          'response': {'status': 'completed'},
        }),
      ]);

      final events = await parser.parse(stream).toList();

      final complete = events.whereType<LlmToolCallComplete>().single;
      expect(complete.toolCallId, 'call_xyz');
      expect(complete.arguments['q'], 1);
    });

    test('response.failed → LlmStreamError（携带服务端错误信息）', () async {
      final stream = Stream.fromIterable([
        sseEvent('response.failed', {
          'response': {
            'status': 'failed',
            'error': {
              'code': 'rate_limit_exceeded',
              'message': 'You exceeded your quota',
            },
          },
        }),
      ]);

      final events = await parser.parse(stream).toList();

      final error = events.whereType<LlmStreamError>().single;
      expect(error.message, contains('quota'));
      expect(error.code, 'rate_limit_exceeded');
      // 失败后不再兜底 Done
      expect(events.whereType<LlmStreamDone>(), isEmpty);
    });

    test('顶层 error 事件 → LlmStreamError', () async {
      final stream = Stream.fromIterable([
        sseEvent('error', {
          'type': 'error',
          'code': 'server_error',
          'message': 'Internal error',
        }),
      ]);

      final events = await parser.parse(stream).toList();

      final error = events.whereType<LlmStreamError>().single;
      expect(error.message, 'Internal error');
      expect(events.whereType<LlmStreamDone>(), isEmpty);
    });

    test('response.incomplete → Done 携带 length（max_output_tokens 截断）',
        () async {
      final stream = Stream.fromIterable([
        sseEvent('response.incomplete', {
          'response': {
            'status': 'incomplete',
            'incomplete_details': {'reason': 'max_output_tokens'},
            'usage': {
              'input_tokens': 8,
              'output_tokens': 64,
              'total_tokens': 72,
            },
          },
        }),
      ]);

      final events = await parser.parse(stream).toList();

      final done = events.whereType<LlmStreamDone>().single;
      expect(done.finishReason, 'length');
      expect(done.usage!.completionTokens, 64);
    });

    test('reasoning_summary_text.delta → 思考增量（推理摘要展示）', () async {
      final stream = Stream.fromIterable([
        sseEvent('response.reasoning_summary_text.delta', {
          'delta': '考虑天气查询…',
        }),
        sseEvent('response.completed', {
          'response': {'status': 'completed'},
        }),
      ]);

      final events = await parser.parse(stream).toList();

      expect((events[0] as LlmThinkingDelta).content, '考虑天气查询…');
    });

    test('断流兜底：无 completed 事件时完成累积中的工具调用并发出 Done', () async {
      final stream = Stream.fromIterable([
        sseEvent('response.output_item.added', {
          'item': {
            'type': 'function_call',
            'id': 'fc_9',
            'call_id': 'call_9',
            'name': 'echo',
          },
        }),
        sseEvent('response.function_call_arguments.delta', {
          'item_id': 'fc_9',
          'delta': '{"a":',
        }),
        // 直接断流（无 done / 无 completed）
      ]);

      final events = await parser.parse(stream).toList();

      final complete = events.whereType<LlmToolCallComplete>().single;
      // 增量累积被截断为非法 JSON → 容错为空 Map（与 CC 解析器对齐）
      expect(complete.arguments, isEmpty);
      expect(events.last, isA<LlmStreamDone>());
    });

    test('中转兼容：[DONE] 哨兵（Responses 官方无此标记）', () async {
      final stream = Stream.fromIterable([
        sseEvent('response.completed', {
          'response': {'status': 'completed'},
        }),
        'data: [DONE]\n\n',
      ]);

      final events = await parser.parse(stream).toList();

      // completed 已收尾，[DONE] 不产生第二个 Done
      expect(events.whereType<LlmStreamDone>().length, 1);
    });

    test('实例可复用：多次 parse 调用状态隔离', () async {
      Future<List<LlmStreamEvent>> run() async {
        final stream = Stream.fromIterable([
          sseEvent('response.output_item.added', {
            'item': {
              'type': 'function_call',
              'id': 'fc_1',
              'call_id': 'call_1',
              'name': 'x',
            },
          }),
          sseEvent('response.completed', {
            'response': {'status': 'completed'},
          }),
        ]);
        return parser.parse(stream).toList();
      }

      final first = await run();
      final second = await run();

      expect(first.whereType<LlmToolCallComplete>().length, 1);
      expect(second.whereType<LlmToolCallComplete>().length, 1);
      expect(second.whereType<LlmStreamDone>().length, 1);
    });
  });
}
