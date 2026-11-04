import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/network/sse/raw_sse_chunk_parser.dart';

void main() {
  group('RawSseChunkParser', () {
    test('解析单个 data 事件（无 event 字段，OpenAI 格式）', () async {
      final input = Stream.fromIterable(['data: {"hello":"world"}\n\n']);
      final parser = RawSseChunkParser();
      final results = await parser.parse(input).toList();

      expect(results.length, 1);
      expect(results.first.event, isNull);
      expect(results.first.data, '{"hello":"world"}');
    });

    test('解析 event + data 事件（Anthropic 格式）', () async {
      final input = Stream.fromIterable([
        'event: message_start\ndata: {"type":"message_start"}\n\n',
      ]);
      final parser = RawSseChunkParser();
      final results = await parser.parse(input).toList();

      expect(results.length, 1);
      expect(results.first.event, 'message_start');
      expect(results.first.data, '{"type":"message_start"}');
    });

    test('忽略 SSE 注释行（: keep-alive）', () async {
      final input = Stream.fromIterable([
        ': keep-alive\n\ndata: {"content":"hi"}\n\n',
      ]);
      final parser = RawSseChunkParser();
      final results = await parser.parse(input).toList();

      expect(results.length, 1);
      expect(results.first.data, '{"content":"hi"}');
    });

    test('跨 chunk 的事件块正确拼接', () async {
      final input = Stream.fromIterable([
        'data: {"par',
        't":"value"}\n\n',
      ]);
      final parser = RawSseChunkParser();
      final results = await parser.parse(input).toList();

      expect(results.length, 1);
      expect(results.first.data, '{"part":"value"}');
    });

    test(r'多行 data 字段按 \n 拼接（SSE 规范）', () async {
      // ignore: use_raw_strings
      final input = Stream.fromIterable(['data: line1\ndata: line2\n\n']);
      final parser = RawSseChunkParser();
      final results = await parser.parse(input).toList();

      expect(results.length, 1);
      expect(results.first.data, 'line1\nline2');
    });

    test('同时解析多个事件块', () async {
      final input = Stream.fromIterable([
        'data: {"i":1}\n\ndata: {"i":2}\n\ndata: {"i":3}\n\n',
      ]);
      final parser = RawSseChunkParser();
      final results = await parser.parse(input).toList();

      expect(results.length, 3);
      expect(results[0].data, '{"i":1}');
      expect(results[1].data, '{"i":2}');
      expect(results[2].data, '{"i":3}');
    });

    test('实例可复用：连续两次 parse 互不影响', () async {
      final parser = RawSseChunkParser();
      final r1 =
          await parser.parse(Stream.fromIterable(['data: a\n\n'])).toList();
      final r2 =
          await parser.parse(Stream.fromIterable(['data: b\n\n'])).toList();

      expect(r1.length, 1);
      expect(r1.first.data, 'a');
      expect(r2.length, 1);
      expect(r2.first.data, 'b');
    });

    test('空流不产生事件', () async {
      final parser = RawSseChunkParser();
      final results = await parser.parse(const Stream<String>.empty()).toList();
      expect(results, isEmpty);
    });

    test('处理 Gemini 流式 alt=sse 格式', () async {
      // Gemini streamGenerateContent?alt=sse 返回 data: {...} 格式
      final input = Stream.fromIterable([
        'data: {"candidates":[{"content":{"parts":[{"text":"hi"}]}}]}\n\n',
      ]);
      final parser = RawSseChunkParser();
      final results = await parser.parse(input).toList();

      expect(results.length, 1);
      expect(results.first.event, isNull);
      expect(results.first.data, contains('"candidates"'));
    });

    group('CRLF 行尾（2026-09-03 Gemini 真机 PARSE_ERROR 修复）', () {
      test(r'Gemini 实际以 \r\n\r\n 分隔事件，须逐块流出而非缓冲到流尾', () async {
        final input = Stream.fromIterable([
          'data: {"i":1}\r\n\r\ndata: {"i":2}\r\n\r\n',
        ]);
        final parser = RawSseChunkParser();
        final results = await parser.parse(input).toList();

        expect(results.length, 2);
        expect(results[0].data, '{"i":1}');
        expect(results[1].data, '{"i":2}');
      });

      test(r'CRLF 分隔符跨 chunk 边界（\r 收尾 + \n 开头）不得产生假事件', () async {
        final input = Stream.fromIterable([
          'data: {"i":1}\r\n\r',
          '\ndata: {"i":2}\r\n\r\n',
        ]);
        final parser = RawSseChunkParser();
        final results = await parser.parse(input).toList();

        expect(results.length, 2);
        expect(results[0].data, '{"i":1}');
        expect(results[1].data, '{"i":2}');
      });

      test(r'事件内 CRLF 多行 data 仍按 \n 拼接（SSE 规范）', () async {
        final input = Stream.fromIterable([
          'data: line1\r\ndata: line2\r\n\r\n',
        ]);
        final parser = RawSseChunkParser();
        final results = await parser.parse(input).toList();

        expect(results.length, 1);
        expect(results.first.data, 'line1\nline2');
      });

      test('流末尾无分隔符的 CRLF 残块仍可解析', () async {
        final input = Stream.fromIterable([
          'data: {"i":1}\r\n\r\ndata: {"i":2}\r\n',
        ]);
        final parser = RawSseChunkParser();
        final results = await parser.parse(input).toList();

        expect(results.length, 2);
        expect(results[1].data, '{"i":2}');
      });
    });
  });
}
