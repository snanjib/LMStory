import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/network/sse/gemini_sse_parser.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';

/// 构造 Gemini SSE 数据块
///
/// Gemini SSE 无 event 字段，只有 data: {json}\n\n
String sseData(Map<String, dynamic> data) {
  return 'data: ${jsonEncode(data)}\n\n';
}

void main() {
  group('GeminiSseParser', () {
    late GeminiSseParser parser;

    setUp(() {
      parser = GeminiSseParser();
    });

    test('解析完整文本流（多 chunk 拼接 + usage）', () async {
      final sseStream = Stream.fromIterable([
        sseData({
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': 'Hello'},
                ],
                'role': 'model',
              },
              'finishReason': null,
              'index': 0,
            },
          ],
        }),
        sseData({
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': ' world'},
                ],
                'role': 'model',
              },
              'finishReason': 'STOP',
              'index': 0,
            },
          ],
          'usageMetadata': {
            'promptTokenCount': 10,
            'candidatesTokenCount': 5,
            'totalTokenCount': 15,
          },
        }),
      ]);

      final events = await parser.parse(sseStream).toList();

      // 事件序列：
      // 1. text_delta (Hello)
      // 2. text_delta ( world)
      // 3. stream_done (STOP finishReason 触发，含 usage)
      expect(events.length, 3);
      expect(events[0], isA<LlmTextDelta>());
      expect((events[0] as LlmTextDelta).content, 'Hello');
      expect(events[1], isA<LlmTextDelta>());
      expect((events[1] as LlmTextDelta).content, ' world');
      expect(events[2], isA<LlmStreamDone>());
      final done = events[2] as LlmStreamDone;
      expect(done.usage?.promptTokens, 10);
      expect(done.usage?.completionTokens, 5);
      expect(done.usage?.totalTokens, 15);
      // finishReason 随 StreamDone 上抛（length 截断诊断对 Gemini 生效）
      expect(done.finishReason, 'STOP');
    });

    test('B5-6：MAX_TOKENS → StreamDone 携带 finishReason（截断诊断可用）', () async {
      final parser = GeminiSseParser();
      final sseStream = Stream.fromIterable([
        sseData({
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': '写到一半'},
                ],
                'role': 'model',
              },
              'finishReason': 'MAX_TOKENS',
              'index': 0,
            },
          ],
        }),
      ]);

      final events = await parser.parse(sseStream).toList();

      final done = events.whereType<LlmStreamDone>().toList();
      expect(done, hasLength(1));
      expect(done.single.finishReason, 'MAX_TOKENS');
    });

    test('解析 thought（thinking 内容）', () async {
      final sseStream = Stream.fromIterable([
        sseData({
          'candidates': [
            {
              'content': {
                'parts': [
                  {'thought': true, 'text': 'Let me think...'},
                ],
                'role': 'model',
              },
              'finishReason': null,
              'index': 0,
            },
          ],
        }),
        sseData({
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': 'Answer'},
                ],
                'role': 'model',
              },
              'finishReason': 'STOP',
              'index': 0,
            },
          ],
        }),
      ]);

      final events = await parser.parse(sseStream).toList();

      // 事件序列：
      // 1. thinking_delta (thought:true)
      // 2. text_delta (普通文本)
      // 3. stream_done
      expect(events.length, 3);
      expect(events[0], isA<LlmThinkingDelta>());
      expect((events[0] as LlmThinkingDelta).content, 'Let me think...');
      expect(events[1], isA<LlmTextDelta>());
      expect((events[1] as LlmTextDelta).content, 'Answer');
      expect(events[2], isA<LlmStreamDone>());
    });

    test('解析 functionCall（完整返回，非增量）', () async {
      final sseStream = Stream.fromIterable([
        sseData({
          'candidates': [
            {
              'content': {
                'parts': [
                  {
                    'functionCall': {
                      'name': 'get_weather',
                      'args': {'location': 'NYC'},
                    },
                  },
                ],
                'role': 'model',
              },
              'finishReason': 'STOP',
              'index': 0,
            },
          ],
        }),
      ]);

      final events = await parser.parse(sseStream).toList();

      // 事件序列：
      // 1. tool_call_start (Gemini functionCall 完整返回)
      // 2. tool_call_complete (紧随 start 发出)
      // 3. stream_done
      expect(events.length, 3);
      expect(events[0], isA<LlmToolCallStart>());
      final start = events[0] as LlmToolCallStart;
      expect(start.toolCallId, 'gemini_get_weather');
      expect(start.name, 'get_weather');
      expect(events[1], isA<LlmToolCallComplete>());
      final complete = events[1] as LlmToolCallComplete;
      expect(complete.toolCallId, 'gemini_get_weather');
      expect(complete.name, 'get_weather');
      expect(complete.arguments['location'], 'NYC');
      expect(events[2], isA<LlmStreamDone>());
    });

    test('functionCall 去重：同一 name 多次出现只发一次', () async {
      // Gemini 偶尔会在后续 chunk 重复携带已完成的 functionCall
      final sseStream = Stream.fromIterable([
        sseData({
          'candidates': [
            {
              'content': {
                'parts': [
                  {
                    'functionCall': {
                      'name': 'search',
                      'args': {'q': 'test'},
                    },
                  },
                ],
                'role': 'model',
              },
              'finishReason': null,
              'index': 0,
            },
          ],
        }),
        // 第二个 chunk 重复携带同一 functionCall（finishReason=STOP）
        sseData({
          'candidates': [
            {
              'content': {
                'parts': [
                  {
                    'functionCall': {
                      'name': 'search',
                      'args': {'q': 'test'},
                    },
                  },
                ],
                'role': 'model',
              },
              'finishReason': 'STOP',
              'index': 0,
            },
          ],
        }),
      ]);

      final events = await parser.parse(sseStream).toList();

      // 事件序列（去重后）：
      // 1. tool_call_start
      // 2. tool_call_complete
      // 3. stream_done (STOP 触发)
      // 第二个 functionCall 被去重过滤，不再发出
      expect(events.length, 3);
      expect(events[0], isA<LlmToolCallStart>());
      expect(events[1], isA<LlmToolCallComplete>());
      expect(events[2], isA<LlmStreamDone>());
    });

    test('SAFETY finishReason 触发 LlmStreamError', () async {
      final sseStream = Stream.fromIterable([
        sseData({
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': 'partial'},
                ],
                'role': 'model',
              },
              'finishReason': 'SAFETY',
              'index': 0,
            },
          ],
        }),
      ]);

      final events = await parser.parse(sseStream).toList();

      // 事件序列：
      // 1. text_delta (partial)
      // 2. stream_error (SAFETY_BLOCKED)
      // 3. stream_done (跟随 error 后发出)
      expect(events.length, 3);
      expect(events[0], isA<LlmTextDelta>());
      expect((events[0] as LlmTextDelta).content, 'partial');
      expect(events[1], isA<LlmStreamError>());
      expect((events[1] as LlmStreamError).code, 'SAFETY_BLOCKED');
      expect(events[2], isA<LlmStreamDone>());
    });

    test('RECITATION finishReason 触发 LlmStreamError', () async {
      final sseStream = Stream.fromIterable([
        sseData({
          'candidates': [
            {
              'finishReason': 'RECITATION',
              'index': 0,
            },
          ],
        }),
      ]);

      final events = await parser.parse(sseStream).toList();

      // 事件序列：
      // 1. stream_error (RECITATION_BLOCKED)
      // 2. stream_done
      expect(events.length, 2);
      expect(events[0], isA<LlmStreamError>());
      expect((events[0] as LlmStreamError).code, 'RECITATION_BLOCKED');
      expect(events[1], isA<LlmStreamDone>());
    });

    test('MAX_TOKENS finishReason 触发 LlmStreamDone', () async {
      final sseStream = Stream.fromIterable([
        sseData({
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': 'truncated'},
                ],
                'role': 'model',
              },
              'finishReason': 'MAX_TOKENS',
              'index': 0,
            },
          ],
          'usageMetadata': {
            'promptTokenCount': 5,
            'candidatesTokenCount': 100,
            'totalTokenCount': 105,
          },
        }),
      ]);

      final events = await parser.parse(sseStream).toList();

      // 事件序列：
      // 1. text_delta
      // 2. stream_done (MAX_TOKENS 触发，含 usage)
      expect(events.length, 2);
      expect(events[0], isA<LlmTextDelta>());
      expect(events[1], isA<LlmStreamDone>());
      final done = events[1] as LlmStreamDone;
      expect(done.usage?.completionTokens, 100);
    });

    test('流自然关闭无 finishReason 仍发出 LlmStreamDone 兜底', () async {
      final sseStream = Stream.fromIterable([
        sseData({
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': 'Hi'},
                ],
                'role': 'model',
              },
              'finishReason': null,
              'index': 0,
            },
          ],
        }),
        // 流突然关闭，无 STOP finishReason
      ]);

      final events = await parser.parse(sseStream).toList();

      // 事件序列：
      // 1. text_delta
      // 2. stream_done (兜底)
      expect(events.length, 2);
      expect(events[0], isA<LlmTextDelta>());
      expect(events[1], isA<LlmStreamDone>());
    });

    test('解析错误 JSON 时发出 LlmStreamError', () async {
      final sseStream = Stream.fromIterable([
        'data: {invalid json}\n\n',
      ]);

      final events = await parser.parse(sseStream).toList();

      // 事件序列：
      // 1. stream_error (PARSE_ERROR)
      // 2. stream_done (兜底)
      expect(events.length, 2);
      expect(events[0], isA<LlmStreamError>());
      expect((events[0] as LlmStreamError).code, 'PARSE_ERROR');
      expect(events[1], isA<LlmStreamDone>());
    });

    test('兼容 [DONE] 标记（某些代理可能添加）', () async {
      final sseStream = Stream.fromIterable([
        sseData({
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': 'Done'},
                ],
                'role': 'model',
              },
              'finishReason': null,
              'index': 0,
            },
          ],
        }),
        'data: [DONE]\n\n',
      ]);

      final events = await parser.parse(sseStream).toList();

      // 事件序列：
      // 1. text_delta
      // 2. stream_done (由 [DONE] 触发)
      expect(events.length, 2);
      expect(events[0], isA<LlmTextDelta>());
      expect(events[1], isA<LlmStreamDone>());
    });

    test('空 candidates 数组不产生事件', () async {
      final sseStream = Stream.fromIterable([
        sseData({
          'candidates': <dynamic>[],
          'usageMetadata': {
            'promptTokenCount': 5,
            'candidatesTokenCount': 0,
            'totalTokenCount': 5,
          },
        }),
      ]);

      final events = await parser.parse(sseStream).toList();

      // 事件序列：
      // 1. stream_done (兜底，无 candidates 但有 usage)
      expect(events.length, 1);
      expect(events[0], isA<LlmStreamDone>());
      final done = events[0] as LlmStreamDone;
      expect(done.usage?.promptTokens, 5);
    });

    test('空流仍发出 LlmStreamDone 兜底', () async {
      // Gemini parser 设计：流自然关闭时若未收到 STOP，仍发出 LlmStreamDone
      // 空流也符合此兜底逻辑
      const sseStream = Stream<String>.empty();
      final events = await parser.parse(sseStream).toList();
      expect(events.length, 1);
      expect(events[0], isA<LlmStreamDone>());
    });

    test('混合场景：text + thought + functionCall', () async {
      final sseStream = Stream.fromIterable([
        // chunk 1: thinking
        sseData({
          'candidates': [
            {
              'content': {
                'parts': [
                  {'thought': true, 'text': 'Thinking...'},
                ],
                'role': 'model',
              },
              'finishReason': null,
              'index': 0,
            },
          ],
        }),
        // chunk 2: text + functionCall
        sseData({
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': 'Calling tool'},
                  {
                    'functionCall': {
                      'name': 'lookup',
                      'args': {'id': 42},
                    },
                  },
                ],
                'role': 'model',
              },
              'finishReason': 'STOP',
              'index': 0,
            },
          ],
          'usageMetadata': {
            'promptTokenCount': 10,
            'candidatesTokenCount': 20,
            'totalTokenCount': 30,
          },
        }),
      ]);

      final events = await parser.parse(sseStream).toList();

      // 事件序列：
      // 1. thinking_delta
      // 2. text_delta (Calling tool)
      // 3. tool_call_start (lookup)
      // 4. tool_call_complete (lookup, args={id:42})
      // 5. stream_done
      expect(events.length, 5);
      expect(events[0], isA<LlmThinkingDelta>());
      expect((events[0] as LlmThinkingDelta).content, 'Thinking...');
      expect(events[1], isA<LlmTextDelta>());
      expect((events[1] as LlmTextDelta).content, 'Calling tool');
      expect(events[2], isA<LlmToolCallStart>());
      expect(events[3], isA<LlmToolCallComplete>());
      final tc = events[3] as LlmToolCallComplete;
      expect(tc.name, 'lookup');
      expect(tc.arguments['id'], 42);
      expect(events[4], isA<LlmStreamDone>());
      final done = events[4] as LlmStreamDone;
      expect(done.usage?.totalTokens, 30);
    });

    test('实例可复用：多次 parse 调用状态隔离', () async {
      // 第一次解析
      final stream1 = Stream.fromIterable([
        sseData({
          'candidates': [
            {
              'content': {
                'parts': [
                  {
                    'functionCall': {
                      'name': 'first',
                      'args': <String, dynamic>{},
                    },
                  },
                ],
                'role': 'model',
              },
              'finishReason': 'STOP',
              'index': 0,
            },
          ],
        }),
      ]);
      final events1 = await parser.parse(stream1).toList();
      expect(events1.length, 3);
      expect(events1[0], isA<LlmToolCallStart>());
      expect((events1[0] as LlmToolCallStart).name, 'first');

      // 第二次解析（实例复用，去重集合应已重置）
      final stream2 = Stream.fromIterable([
        sseData({
          'candidates': [
            {
              'content': {
                'parts': [
                  {
                    'functionCall': {
                      'name': 'first', // 同名，但应再次发出（状态已重置）
                      'args': <String, dynamic>{},
                    },
                  },
                ],
                'role': 'model',
              },
              'finishReason': 'STOP',
              'index': 0,
            },
          ],
        }),
      ]);
      final events2 = await parser.parse(stream2).toList();

      // 不应有第一次的状态泄漏：同名 functionCall 应再次发出
      expect(events2.length, 3);
      expect(events2[0], isA<LlmToolCallStart>());
      expect((events2[0] as LlmToolCallStart).name, 'first');
    });

    test('XC-4：实例复用时 finishReason 随 parse() 重置', () async {
      // 第一次解析：finishReason=MAX_TOKENS
      final stream1 = Stream.fromIterable([
        sseData({
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': 'first'},
                ],
                'role': 'model',
              },
              'finishReason': 'MAX_TOKENS',
              'index': 0,
            },
          ],
        }),
      ]);
      final events1 = await parser.parse(stream1).toList();
      expect(
        events1.whereType<LlmStreamDone>().single.finishReason,
        'MAX_TOKENS',
      );

      // 第二次解析（复用实例）：无 finishReason，兜底 Done 不应残留上一流的值
      final stream2 = Stream.fromIterable([
        sseData({
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': 'second'},
                ],
                'role': 'model',
              },
              'finishReason': null,
              'index': 0,
            },
          ],
        }),
      ]);
      final events2 = await parser.parse(stream2).toList();

      final done2 = events2.whereType<LlmStreamDone>().single;
      expect(done2.finishReason, isNull);
    });
  });

  group('审查收官 R3-P1-3：流内 error 块检测', () {
    test('200 + error chunk → LlmStreamError（语义码映射）且无兜底空 Done', () async {
      final parser = GeminiSseParser();
      final events = await parser
          .parse(
            Stream.value(
              'data: {"error":{"message":"API key not valid","code":401}}'
              '\n\n',
            ),
          )
          .toList();

      expect(events, hasLength(1));
      final error = events.single as LlmStreamError;
      expect(error.message, 'API key not valid');
      expect(error.code, 'AUTH');
      // 无兜底 Done（空内容假成功已被抑制）
      expect(events.whereType<LlmStreamDone>(), isEmpty);
    });

    test('Gemini status 形态（RESOURCE_EXHAUSTED）→ RATE_LIMIT 语义码', () async {
      final parser = GeminiSseParser();
      final events = await parser
          .parse(
            Stream.value(
              'data: {"error":{"message":"quota exceeded","status":"RESOURCE_EXHAUSTED"}}\n\n',
            ),
          )
          .toList();
      final error = events.single as LlmStreamError;
      expect(error.code, 'RATE_LIMIT');
    });
  });

  group('v0.3 M0：thoughtSignature 与同名多次调用', () {
    test('functionCall part 携带 thoughtSignature → Complete 事件透传', () async {
      final parser = GeminiSseParser();
      final stream = Stream.fromIterable([
        sseData({
          'candidates': [
            {
              'content': {
                'parts': [
                  {
                    'functionCall': {
                      'name': 'search_story',
                      'args': {'query': '风暴'},
                    },
                    'thoughtSignature': 'sig-abc123',
                  },
                ],
                'role': 'model',
              },
              'finishReason': 'STOP',
              'index': 0,
            },
          ],
        }),
      ]);

      final events = await parser.parse(stream).toList();
      final completes = events.whereType<LlmToolCallComplete>().toList();
      expect(completes, hasLength(1));
      expect(completes.first.thoughtSignature, 'sig-abc123');
      expect(completes.first.toolCallId, 'gemini_search_story');
    });

    test('同名不同参数的两次调用均发出，id 带序号后缀', () async {
      final parser = GeminiSseParser();
      final stream = Stream.fromIterable([
        sseData({
          'candidates': [
            {
              'content': {
                'parts': [
                  {
                    'functionCall': {
                      'name': 'search_story',
                      'args': {'query': 'A'},
                    },
                  },
                  {
                    'functionCall': {
                      'name': 'search_story',
                      'args': {'query': 'B'},
                    },
                  },
                ],
                'role': 'model',
              },
              'finishReason': 'STOP',
              'index': 0,
            },
          ],
        }),
      ]);

      final events = await parser.parse(stream).toList();
      final completes = events.whereType<LlmToolCallComplete>().toList();
      // 修复前：同名去重导致第二个调用被丢弃
      expect(completes, hasLength(2));
      expect(completes[0].toolCallId, 'gemini_search_story');
      expect(completes[1].toolCallId, 'gemini_search_story__1');
    });

    test('完全相同的 functionCall 重复 chunk 仍被去重', () async {
      final parser = GeminiSseParser();
      final part = {
        'functionCall': {
          'name': 'search_story',
          'args': {'query': 'A'},
        },
      };
      final chunk = sseData({
        'candidates': [
          {
            'content': {
              'parts': [part],
              'role': 'model',
            },
            'index': 0,
          },
        ],
      });
      final stream = Stream.fromIterable([chunk, chunk, chunk]);

      final events = await parser.parse(stream).toList();
      expect(events.whereType<LlmToolCallComplete>(), hasLength(1));
    });

    test(r'CRLF 行尾流（Gemini 真机 \r\n\r\n 分隔）正常解析出文本与 Done', () async {
      // 2026-09-03 真机反馈：Gemini 事件分隔符是 \r\n\r\n，此前 RawSseChunkParser
      // 只认 \n\n，整条流缓冲到流尾后所有 data 行拼成一个字符串，
      // jsonDecode 在第 2 行第 1 列报 PARSE_ERROR。
      String sseCrlf(Map<String, dynamic> data) =>
          'data: ${jsonEncode(data)}\r\n\r\n';
      final stream = Stream.fromIterable([
        sseCrlf({
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': '你好'},
                ],
                'role': 'model',
              },
              'index': 0,
            },
          ],
        }),
        sseCrlf({
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': '，世界'},
                ],
                'role': 'model',
              },
              'finishReason': 'STOP',
              'index': 0,
            },
          ],
        }),
      ]);

      final events = await GeminiSseParser().parse(stream).toList();
      expect(events.whereType<LlmStreamError>(), isEmpty);
      expect(
        events.whereType<LlmTextDelta>().map((e) => e.content).join(),
        '你好，世界',
      );
      expect(events.whereType<LlmStreamDone>(), hasLength(1));
    });
  });

  group('静默失败形态必须产出可见错误（2026-09-08 用户报告排查）', () {
    /// 用户报告：Gemini 3.8 生成消息静默消失、无报错。下列响应形态此前
    /// 被解析器静默跳过（空 candidates / 未知 finishReason），流以「干净
    /// 空响应」收尾——上层按 CH-1 只清 busy 态，用户看不到任何反馈。
    test('promptFeedback.blockReason（无 candidates）→ LlmStreamError，不再静默',
        () async {
      final stream = Stream.fromIterable([
        sseData({
          'promptFeedback': {'blockReason': 'SAFETY'},
        }),
      ]);
      final events = await GeminiSseParser().parse(stream).toList();
      final errors = events.whereType<LlmStreamError>().toList();
      expect(errors, hasLength(1), reason: '安全拦截必须有可见错误事件');
      expect(errors.single.code, 'SAFETY_BLOCKED');
      expect(errors.single.message, contains('SAFETY'));
    });

    test('未知 finishReason（PROHIBITED_CONTENT）→ LlmStreamError', () async {
      final stream = Stream.fromIterable([
        sseData({
          'candidates': [
            {
              'content': {
                'parts': <Map<String, dynamic>>[],
                'role': 'model',
              },
              'finishReason': 'PROHIBITED_CONTENT',
              'index': 0,
            },
          ],
        }),
      ]);
      final events = await GeminiSseParser().parse(stream).toList();
      expect(
        events.whereType<LlmStreamError>(),
        hasLength(1),
        reason: 'BLOCKLIST/PROHIBITED_CONTENT/SPII 等未知 finishReason 不能静默跳过',
      );
    });

    test('未知 finishReason 但已有正文 → 正文保留 + 错误事件（半截可见）', () async {
      final stream = Stream.fromIterable([
        sseData({
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': '写了一半的内容'},
                ],
                'role': 'model',
              },
              'finishReason': null,
              'index': 0,
            },
          ],
        }),
        sseData({
          'candidates': [
            {
              'content': {
                'parts': <Map<String, dynamic>>[],
                'role': 'model',
              },
              'finishReason': 'BLOCKLIST',
              'index': 0,
            },
          ],
        }),
      ]);
      final events = await GeminiSseParser().parse(stream).toList();
      expect(
        events.whereType<LlmTextDelta>().map((e) => e.content).join(),
        '写了一半的内容',
        reason: '已流出的正文不能丢',
      );
      expect(events.whereType<LlmStreamError>(), hasLength(1));
      // 错误后不得再补发「成功 Done」（错误即终点，上层据此展示失败）
      expect(events.whereType<LlmStreamDone>(), isEmpty);
    });

    test('STOP / MAX_TOKENS / SAFETY / RECITATION 之外的成功语义不变（回归保护）', () async {
      final stream = Stream.fromIterable([
        sseData({
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': 'ok'},
                ],
                'role': 'model',
              },
              'finishReason': 'STOP',
              'index': 0,
            },
          ],
        }),
      ]);
      final events = await GeminiSseParser().parse(stream).toList();
      expect(events.whereType<LlmStreamError>(), isEmpty);
      expect(events.whereType<LlmStreamDone>(), hasLength(1));
    });
  });
}
