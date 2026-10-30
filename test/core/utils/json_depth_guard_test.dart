import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/utils/json_depth_guard.dart';

/// JSON 嵌套深度守卫：资源导入与数据备份导入共用的前置粗检。
///
/// 判据：字符串感知的括号计数（字符串字面量内的括号不计）、
/// 超过 500 层即拒绝；真实卡/书/备份深度 < 20，永不误拦。
void main() {
  group('exceedsMaxDepth', () {
    test('常规 JSON 不超限', () {
      expect(
        exceedsMaxDepth('{"a":{"b":[1,2,{"c":3}]},"d":"文本"}'),
        isFalse,
      );
    });

    test('恰好 500 层不超限（边界含）', () {
      final source = '[' * 500 + ']' * 500;
      expect(exceedsMaxDepth(source), isFalse);
    });

    test('501 层超限（边界外一）', () {
      final source = '[' * 501 + ']' * 501;
      expect(exceedsMaxDepth(source), isTrue);
    });

    test('字符串字面量内的括号不计深度', () {
      final deep = '{' * 600 + '}' * 600;
      final source = '{"payload":"$deep"}';
      expect(exceedsMaxDepth(source), isFalse);
    });

    test('转义引号不提前闭合字符串', () {
      // 字符串内 \" 后接真正失控的深层括号仍在字符串内，不计深度
      final deep = '[' * 600 + ']' * 600;
      final source = '{"k":"a\\"b$deep"}';
      expect(exceedsMaxDepth(source), isFalse);
    });

    test('非 JSON 纯文本不误报', () {
      expect(exceedsMaxDepth('普通文本，无括号'), isFalse);
    });
  });
}
