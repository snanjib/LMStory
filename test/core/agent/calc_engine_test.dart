import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/agent/calc/calc_date_engine.dart';
import 'package:lmstory/core/agent/calc/calc_eval_engine.dart';
import 'package:lmstory/core/agent/calc/fraction.dart';

void main() {
  group('Fraction', () {
    test('normalizes sign and gcd', () {
      expect(Fraction(BigInt.from(2), BigInt.from(-4)).exact, '-1/2');
      expect(Fraction(BigInt.zero, BigInt.from(-4)).exact, '0');
    });
    test('rounds half away from zero', () {
      expect(
        Fraction(BigInt.from(5), BigInt.from(2)).roundHalfAwayFromZero().exact,
        '3',
      );
      expect(
        Fraction(BigInt.from(-5), BigInt.from(2)).roundHalfAwayFromZero().exact,
        '-3',
      );
    });
  });

  group('CalcEvalEngine', () {
    const engine = CalcEvalEngine();
    test('exact decimal and right associative powers', () {
      expect(engine.evaluate('0.1 + 0.2').exactFraction, '3/10');
      expect(engine.evaluate('2^3^2').exactFraction, '512');
      expect(engine.evaluate('1/3', places: 4).truncated, isTrue);
    });
    test('literals, modulo and functions', () {
      expect(engine.evaluate('0b101 + 0o7 + 0xA').exactFraction, '22');
      expect(engine.evaluate('-7 % 3').exactFraction, '-1');
      expect(engine.evaluate('round(-2.5)').exactFraction, '-3');
      expect(engine.evaluate('gcd(12, 18)').exactFraction, '6');
      expect(engine.evaluate('fact(5)').exactFraction, '120');
      expect(engine.evaluate('1,234 + 1').exactFraction, '1235');
    });
    test('rejects invalid domain', () {
      expect(
        () => engine.evaluate('1/0'),
        throwsA(
          predicate<CalcEvalException>(
            (e) => e.code == 'division_by_zero',
          ),
        ),
      );
      expect(
        () => engine.evaluate('foo(1)'),
        throwsA(
          predicate<CalcEvalException>(
            (e) => e.code == 'unknown_function',
          ),
        ),
      );
      expect(
        () => engine.evaluate('fact(-1)'),
        throwsA(
          predicate<CalcEvalException>(
            (e) => e.code == 'invalid_argument',
          ),
        ),
      );
      expect(() => engine.evaluate('1__2'), throwsA(isA<CalcEvalException>()));
    });
    test('unary sign, negative zero, negative power', () {
      expect(engine.evaluate('2^-2').exactFraction, '1/4');
      expect(engine.evaluate('-0').exactFraction, '0');
      expect(engine.evaluate('0^0').exactFraction, '1');
      expect(engine.evaluate('-(1+2)*3').exactFraction, '-9');
    });
    test('thousands separators accept only complete 3-digit groups', () {
      expect(engine.evaluate('1,234,567 + 1').exactFraction, '1234568');
      expect(() => engine.evaluate('12,34'), throwsA(isA<CalcEvalException>()));
      expect(
        () => engine.evaluate('1234,567'),
        throwsA(isA<CalcEvalException>()),
      );
    });
    test('resource limits reject over-deep and over-long input', () {
      final deep = '${'(' * 100}1${')' * 100}';
      expect(
        () => engine.evaluate(deep),
        throwsA(
          predicate<CalcEvalException>((e) => e.code == 'limit_exceeded'),
        ),
      );
      expect(
        () => engine.evaluate('1+1', places: 1001),
        throwsA(
          predicate<CalcEvalException>((e) => e.code == 'limit_exceeded'),
        ),
      );
    });
  });

  group('CalcDateEngine', () {
    const engine = CalcDateEngine();
    test('strict date parse and month clamp', () {
      expect(
        engine.evaluate(date: '2026-01-31', add: '1mo').data['result'],
        '2026-02-28T00:00:00Z',
      );
      expect(
        engine.evaluate(date: '2026-01-31', add: '1mo').data['clamped'],
        isTrue,
      );
      expect(
        () => engine.parse('2026-02-30'),
        throwsA(
          predicate<CalcDateException>((e) => e.code == 'invalid_iso'),
        ),
      );
    });
    test('leap year february validity', () {
      expect(engine.parse('2024-02-29').iso, '2024-02-29T00:00:00Z');
      expect(
        () => engine.parse('2023-02-29'),
        throwsA(
          predicate<CalcDateException>((e) => e.code == 'invalid_iso'),
        ),
      );
    });
    test('timestamps follow the 1e11 heuristic and accept negatives', () {
      expect(engine.parse('-1000').iso, '1969-12-31T23:43:20Z');
      // 1e11 恰在边界之上 → 按毫秒解释
      expect(engine.parse('100000000000').iso, '1973-03-03T09:46:40Z');
      // 边界之下按秒解释（结果年份仍在 1..9999）
      expect(engine.parse('99999999999').iso, '5138-11-16T09:46:39Z');
      expect(
        () => engine.parse('99999999999999999999'),
        throwsA(
          predicate<CalcDateException>((e) => e.code == 'date_overflow'),
        ),
      );
    });
    test('add supports multi-unit durations and subtraction', () {
      expect(
        engine.evaluate(date: '2026-01-15', add: '1y2mo3d').data['result'],
        '2027-03-18T00:00:00Z',
      );
      expect(
        engine.evaluate(date: '2026-03-10', add: '-1mo').data['result'],
        '2026-02-10T00:00:00Z',
      );
      expect(
        () => engine.evaluate(date: '2026-01-01', add: '1w'),
        throwsA(
          predicate<CalcDateException>(
            (e) => e.code == 'invalid_duration',
          ),
        ),
      );
      expect(
        () => engine.evaluate(date: '2026-01-01', add: '3h 4m'),
        throwsA(
          predicate<CalcDateException>(
            (e) => e.code == 'invalid_duration',
          ),
        ),
      );
    });
    test('explicit fixed offsets normalize to UTC; IANA rejected', () {
      expect(
        engine.parse('2026-01-01T00:00:00+08:00').iso,
        '2025-12-31T16:00:00Z',
      );
      expect(engine.parse('2026-01-01T00:00:00Z').iso, '2026-01-01T00:00:00Z');
      expect(
        () => engine.parse('2026-01-01T00:00:00[Asia/Shanghai]'),
        throwsA(
          predicate<CalcDateException>((e) => e.code == 'invalid_iso'),
        ),
      );
      expect(
        () => engine.parse('2026-01-01T00:00:00+99:00'),
        throwsA(
          predicate<CalcDateException>((e) => e.code == 'invalid_iso'),
        ),
      );
    });
    test('interval has elapsed and calendar forms', () {
      final data = engine.evaluate(date: '2026-01-01', to: '2027-03-04').data;
      expect(data['calendar'], '1y 2mo 3d');
      expect(data['elapsedDays'], 427);
      final reversed =
          engine.evaluate(date: '2027-03-04', to: '2026-01-01').data;
      expect(reversed['calendar'], '-1y 2mo 3d');
      expect(reversed['elapsedDays'], -427);
    });
    test('no implicit now', () {
      expect(
        () => engine.evaluate(date: null),
        throwsA(
          predicate<CalcDateException>(
            (e) => e.code == 'missing_argument',
          ),
        ),
      );
    });
  });

  // 主控复审保护断言（原 6 红 2 绿迁入；判据不变，修复后应全绿）。
  // 来源证据：仓外 calc_subagent_regression_test.dart 与
  // calc_subagent_regression.log（歧义逗号、正/负大指数、最大日期自间隔、
  // clamped、research 出站六项当时失败；普通 max/千分位与 plain/候选过滤
  // 两项当时通过）。子代理两项已随 research 白名单修复迁入
  // agent_subagent_test.dart 的真实路由与过滤边界测试。
  group('主控复审保护断言', () {
    const engine = CalcEvalEngine();
    const dates = CalcDateEngine();

    test('歧义函数逗号被拒绝（不得静默得 9100）', () {
      expect(
        () => engine.evaluate('max(9,100)'),
        throwsA(isA<CalcEvalException>()),
      );
    });

    for (final sign in ['+', '-']) {
      test('超大 $sign 科学计数指数报 limit_exceeded', () {
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

    test('最大日期自间隔为零', () {
      final result = dates.evaluate(date: '9999-12-31', to: '9999-12-31');
      expect(result.operation, 'diff');
      expect(result.data['elapsedMs'], 0);
      expect(result.data['calendar'], '0d');
    });

    test('月末钳制在天数加法后仍被记录', () {
      final result = dates.evaluate(date: '2026-01-31', add: '1mo1d');
      expect(result.data['result'], '2026-03-01T00:00:00Z');
      expect(result.data['clamped'], isTrue);
    });

    test('无歧义函数参数与千分位分组仍可用', () {
      expect(engine.evaluate('max(9, 100)').exactFraction, '100');
      expect(engine.evaluate('1,234 + 1').exactFraction, '1235');
    });
  });
}
