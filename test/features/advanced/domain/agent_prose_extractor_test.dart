import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/advanced/domain/services/agent_prose_extractor.dart';

void main() {
  group('AgentProseExtractor 完整到达', () {
    test(r'单次 push 提取 prose 值（含 \n 反转义）', () {
      final e = AgentProseExtractor();
      expect(e.push(r'{"prose":"第一段\n第二段"}'), '第一段\n第二段');
      expect(e.buffer, '第一段\n第二段');
    });

    test('prose 为空串：闭合但缓冲为空', () {
      final e = AgentProseExtractor();
      expect(e.push('{"prose":""}'), '');
      expect(e.buffer, '');
      expect(e.isStringClosed, isTrue);
    });
  });

  group('分片边界：转义序列跨片', () {
    test(r'\n 跨片（反斜杠单独成片）', () {
      final e = AgentProseExtractor();
      final out = [
        e.push('{"prose":"ab'),
        e.push(r'\'),
        e.push('ncd"}'),
      ].join();
      expect(out, 'ab\ncd');
    });

    test(r'\" 跨片：反转义为字面引号而非字符串闭合', () {
      final e = AgentProseExtractor();
      final out = [
        e.push('{"prose":"他说'),
        e.push(r'\'),
        e.push(r'"你好\'),
        e.push('"然后离开"}'),
      ].join();
      expect(out, '他说"你好"然后离开');
      expect(e.isStringClosed, isTrue);
    });

    test(r'\\ 跨片：反转义为单个反斜杠', () {
      final e = AgentProseExtractor();
      final out = [
        e.push('{"prose":"a'),
        e.push(r'\'),
        e.push(r'\b"}'),
      ].join();
      expect(out, r'a\b');
    });

    test(r'\uXXXX 跨片：hex 扣满 4 位才解码', () {
      final e = AgentProseExtractor();
      final out = [
        e.push(r'{"prose":"\'),
        e.push('ud83d'),
        e.push(r'\ude00!"}'),
      ].join();
      expect(out, '😀!');
    });

    test(r'\uXXXX hex 逐字符跨片', () {
      final e = AgentProseExtractor();
      final out = [
        e.push(r'{"prose":"\u4e2d'),
        e.push('文"}'),
      ].join();
      expect(out, '中文');
    });

    test(r'\u 小写 hex 解码', () {
      final e = AgentProseExtractor();
      expect(e.push(r'{"prose":"\u4e2d"}'), '中');
    });

    test(r'\t \r \b \f 与 \/ 反转义', () {
      final e = AgentProseExtractor();
      final out = e.push(r'{"prose":"a\tb\rc\/d\be\ff"}');
      expect(out, 'a\tb\rc/d\be\ff');
    });
  });

  group('分片边界：字面码点跨片', () {
    // 字面孤代理用 fromCharCode 程序化构造（源码里写 \uD83D 转义在部分
    // 工具链下不稳定，程序化构造语义也更清晰）
    final high = String.fromCharCode(0xD83D);
    final low = String.fromCharCode(0xDE00);

    test('字面代理对跨片：高代理扣住等低代理合成', () {
      final e = AgentProseExtractor();
      final out = [
        e.push('{"prose":"$high'),
        e.push('$low!")}'),
      ].join();
      expect(out, '😀!');
      expect(e.isStringClosed, isTrue);
    });

    test('孤高代理后跟普通字符：按原样吐出不吞字符', () {
      final e = AgentProseExtractor();
      final out = [
        e.push('{"prose":"$high'),
        e.push('x")}'),
      ].join();
      expect(out, '$high' 'x');
    });
  });

  group('JSON 结构跳过', () {
    test('prose 前有其他键：跳过不输出', () {
      final e = AgentProseExtractor();
      expect(e.push('{"other":123,"prose":"正文"}'), '正文');
    });

    test('prose 后有其他键：字符串闭合后丢弃', () {
      final e = AgentProseExtractor();
      expect(e.push('{"prose":"正文"}'), '正文');
      expect(e.push(',"x":1}'), '');
    });

    test('其他键的值是嵌套结构（对象/数组/字符串）：整体跳过', () {
      final e = AgentProseExtractor();
      final out = e.push(
        '{"meta":{"tags":["a","b"],"nested":{"k":"v"}},"prose":"正文"}',
      );
      expect(out, '正文');
    });

    test('嵌套结构里的 "prose" 键不误命中（只有顶层 prose 生效）', () {
      final e = AgentProseExtractor();
      final out = e.push('{"wrap":{"prose":"内层"},"prose":"外层"}');
      expect(out, '外层');
    });

    test('键名跨片：token 缓冲跨 push 持续', () {
      final e = AgentProseExtractor();
      final out = [e.push('{"pro'), e.push('se":"跨片键"}')].join();
      expect(out, '跨片键');
    });

    test('冒号跨片：afterStringToken 等待冒号到达', () {
      final e = AgentProseExtractor();
      final out = [e.push('{"prose"'), e.push(':"正文"}')].join();
      expect(out, '正文');
    });

    test('值前空白：JSON 空白分隔符跳过', () {
      final e = AgentProseExtractor();
      expect(e.push('{"prose": "正文"}'), '正文');
    });
  });

  group('尾部截断（通道 B 基础）', () {
    test('字符串中途截断：缓冲保留已提取正文且未闭合', () {
      final e = AgentProseExtractor()..push('{"prose":"写了很长的一段正');
      expect(e.buffer, '写了很长的一段正');
      expect(e.isStringClosed, isFalse);
    });

    test('截断在反斜杠上：hold-back 不产出半截转义', () {
      final e = AgentProseExtractor()
        ..push('{"prose":"正文')
        ..push(r'\');
      expect(e.buffer, '正文');
      expect(e.isStringClosed, isFalse);
    });

    test(r'截断在 \u hex 半途：未满 4 位不解码', () {
      final e = AgentProseExtractor()..push(r'{"prose":"正文\u4e2');
      expect(e.buffer, '正文');
      expect(e.isStringClosed, isFalse);
    });

    test('截断在高代理上：代理扣住不产出', () {
      final high = String.fromCharCode(0xD83D);
      final e = AgentProseExtractor()..push('{"prose":"正文$high');
      expect(e.buffer, '正文');
      expect(e.isStringClosed, isFalse);
    });
  });

  group('emoji 与 content 路径逐字符等价', () {
    test('转义代理对与字面代理对输出一致', () {
      final escaped = AgentProseExtractor().push('{"prose":"😀"}');
      final literal = AgentProseExtractor().push('{"prose":"😀"}');
      expect(escaped, literal);
      expect(escaped, '😀');
    });

    test('混合换行/引号/emoji 长文本跨片流式提取', () {
      const full = r'{"prose":"雨停了。\n他说\"你好\"，😀，然后离开。\n尾声。"}';
      const expected = '雨停了。\n他说"你好"，😀，然后离开。\n尾声。';
      final e = AgentProseExtractor();
      // 每 3 个字符切一片，覆盖所有边界组合
      final out = <String>[];
      for (var i = 0; i < full.length; i += 3) {
        final end = (i + 3 > full.length) ? full.length : i + 3;
        out.add(e.push(full.substring(i, end)));
      }
      expect(out.join(), expected);
      expect(e.buffer, expected);
      expect(e.isStringClosed, isTrue);
    });
  });
}
