import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/agent/calc/calc_eval_engine.dart';
import 'package:lmstory/core/agent/calc/calc_limits.dart';

void main() {
  const engine = CalcEvalEngine();

  group('函数参数内的千分位逗号歧义', () {
    test('无空格分隔的函数参数逗号被拒绝，不能静默拼成千分位数字', () {
      expect(
        () => engine.evaluate('max(9,100)'),
        throwsA(isA<CalcEvalException>()),
        reason: 'max(9,100) 若把逗号当千分位会静默得 9100。',
      );
      expect(
        () => engine.evaluate('min(2, max(3,100))'),
        throwsA(isA<CalcEvalException>()),
        reason: '嵌套函数内的歧义逗号同样拒绝。',
      );
      expect(
        () => engine.evaluate('max((1,234))'),
        throwsA(isA<CalcEvalException>()),
        reason: '函数内普通括号包裹的分组数字仍在函数上下文中，拒绝。',
      );
    });

    test('带空格的函数参数与函数外合法千分位保持可用', () {
      expect(engine.evaluate('max(9, 100)').exactFraction, '100');
      expect(engine.evaluate('gcd(12, 18)').exactFraction, '6');
      expect(engine.evaluate('1,234 + 1').exactFraction, '1235');
      expect(engine.evaluate('1,234,567 + 1').exactFraction, '1234568');
      expect(engine.evaluate('(1,234) + 1').exactFraction, '1235');
    });
  });

  group('数字指数字面量溢出', () {
    for (final sign in ['+', '-']) {
      test('超出整数范围的 $sign 指数报 limit_exceeded 而非回退为 0', () {
        expect(
          () => engine.evaluate('1e$sign' '999999999999999999999999'),
          throwsA(
            isA<CalcEvalException>().having(
              (error) => error.code,
              'code',
              'limit_exceeded',
            ),
          ),
        );
      });
    }

    test('指数边界按常量锁定：恰在限内可用、超限拒绝', () {
      final atLimit = engine.evaluate('1e${CalcLimits.maxDecimalExponent}');
      expect(atLimit.value.numerator.bitLength, greaterThan(33000));
      expect(
        () => engine.evaluate('1e${CalcLimits.maxDecimalExponent + 1}'),
        throwsA(
          isA<CalcEvalException>().having(
            (error) => error.code,
            'code',
            'limit_exceeded',
          ),
        ),
      );
    });

    test('正常科学计数保持精确语义', () {
      expect(engine.evaluate('1.5e-2').exactFraction, '3/200');
      expect(engine.evaluate('1e3').exactFraction, '1000');
    });
  });

  group('结果规模预检先于大分配', () {
    test('嵌套幂在分配前被位宽估算拒绝并快速失败', () {
      final sw = Stopwatch()..start();
      expect(
        () => engine.evaluate('(2^100000)^100000'),
        throwsA(
          isA<CalcEvalException>().having(
            (error) => error.code,
            'code',
            'limit_exceeded',
          ),
        ),
      );
      sw.stop();
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('合法单次幂 2^100000 仍可用（位宽与十进制位数分别锁定）', () {
      final result = engine.evaluate('2^100000');
      expect(result.value.isInteger, isTrue);
      expect(result.value.numerator.bitLength, 100001);
      // 100001 个二进制位 = 30103 个十进制位。
      expect(result.exactFraction.length, 30103);
    });

    test('幂位宽边界按上限换算锁定', () {
      // 单次幂指数上限 100000（参考语义）；结果位宽上界 =
      // 底数分子位宽 × 指数 ≤ maxBigIntBits。底数 2^100000（100001 bit）：
      // 8 次幂 = 800008 ≤ 1048576 可算，13 次幂 = 1300013 超限拒绝。
      final atEdge = engine.evaluate('(2^100000)^8');
      expect(atEdge.value.numerator.bitLength, 800001);
      expect(
        () => engine.evaluate('(2^100000)^13'),
        throwsA(
          isA<CalcEvalException>().having(
            (error) => error.code,
            'code',
            'limit_exceeded',
          ),
        ),
      );
    });

    test('大数乘积在分配前被拒绝', () {
      // 连乘 2^100000：10 个操作数 = 2^1000000（1000001 bit）仍可算
      // （第 9 次乘法前位宽和 900009+100001=1000010 ≤ 1048576）；
      // 第 10 次乘法位宽和 1000001+100001=1100002 > 1048576 被预检拒绝。
      const op = '2^100000';
      final nine = engine.evaluate('$op${' * $op' * 9}');
      expect(nine.value.numerator.bitLength, 1000001);
      expect(
        () => engine.evaluate('$op${' * $op' * 10}'),
        throwsA(
          isA<CalcEvalException>().having(
            (error) => error.code,
            'code',
            'limit_exceeded',
          ),
        ),
      );
    });

    test('fact 上限按常量锁定', () {
      final result = engine.evaluate('fact(${CalcLimits.maxFactArgument})');
      expect(result.value.isInteger, isTrue);
      expect(result.value.numerator.bitLength, greaterThan(50000));
      expect(
        () => engine.evaluate('fact(${CalcLimits.maxFactArgument + 1})'),
        throwsA(
          isA<CalcEvalException>().having(
            (error) => error.code,
            'code',
            'invalid_argument',
          ),
        ),
      );
    });
  });

  group('既有精确语义回归抽样', () {
    test('精确分数、截断、负幂与舍入语义保持', () {
      expect(engine.evaluate('0.1 + 0.2').exactFraction, '3/10');
      expect(engine.evaluate('1/3', places: 4).decimal, '0.3333');
      expect(engine.evaluate('1/3', places: 4).truncated, isTrue);
      expect(engine.evaluate('2^-2').exactFraction, '1/4');
      expect(engine.evaluate('round(-2.5)').exactFraction, '-3');
      expect(engine.evaluate('0^0').exactFraction, '1');
      expect(engine.evaluate('-7 % 3').exactFraction, '-1');
    });
  });
}
