import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/intermediate/domain/services/incremental_json_parser.dart';

/// IncrementalJsonParser 单元测试（新增）
///
/// 验证从部分 JSON 字符串中实时提取字符串字段值的能力，覆盖：
/// - 流式增量解析（字段值未闭合）
/// - 字段值已闭合（完整返回）
/// - 转义字符处理（\n \" \\ \uXXXX）
/// - 字段未出现 / 字段名漂移 / 空 JSON
void main() {
  group('IncrementalJsonParser.extractStringField', () {
    test('字段尚未出现 → 返回 null', () {
      expect(
        IncrementalJsonParser.extractStringField('{"keywords":[]}', 'draft'),
        isNull,
      );
    });

    test('字段名后只有冒号 → 返回 null（等待开引号）', () {
      expect(
        IncrementalJsonParser.extractStringField('{"draft":', 'draft'),
        isNull,
      );
    });

    test('字段值刚开始（只有开引号）→ 返回 null（无内容）', () {
      expect(
        IncrementalJsonParser.extractStringField('{"draft":"', 'draft'),
        isNull,
      );
    });

    test('字段值流式中（未闭合）→ 返回已累积部分', () {
      expect(
        IncrementalJsonParser.extractStringField(
          '{"draft":"主角来到后山',
          'draft',
        ),
        '主角来到后山',
      );
    });

    test('字段值已闭合 → 返回完整值', () {
      expect(
        IncrementalJsonParser.extractStringField(
          '{"draft":"主角来到后山","keywords":[]}',
          'draft',
        ),
        '主角来到后山',
      );
    });

    test('字段名与值之间有空白 → 正确提取', () {
      expect(
        IncrementalJsonParser.extractStringField(
          '{"draft" : "正文"',
          'draft',
        ),
        '正文',
      );
    });

    test(r'转义 \n → 换行符', () {
      expect(
        IncrementalJsonParser.extractStringField(
          r'{"draft":"第一行\n第二行"',
          'draft',
        ),
        '第一行\n第二行',
      );
    });

    test(r'转义 \" → 双引号', () {
      expect(
        IncrementalJsonParser.extractStringField(
          r'{"draft":"他说\"你好\""',
          'draft',
        ),
        '他说"你好"',
      );
    });

    test(r'转义 \\ → 反斜杠', () {
      expect(
        IncrementalJsonParser.extractStringField(
          r'{"draft":"路径C:\\Users"',
          'draft',
        ),
        r'路径C:\Users',
      );
    });

    test(r'转义 \uXXXX → Unicode 字符', () {
      expect(
        IncrementalJsonParser.extractStringField(
          r'{"draft":"\u4e2d\u6587"',
          'draft',
        ),
        '中文',
      );
    });

    test('流式末尾恰是反斜杠 → 丢弃此次累积（避免误判转义）', () {
      // 反斜杠后无字符，无法判断转义内容，应返回已累积部分（不含反斜杠）
      expect(
        IncrementalJsonParser.extractStringField(
          // ignore: use_raw_strings
          '{"draft":"正文\\',
          'draft',
        ),
        '正文',
      );
    });

    test(r'流式末尾是不完整的 \uXXXX → 返回已累积部分', () {
      expect(
        IncrementalJsonParser.extractStringField(
          r'{"draft":"正文\u4e2',
          'draft',
        ),
        '正文',
      );
    });

    test('字段在 JSON 中出现多次 → 返回第一个匹配', () {
      // 边界情况：理论上下层 schema 可能重名字段，本解析器取首个
      expect(
        IncrementalJsonParser.extractStringField(
          '{"draft":"第一个","nested":{"draft":"第二个"}}',
          'draft',
        ),
        '第一个',
      );
    });

    test('空 JSON 字符串 → 返回 null', () {
      expect(
        IncrementalJsonParser.extractStringField('', 'draft'),
        isNull,
      );
    });

    test('非 JSON 文本 → 返回 null', () {
      expect(
        IncrementalJsonParser.extractStringField('这不是 JSON', 'draft'),
        isNull,
      );
    });

    test('流式分批喂入模拟 → 每次返回当前累积值', () {
      // 模拟真实流式场景：分批喂入 JSON 字符串
      const chunks = [
        '{"draft":"',
        '主角',
        '来到',
        '后山',
        '看到',
        '古碑',
        '"',
        ',"keywords":[]}',
      ];
      final partial = StringBuffer();
      var lastValue = '';
      for (final chunk in chunks) {
        partial.write(chunk);
        final current = IncrementalJsonParser.extractStringField(
          partial.toString(),
          'draft',
        );
        if (current != null) {
          // 验证每次提取的值是已累积部分的超集
          expect(current.startsWith(lastValue), isTrue);
          lastValue = current;
        }
      }
      // 最终应得到完整值
      expect(lastValue, '主角来到后山看到古碑');
    });

    test('revise 字段（reply）流式提取', () {
      expect(
        IncrementalJsonParser.extractStringField(
          '{"reply":"最终回复内容',
          'reply',
        ),
        '最终回复内容',
      );
    });
  });
}
