import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/agent/agent_tool.dart';

void main() {
  group('parseIntegerArg 弱模型容错', () {
    test('非法类型给出可行动错误（字段名+期望类型）', () {
      final result = parseIntegerArg({'turn': 'abc'}, 'turn', min: 1);
      expect(result.value, isNull);
      expect(result.error, contains('turn'));
      expect(result.error, contains('整数'));
    });

    test('缺失且有 fallback → 用默认值', () {
      final result = parseIntegerArg({}, 'turn', min: 1, fallback: 2);
      expect(result.value, 2);
      expect(result.error, isNull);
    });

    test('数字字符串可解析', () {
      final result = parseIntegerArg({'turn': ' 3 '}, 'turn', min: 1);
      expect(result.value, 3);
    });

    test('只有 min 时越界信封不出现「null」', () {
      final result = parseIntegerArg({'turn': 0}, 'turn', min: 1);
      expect(result.value, isNull);
      expect(result.error, isNotNull);
      expect(result.error, contains('超出允许范围'));
      expect(result.error, isNot(contains('null')));
      expect(result.error, contains('不限'));
    });

    test('min+max 齐备时越界信封给出具体区间', () {
      final result = parseIntegerArg({'turn': 99}, 'turn', min: 1, max: 10);
      expect(result.value, isNull);
      expect(result.error, contains('1-10'));
    });
  });

  group('parseStringListArg 弱模型容错', () {
    test('字符串数组去空白、丢空项', () {
      expect(
        parseStringListArg(
          {
            'tags': [' 伏笔 ', '', '决裂'],
          },
          'tags',
        ),
        ['伏笔', '决裂'],
      );
    });

    test('逗号/顿号/分号分隔字符串 → 拆分', () {
      expect(
        parseStringListArg({'tags': '伏笔, 决裂、名剑；约定'}, 'tags'),
        ['伏笔', '决裂', '名剑', '约定'],
      );
    });

    test('JSON 数组字符串 → 解析', () {
      expect(
        parseStringListArg({'tags': '["伏笔","决裂"]'}, 'tags'),
        ['伏笔', '决裂'],
      );
    });

    test('缺失/空值/对象 → 空列表，不抛异常', () {
      expect(parseStringListArg({}, 'tags'), isEmpty);
      expect(parseStringListArg({'tags': '  '}, 'tags'), isEmpty);
      expect(
        parseStringListArg(
          {
            'tags': {'a': 1},
          },
          'tags',
        ),
        isEmpty,
      );
    });

    test('标量转单元素，重复项去重并保留首次顺序', () {
      expect(parseStringListArg({'tags': 42}, 'tags'), ['42']);
      expect(
        parseStringListArg(
          {
            'tags': ['a', 'b', 'a'],
          },
          'tags',
        ),
        ['a', 'b'],
      );
    });
  });
}
