import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/agent/calc/calc_date_engine.dart';
import 'package:lmstory/core/agent/calc/calc_limits.dart';

void main() {
  const engine = CalcDateEngine();

  group('上限边界与同日间隔', () {
    test('最大支持日期与自身求间隔为零', () {
      final result = engine.evaluate(date: '9999-12-31', to: '9999-12-31');
      expect(result.operation, 'diff');
      expect(result.data['elapsedMs'], 0);
      expect(result.data['calendar'], '0d');
    });

    test('上限边界同日带时间的反向小间隔', () {
      final result = engine.evaluate(
        date: '9999-12-31T23:59:59.999',
        to: '9999-12-31',
      );
      expect(result.data['calendar'], '-23h 59m 59s 999ms');
      expect(result.data['elapsedMs'], -86399999);
    });

    test('公元起点到 9000 年的大跨度按整年输出', () {
      final result = engine.evaluate(date: '0001-01-01', to: '9000-01-01');
      expect(result.data['calendar'], '8999y');
      expect(result.data['elapsedMs'], greaterThan(0));
    });
  });

  group('月末钳制不被后续天数覆盖', () {
    test('1 月 31 日加 1mo1d 记录钳制', () {
      final result = engine.evaluate(date: '2026-01-31', add: '1mo1d');
      expect(result.data['result'], '2026-03-01T00:00:00Z');
      expect(result.data['clamped'], isTrue);
    });

    test('纯月移位钳制与无钳制路径保持', () {
      expect(
        engine.evaluate(date: '2026-01-31', add: '1mo').data['result'],
        '2026-02-28T00:00:00Z',
      );
      expect(
        engine.evaluate(date: '2026-01-31', add: '1mo').data['clamped'],
        isTrue,
      );
      expect(
        engine.evaluate(date: '2026-01-15', add: '1y2mo3d').data['clamped'],
        isFalse,
      );
      // 减法方向同样记录钳制。
      expect(
        engine.evaluate(date: '2026-03-31', add: '-1mo').data['clamped'],
        isTrue,
      );
      // 纯天数不涉及月移位，永不钳制。
      expect(
        engine.evaluate(date: '2026-02-28', add: '1d').data['clamped'],
        isFalse,
      );
    });
  });

  group('add 与 to 组合：先加时长再求间隔', () {
    test('2026-01-31 加 1mo1d 到 2026-03-03 间隔 2 天', () {
      final result = engine.evaluate(
        date: '2026-01-31',
        add: '1mo1d',
        to: '2026-03-03',
      );
      expect(result.operation, 'add_diff');
      expect(result.data['result'], '2026-03-01T00:00:00Z');
      expect(result.data['clamped'], isTrue);
      expect(result.data['from'], '2026-03-01T00:00:00Z');
      expect(result.data['to'], '2026-03-03T00:00:00Z');
      expect(result.data['calendar'], '2d');
      expect(result.data['elapsedDays'], 2);
    });

    test('反向（加后结果晚于 to）带负号', () {
      final result = engine.evaluate(
        date: '2026-01-31',
        add: '1mo1d',
        to: '2026-02-28',
      );
      expect(result.operation, 'add_diff');
      expect(result.data['calendar'], '-1d');
      expect(result.data['elapsedMs'], -86400000);
    });

    test('纯 add 与纯 to 行为不变', () {
      expect(engine.evaluate(date: '2026-01-31', add: '1mo').operation, 'add');
      expect(
        engine.evaluate(date: '2026-01-01', to: '2026-01-02').operation,
        'diff',
      );
      expect(engine.evaluate(date: '2026-01-01').operation, 'parse');
    });
  });

  group('时间戳毫秒换算按参考 Math.round 口径', () {
    test('负半毫秒向 +Infinity 取整为 0', () {
      expect(engine.parse('-0.0005').millis, 0);
      expect(engine.parse('-0.0005').iso, '1970-01-01T00:00:00Z');
    });

    test('半值边界两侧全套', () {
      expect(engine.parse('0.0005').millis, 1);
      expect(engine.parse('-0.0015').millis, -1);
      expect(engine.parse('-0.0025').millis, -2);
      expect(engine.parse('1.5').millis, 1500);
      expect(engine.parse('-1.5').millis, -1500);
      expect(engine.parse('2.5').millis, 2500);
    });

    test('毫秒判别路径同样取整', () {
      // ≥1e11 按毫秒解释：小数部分半值向 +Infinity。
      final value = engine.parse('123456789012.5');
      expect(value.millis, 123456789013);
      expect(engine.parse('-123456789012.5').millis, -123456789012);
    });

    test('1e11 启发式与负时间戳保持', () {
      expect(engine.parse('-1000').iso, '1969-12-31T23:43:20Z');
      expect(engine.parse('100000000000').iso, '1973-03-03T09:46:40Z');
      expect(engine.parse('99999999999').iso, '5138-11-16T09:46:39Z');
    });
  });

  group('输入资源边界', () {
    test('date/add/to 超长输入报 limit_exceeded', () {
      final long = '9' * (CalcLimits.maxDateInputLength + 1);
      expect(
        () => engine.evaluate(date: long),
        throwsA(
          isA<CalcDateException>().having(
            (error) => error.code,
            'code',
            'limit_exceeded',
          ),
        ),
      );
      expect(
        () => engine.evaluate(date: '2026-01-01', add: long),
        throwsA(isA<CalcDateException>()),
      );
      expect(
        () => engine.evaluate(date: '2026-01-01', to: long),
        throwsA(isA<CalcDateException>()),
      );
    });

    test('时长分量上限按常量锁定', () {
      expect(
        () => engine.evaluate(
          date: '2026-01-01',
          add: '${CalcLimits.maxDurationComponent + 1}d',
        ),
        throwsA(
          isA<CalcDateException>().having(
            (error) => error.code,
            'code',
            'limit_exceeded',
          ),
        ),
      );
      final atLimit = engine.evaluate(
        date: '2026-01-01',
        add: '${CalcLimits.maxDurationComponent}d',
      );
      expect(atLimit.operation, 'add');
    });
  });

  group('既有语义回归抽样', () {
    test('闰年与非法日期', () {
      expect(engine.parse('2024-02-29').iso, '2024-02-29T00:00:00Z');
      expect(
        () => engine.parse('2023-02-29'),
        throwsA(
          isA<CalcDateException>().having(
            (error) => error.code,
            'code',
            'invalid_iso',
          ),
        ),
      );
    });

    test('固定偏移归一 UTC 且不支持 IANA', () {
      expect(
        engine.parse('2026-01-01T00:00:00+08:00').iso,
        '2025-12-31T16:00:00Z',
      );
      expect(
        () => engine.parse('2026-01-01T00:00:00[Asia/Shanghai]'),
        throwsA(isA<CalcDateException>()),
      );
    });

    test('无隐式当前时间', () {
      expect(
        () => engine.evaluate(date: null),
        throwsA(
          isA<CalcDateException>().having(
            (error) => error.code,
            'code',
            'missing_argument',
          ),
        ),
      );
    });

    test('间隔正反方向与日历部件', () {
      final data = engine.evaluate(date: '2026-01-01', to: '2027-03-04').data;
      expect(data['calendar'], '1y 2mo 3d');
      expect(data['elapsedDays'], 427);
      final reversed =
          engine.evaluate(date: '2027-03-04', to: '2026-01-01').data;
      expect(reversed['calendar'], '-1y 2mo 3d');
    });
  });
}
