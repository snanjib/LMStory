import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/network/sse/tool_call_accumulator.dart';

void main() {
  group('ToolCallAccumulator', () {
    test('完整 JSON 直接返回', () {
      const json = '{"key": "value"}';
      expect(ToolCallAccumulator.repairJson(json), json);
    });

    test('空字符串返回空对象', () {
      expect(ToolCallAccumulator.repairJson(''), '{}');
      expect(ToolCallAccumulator.repairJson('  '), '{}');
    });

    test('移除尾逗号', () {
      const json = '{"key": "value",}';
      final result = ToolCallAccumulator.repairJson(json);
      // 修复后应该是有效 JSON
      expect(result, contains('"key"'));
    });

    test('数组尾逗号', () {
      const json = '{"items": [1, 2,],}';
      final result = ToolCallAccumulator.repairJson(json);
      // 验证修复后可解析
      expect(result, isNot(contains(',]')));
      expect(result, isNot(contains(',}')));
    });

    test('自动闭合未关闭的括号', () {
      const json = '{"key": "value"';
      final result = ToolCallAccumulator.repairJson(json);
      expect(result, '{"key": "value"}');
    });

    test('自动闭合嵌套括号', () {
      const json = '{"outer": {"inner": "val"';
      final result = ToolCallAccumulator.repairJson(json);
      expect(result, '{"outer": {"inner": "val"}}');
    });

    test('自动闭合数组括号', () {
      const json = '{"items": [1, 2';
      final result = ToolCallAccumulator.repairJson(json);
      expect(result, '{"items": [1, 2]}');
    });

    test('截断字符串自动闭合', () {
      const json = '{"key": "incomplete';
      final result = ToolCallAccumulator.repairJson(json);
      expect(result, contains('"incomplete"'));
    });

    test('parseAndRepair 返回 Map', () {
      const json = '{"key": "value"';
      final result = ToolCallAccumulator.parseAndRepair(json);
      expect(result, isA<Map<String, dynamic>>());
      expect(result['key'], 'value');
    });

    test('无法修复的 JSON 返回空对象', () {
      const json = r'{@#$%}';
      final result = ToolCallAccumulator.repairJson(json);
      expect(result, '{}');
    });
  });
}
