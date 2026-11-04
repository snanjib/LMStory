import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/resource_library/domain/services/type_coercion.dart';

/// 类型容错工具单元测试（DOC-15 §5.2）
///
/// `coerceStringList` 的 Python repr 归一化
/// （单引号→双引号）此前无差别替换，值内含撇号（O'Brien）时把合法
/// JSON 撕碎、回退逗号分隔产出带括号引号的碎值。
void main() {
  group('coerceStringList', () {
    test('正常 JSON 数组（双引号）→ 逐项解析', () {
      expect(coerceStringList('["a", "b"]'), ['a', 'b']);
      expect(coerceStringList('[]'), isEmpty);
      expect(coerceStringList('  [ "x" ]  '), ['x']);
    });

    test("JSON 数组值内含撇号（O'Brien）→ 不再被撕裂", () {
      expect(coerceStringList('["O\'Brien", "x"]'), ["O'Brien", 'x']);
      expect(coerceStringList('["O\'Brien"]'), ["O'Brien"]);
    });

    test('Python repr 单引号列表（内部无撇号）→ 归一化解析', () {
      expect(coerceStringList("['a', 'b']"), ['a', 'b']);
      expect(coerceStringList("['货币汇率']"), ['货币汇率']);
    });

    test('Python repr 值内含撇号（无逃逸）→ 回退逗号分隔，不做破坏性替换', () {
      // ['O'Brien'] 不是合法 JSON 也无法安全替换——按逗号分隔兜底，
      // 不产出 ["O"Brien"] 解析失败后的碎块
      final result = coerceStringList("['O'Brien', 'x']");
      expect(result, ["['O'Brien'", "'x']"]);
    });

    test('普通逗号分隔字符串 → 拆分并去空白项', () {
      expect(coerceStringList("O'Brien, 张三 , "), ["O'Brien", '张三']);
      expect(coerceStringList('  '), isEmpty);
      expect(coerceStringList(null), isEmpty);
    });

    test('List 输入原样逐项字符串化', () {
      expect(coerceStringList([1, 'a', true]), ['1', 'a', 'true']);
    });

    test('非列表 JSON（[] 前缀但解析非数组）→ 逗号分隔兜底', () {
      // 首尾括号齐全但无法 JSON 解析：直接逗号分隔
      expect(coerceStringList('[a, b]'), ['[a', 'b]']);
    });
  });

  group('coerceBool', () {
    test('字符串布尔容错', () {
      expect(coerceBool('True'), isTrue);
      expect(coerceBool('false'), isFalse);
      expect(coerceBool(''), isFalse);
      expect(coerceBool('yes'), isTrue);
    });

    test('数字与非字符串回退', () {
      expect(coerceBool(1), isTrue);
      expect(coerceBool(0), isFalse);
      expect(coerceBool(null, fallback: true), isTrue);
    });
  });

  group('coerceString', () {
    test('null → 空串；非字符串 toString', () {
      expect(coerceString(null), '');
      expect(coerceString(42), '42');
      expect(coerceString('x'), 'x');
    });
  });
}
