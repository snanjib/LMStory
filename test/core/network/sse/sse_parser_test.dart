import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/exceptions/app_exceptions.dart';
import 'package:lmstory/core/network/sse/sse_parser.dart';

void main() {
  group('SseParser', () {
    late SseParser parser;

    setUp(() {
      parser = SseParser();
    });

    test('idle → streamingText 状态转换', () async {
      expect(parser.state, SseParserState.idle);

      final rawStream = Stream.fromIterable([
        'data: {"choices":[{"delta":{"content":"Hello"},"finish_reason":null}]}\n\n',
      ]);

      final events = await parser.parse(rawStream).toList();

      expect(events, hasLength(2));
      expect(events[0], isA<TextDelta>());
      expect((events[0] as TextDelta).content, 'Hello');
      expect(events[1], isA<StreamEnd>());
      // After stream ends, parser is reset
    });

    test('纯文本 SSE 数据解析', () async {
      final chunks = [
        'data: {"choices":[{"delta":{"content":"Hello "},"finish_reason":null}]}\n\n',
        'data: {"choices":[{"delta":{"content":"World"},"finish_reason":null}]}\n\n',
        'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\n',
        'data: [DONE]\n\n',
      ];

      final events = await parser.parse(Stream.fromIterable(chunks)).toList();

      final textDeltas = events.whereType<TextDelta>().toList();
      expect(textDeltas, hasLength(2));
      expect(textDeltas[0].content, 'Hello ');
      expect(textDeltas[1].content, 'World');

      // [DONE] signal produces StreamEnd (no duplicate)
      final streamEnds = events.whereType<StreamEnd>().toList();
      expect(streamEnds, hasLength(1));
    });

    test('finish_reason 透传到 StreamEnd（length 截断识别）', () async {
      final chunks = [
        'data: {"choices":[{"delta":{"reasoning":"思考中…"},"finish_reason":null}]}\n\n',
        'data: {"choices":[{"delta":{},"finish_reason":"length"}]}\n\n',
        'data: [DONE]\n\n',
      ];

      final events = await parser.parse(Stream.fromIterable(chunks)).toList();

      final streamEnd = events.whereType<StreamEnd>().single;
      expect(streamEnd.finishReason, 'length');
    });

    test('含 tool_calls 的 SSE 数据解析', () async {
      final chunks = [
        'data: {"choices":[{"delta":{"role":"assistant","content":null,"tool_calls":[{"index":0,"id":"call_abc123","type":"function","function":{"name":"update_world","arguments":""}}]},"finish_reason":null}]}\n\n',
        'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"state_"}}]},"finish_reason":null}]}\n\n',
        'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"patch\\":{\\"location\\":\\"forest\\"}}"}}]},"finish_reason":null}]}\n\n',
        'data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}\n\n',
        'data: [DONE]\n\n',
      ];

      final events = await parser.parse(Stream.fromIterable(chunks)).toList();

      // Should have: ToolCallStart, ToolCallArgs, ToolCallArgs, ToolCallComplete, StreamEnd
      final toolCallStarts = events.whereType<ToolCallStart>().toList();
      expect(toolCallStarts, hasLength(1));
      expect(toolCallStarts[0].toolCallId, 'call_abc123');
      expect(toolCallStarts[0].toolName, 'update_world');

      final toolCallArgs = events.whereType<ToolCallArgs>().toList();
      expect(toolCallArgs, hasLength(2));

      final toolCallCompletes = events.whereType<ToolCallComplete>().toList();
      expect(toolCallCompletes, hasLength(1));
      expect(toolCallCompletes[0].toolCallId, 'call_abc123');
      expect(toolCallCompletes[0].toolName, 'update_world');
      expect(
        toolCallCompletes[0].arguments,
        contains('state_patch'),
      );
    });

    test('streamingText → toolCallDetected 状态转换', () async {
      final chunks = [
        'data: {"choices":[{"delta":{"content":"Thinking..."},"finish_reason":null}]}\n\n',
        'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_xyz","type":"function","function":{"name":"update_world","arguments":""}}]},"finish_reason":null}]}\n\n',
        'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"key\\":\\"value\\"}"}}]},"finish_reason":null}]}\n\n',
        'data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}\n\n',
        'data: [DONE]\n\n',
      ];

      final events = await parser.parse(Stream.fromIterable(chunks)).toList();

      final textDeltas = events.whereType<TextDelta>().toList();
      expect(textDeltas, hasLength(1));
      expect(textDeltas[0].content, 'Thinking...');

      final toolCallStarts = events.whereType<ToolCallStart>().toList();
      expect(toolCallStarts, hasLength(1));
    });

    test('流中断信号处理 ([DONE])', () async {
      final chunks = [
        'data: {"choices":[{"delta":{"content":"Partial"},"finish_reason":null}]}\n\n',
        'data: [DONE]\n\n',
      ];

      final events = await parser.parse(Stream.fromIterable(chunks)).toList();

      final textDeltas = events.whereType<TextDelta>().toList();
      expect(textDeltas, hasLength(1));
      expect(textDeltas[0].content, 'Partial');

      final streamEnds = events.whereType<StreamEnd>().toList();
      // [DONE] produces single StreamEnd (no duplicate)
      expect(streamEnds, hasLength(1));
    });

    test('空数据块被忽略', () async {
      final chunks = [
        'data: {"choices":[{"delta":{"content":"Hi"},"finish_reason":null}]}\n\n',
        'data: \n\n',
        'data: {"choices":[{"delta":{}}]}\n\n',
      ];

      final events = await parser.parse(Stream.fromIterable(chunks)).toList();

      final textDeltas = events.whereType<TextDelta>().toList();
      expect(textDeltas, hasLength(1));
      expect(textDeltas[0].content, 'Hi');
    });

    test('无效 JSON 产生 StreamError', () async {
      final chunks = [
        'data: {invalid json}\n\n',
      ];

      final events = await parser.parse(Stream.fromIterable(chunks)).toList();

      final errors = events.whereType<StreamError>().toList();
      expect(errors, hasLength(1));
    });

    // P0-B 回归测试：多个 data: 行应以 \n 拼接为完整 payload
    // 修复前：只保留最后一个 data 行，导致拆分的 JSON 解析失败
    group('P0-B 多 data 行拼接', () {
      test('单个事件块内多个 data 行拼接为完整 JSON', () async {
        // 模拟服务器将一个 JSON payload 拆分到多个 data: 行
        // 拼接后：{"choices":[{"delta":{"content":"Hello"}}\n]}
        // JSON 允许 token 间任意空白，故 \n 不影响解析
        final chunks = [
          'data: {"choices":[{"delta":{"content":"Hello"}}\ndata: ]}\n\n',
        ];

        final events = await parser.parse(Stream.fromIterable(chunks)).toList();

        final textDeltas = events.whereType<TextDelta>().toList();
        expect(textDeltas, hasLength(1));
        expect(textDeltas[0].content, 'Hello');
        // 不应产生 StreamError（修复前会因只保留 "]}" 而解析失败）
        expect(events.whereType<StreamError>(), isEmpty);
      });

      test('三个 data 行拼接（模拟 o1 多行 reasoning_content 场景）', () async {
        // 模拟 OpenAI o1 模型将含换行的 reasoning_content 拆分到多个 data 行
        // 拼接后含 \n，但 JSON token 间的 \n 是合法空白
        const chunk =
            'data: {"choices":[{"delta":{"reasoning_content":"Thinking step1"'
            '\ndata: ,"reasoning_content":"step2"'
            '\ndata: }}]}\n\n';

        final events =
            await parser.parse(Stream.fromIterable([chunk])).toList();

        // 拼接后是合法 JSON，不应报错
        expect(events.whereType<StreamError>(), isEmpty);
      });

      test('多 data 行事件后接 [DONE] 信号', () async {
        final chunks = [
          'data: {"choices":[{"delta":{"content":"Hi"}}\ndata: ]}\n\n',
          'data: [DONE]\n\n',
        ];

        final events = await parser.parse(Stream.fromIterable(chunks)).toList();

        final textDeltas = events.whereType<TextDelta>().toList();
        expect(textDeltas, hasLength(1));
        expect(textDeltas[0].content, 'Hi');

        final streamEnds = events.whereType<StreamEnd>().toList();
        expect(streamEnds, hasLength(1));
      });

      test('单个 data 行行为不变（回归保护）', () async {
        // 确保修复未破坏单 data 行场景
        final chunks = [
          'data: {"choices":[{"delta":{"content":"Single"}}]}\n\n',
        ];

        final events = await parser.parse(Stream.fromIterable(chunks)).toList();

        final textDeltas = events.whereType<TextDelta>().toList();
        expect(textDeltas, hasLength(1));
        expect(textDeltas[0].content, 'Single');
      });
    });

    // DOC-12 §5.4.1 P0 缺口：JSON chunk 内 error 字段检测
    // 部分供应商（如 DeepSeek、OpenRouter）流式错误返回 200 + 含 error 字段的 JSON
    group('error 字段检测', () {
      test('含 error 字段的 JSON chunk 发出 StreamError', () async {
        // 模拟 DeepSeek V4 Flash 上游错误（memory 记录的实际场景）
        final chunks = [
          'data: {"error":{"message":"Upstream request failed","type":"upstream_error"}}\n\n',
        ];

        final events = await parser.parse(Stream.fromIterable(chunks)).toList();

        final errors = events.whereType<StreamError>().toList();
        expect(errors, hasLength(1));
        expect(errors[0].message, 'Upstream request failed');
        expect(errors[0].code, 'upstream_error');
      });

      test('error 字段含 code 时优先取 code', () async {
        final chunks = [
          'data: {"error":{"message":"Quota exceeded","code":"insufficient_quota","type":"quota"}}\n\n',
        ];

        final events = await parser.parse(Stream.fromIterable(chunks)).toList();

        final errors = events.whereType<StreamError>().toList();
        expect(errors, hasLength(1));
        expect(errors[0].message, 'Quota exceeded');
        expect(errors[0].code, 'insufficient_quota');
      });

      test('error 字段为字符串时直接作为 message', () async {
        final chunks = [
          'data: {"error":"Something went wrong"}\n\n',
        ];

        final events = await parser.parse(Stream.fromIterable(chunks)).toList();

        final errors = events.whereType<StreamError>().toList();
        expect(errors, hasLength(1));
        expect(errors[0].message, 'Something went wrong');
        expect(errors[0].code, isNull);
      });

      test('error chunk 后仍正常结束流（StreamEnd）', () async {
        final chunks = [
          'data: {"error":{"message":"Bad request","code":"400"}}\n\n',
        ];

        final events = await parser.parse(Stream.fromIterable(chunks)).toList();

        // 应有 1 个 StreamError + 1 个 StreamEnd
        expect(events.whereType<StreamError>(), hasLength(1));
        expect(events.whereType<StreamEnd>(), hasLength(1));
      });

      test('正常 chunk 与 error chunk 混合时 error 不被吞掉', () async {
        final chunks = [
          'data: {"choices":[{"delta":{"content":"Hi"},"finish_reason":null}]}\n\n',
          'data: {"error":{"message":"Interrupted","code":"interrupted"}}\n\n',
        ];

        final events = await parser.parse(Stream.fromIterable(chunks)).toList();

        // 应有 1 个 TextDelta + 1 个 StreamError + 1 个 StreamEnd
        expect(events.whereType<TextDelta>(), hasLength(1));
        expect(events.whereType<StreamError>(), hasLength(1));
        expect(events.whereType<StreamEnd>(), hasLength(1));
      });

      // 2026-07-29 回归测试：供应商 error.code 为数字类型时不应崩溃
      // 复现场景：NVIDIA NIM / 部分供应商返回 {"error":{"code":500,...}}
      // 修复前：`errorJson['code'] as String?` 抛 _TypeError，
      // 被外层 catch 包装为 "Failed to parse SSE data: type 'int' is not
      // a subtype of type 'String?' in type cast"，掩盖供应商真实错误。
      test('error.code 为数字时不崩溃且正确转为字符串', () async {
        final chunks = [
          'data: {"error":{"message":"Internal server error","code":500,"type":"server_error"}}\n\n',
        ];

        final events = await parser.parse(Stream.fromIterable(chunks)).toList();

        final errors = events.whereType<StreamError>().toList();
        expect(errors, hasLength(1));
        expect(errors[0].message, 'Internal server error');
        // 数字 500 应被 toString() 转为字符串 "500"
        expect(errors[0].code, '500');
        // 不应产生 "Failed to parse SSE data" 包装错误
        expect(
          errors.any((e) => e.message.contains('Failed to parse SSE data')),
          isFalse,
        );
      });

      test('error.code 为数字 429（限流）时正确解析', () async {
        final chunks = [
          'data: {"error":{"message":"Rate limit exceeded","code":429}}\n\n',
        ];

        final events = await parser.parse(Stream.fromIterable(chunks)).toList();

        final errors = events.whereType<StreamError>().toList();
        expect(errors, hasLength(1));
        expect(errors[0].message, 'Rate limit exceeded');
        expect(errors[0].code, '429');
      });

      test('error.message 为非字符串时兜底为 Unknown stream error', () async {
        final chunks = [
          'data: {"error":{"message":500,"code":"server_error"}}\n\n',
        ];

        final events = await parser.parse(Stream.fromIterable(chunks)).toList();

        final errors = events.whereType<StreamError>().toList();
        expect(errors, hasLength(1));
        expect(errors[0].message, 'Unknown stream error');
        expect(errors[0].code, 'server_error');
      });

      test('error 仅有 code 无 type 时不崩溃', () async {
        final chunks = [
          'data: {"error":{"code":400}}\n\n',
        ];

        final events = await parser.parse(Stream.fromIterable(chunks)).toList();

        final errors = events.whereType<StreamError>().toList();
        expect(errors, hasLength(1));
        expect(errors[0].message, 'Unknown stream error');
        expect(errors[0].code, '400');
      });
    });

    // 2026-07-29 回归测试：delta 字段非字符串类型容错
    // 部分供应商在结束帧可能返回非字符串 content/reasoning_content/reasoning
    // （如 null/false/0），原 `as String?` 强转会抛 _TypeError。
    group('delta 字段类型容错', () {
      test('content 为数字时不崩溃且视为无内容', () async {
        final chunks = [
          'data: {"choices":[{"delta":{"content":0},"finish_reason":null}]}\n\n',
          'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\n',
          'data: [DONE]\n\n',
        ];

        final events = await parser.parse(Stream.fromIterable(chunks)).toList();

        // 不应产生 StreamError
        expect(events.whereType<StreamError>(), isEmpty);
        // 也不应产生 TextDelta（数字 0 视为无内容）
        expect(events.whereType<TextDelta>(), isEmpty);
      });

      test('content 为 bool false 时不崩溃', () async {
        final chunks = [
          'data: {"choices":[{"delta":{"content":false},"finish_reason":null}]}\n\n',
          'data: [DONE]\n\n',
        ];

        final events = await parser.parse(Stream.fromIterable(chunks)).toList();

        expect(events.whereType<StreamError>(), isEmpty);
        expect(events.whereType<TextDelta>(), isEmpty);
      });

      test('reasoning_content 为数字时不崩溃', () async {
        final chunks = [
          'data: {"choices":[{"delta":{"reasoning_content":0},"finish_reason":null}]}\n\n',
          'data: [DONE]\n\n',
        ];

        final events = await parser.parse(Stream.fromIterable(chunks)).toList();

        expect(events.whereType<StreamError>(), isEmpty);
        expect(events.whereType<ThinkingDelta>(), isEmpty);
      });

      test('reasoning 为数字时不崩溃', () async {
        final chunks = [
          'data: {"choices":[{"delta":{"reasoning":1},"finish_reason":null}]}\n\n',
          'data: [DONE]\n\n',
        ];

        final events = await parser.parse(Stream.fromIterable(chunks)).toList();

        expect(events.whereType<StreamError>(), isEmpty);
        expect(events.whereType<ThinkingDelta>(), isEmpty);
      });

      test('finish_reason 为非字符串时不崩溃', () async {
        final chunks = [
          'data: {"choices":[{"delta":{"content":"Hi"},"finish_reason":0}]}\n\n',
          'data: [DONE]\n\n',
        ];

        final events = await parser.parse(Stream.fromIterable(chunks)).toList();

        // finish_reason 非字符串时视为 null，不影响 content 解析
        expect(events.whereType<StreamError>(), isEmpty);
        final textDeltas = events.whereType<TextDelta>().toList();
        expect(textDeltas, hasLength(1));
        expect(textDeltas[0].content, 'Hi');
      });
    });
  });

  // 连接期 HTTP 错误（AppHttpException）不再字符串化——语义码与
  // Retry-After 随 StreamError 结构化上抛，消费侧按语义判定重试/冷却
  group('B3 流中断语义码', () {
    test('流错误携带 AppHttpException(429 + Retry-After) → RATE_LIMIT + 冷却',
        () async {
      final raw = Stream<String>.error(
        const AppHttpException(
          'SSE request failed with status 429',
          statusCode: 429,
          headers: HttpErrorHeaders(retryAfter: '7'),
        ),
      );

      final events = await SseParser().parse(raw).toList();

      final errors = events.whereType<StreamError>().toList();
      expect(errors, hasLength(1));
      expect(errors.single.code, 'RATE_LIMIT');
      expect(errors.single.retryAfter, const Duration(seconds: 7));
    });

    test('流错误携带 AppHttpException(401) → AUTH（无冷却指示）', () async {
      final raw = Stream<String>.error(
        const AppHttpException('bad key', statusCode: 401),
      );

      final events = await SseParser().parse(raw).toList();

      final errors = events.whereType<StreamError>().toList();
      expect(errors, hasLength(1));
      expect(errors.single.code, 'AUTH');
      expect(errors.single.retryAfter, isNull);
    });

    test('非 HTTP 异常（解析错误）保持 STREAM_ERROR', () async {
      final raw = Stream<String>.error(const FormatException('bad'));
      final events = await SseParser().parse(raw).toList();
      expect(events.whereType<StreamError>().single.code, 'STREAM_ERROR');
    });
  });

  group('审查收官 R3-P2-4：CRLF 行尾归一化', () {
    test('中转端点 CRLFCRLF 分隔的多事件正常解析（不积压到流尾）', () async {
      final parser = SseParser();
      final crlf2 = String.fromCharCodes([13, 10, 13, 10]);
      final events = await parser
          .parse(
            Stream.value(
              'data: {"choices":[{"delta":{"content":"你好"}}]}${crlf2}data: [DONE]$crlf2',
            ),
          )
          .toList();

      final deltas = events.whereType<TextDelta>().toList();
      expect(deltas, isNotEmpty, reason: '修复前两事件拼成单块解析必炸');
      expect(deltas.first.content, '你好');
      expect(events.whereType<StreamEnd>(), isNotEmpty);
    });
  });
}
