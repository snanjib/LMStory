/// Deterministic ISO date arithmetic for the director's calc reference tool.
/// No system clock, timezone database, or locale data is consulted.
library;

import 'package:lmstory/core/agent/calc/calc_limits.dart';

const int calcDateMinYear = 1;
const int calcDateMaxYear = 9999;
const int calcDateMaxMillis = 8640000000000000;

class CalcDateException implements Exception {
  const CalcDateException(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => message;
}

class CalcDateValue {
  const CalcDateValue({required this.millis, required this.iso});
  final int millis;
  final String iso;
}

class CalcDateResult {
  const CalcDateResult({required this.operation, required this.data});
  final String operation;
  final Map<String, dynamic> data;
}

class CalcDateEngine {
  const CalcDateEngine();

  CalcDateResult evaluate({required String? date, String? add, String? to}) {
    if (date == null || date.trim().isEmpty) {
      throw const CalcDateException(
        'missing_argument',
        'date 不能为空，请传入显式 ISO 日期或 Unix 时间戳。',
      );
    }
    _guardInputLength('date', date);
    if (add != null) _guardInputLength('add', add);
    if (to != null) _guardInputLength('to', to);
    final base = parse(date);
    if (add != null) {
      final duration = parseDuration(add);
      final added = _add(base.millis, duration);
      if (to != null) {
        // 组合操作（对齐固定参考）：先加时长，再计算加后结果到 to 的间隔；
        // 月移位钳制信息保留，不被最终日期覆盖。
        final target = parse(to);
        return CalcDateResult(
          operation: 'add_diff',
          data: {
            'input': date.trim(),
            'duration': add.trim(),
            'result': _iso(added.millis),
            'clamped': added.clamped,
            'from': _iso(added.millis),
            'to': _iso(target.millis),
            ..._between(added.millis, target.millis),
          },
        );
      }
      return CalcDateResult(
        operation: 'add',
        data: {
          'input': date.trim(),
          'duration': add.trim(),
          'result': _iso(added.millis),
          'clamped': added.clamped,
        },
      );
    }
    if (to != null) {
      final target = parse(to);
      return CalcDateResult(
        operation: 'diff',
        data: {
          'from': _iso(base.millis),
          'to': _iso(target.millis),
          ..._between(base.millis, target.millis),
        },
      );
    }
    return CalcDateResult(
      operation: 'parse',
      data: {
        'input': date.trim(),
        'iso': base.iso,
        'unix': base.millis ~/ 1000,
        'unixMs': base.millis,
      },
    );
  }

  static void _guardInputLength(String field, String value) {
    if (value.length > CalcLimits.maxDateInputLength) {
      throw const CalcDateException(
        'limit_exceeded',
        '日期输入过长，date/add/to 每项不能超过 '
            '${CalcLimits.maxDateInputLength} 个字符。',
      );
    }
  }

  CalcDateValue parse(String source) {
    final text = source.trim();
    if (text.isEmpty) throw const CalcDateException('invalid_iso', '日期不能为空。');
    if (text.length > CalcLimits.maxDateInputLength) {
      throw const CalcDateException(
        'limit_exceeded',
        '日期输入过长，不能超过 ${CalcLimits.maxDateInputLength} 个字符。',
      );
    }
    if (RegExp(r'^[-+]?\d+(?:\.\d+)?$').hasMatch(text)) {
      return _parseTimestamp(text);
    }
    final match = RegExp(
      r'^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2})(?:[.,](\d{1,9}))?)?)?\s*(Z|[+-]\d{2}:?\d{2})?$',
      caseSensitive: false,
    ).firstMatch(text);
    if (match == null) {
      throw CalcDateException(
        'invalid_iso',
        '无法解析日期「${truncateForEcho(source)}」，请使用严格 ISO 形状。',
      );
    }
    final year = int.parse(match.group(1)!);
    final month = int.parse(match.group(2)!);
    final day = int.parse(match.group(3)!);
    final hour = int.parse(match.group(4) ?? '0');
    final minute = int.parse(match.group(5) ?? '0');
    final second = int.parse(match.group(6) ?? '0');
    final fraction = match.group(7) ?? '';
    final millis = int.parse('${fraction}000'.substring(0, 3));
    _validateParts(year, month, day, hour, minute, second);
    var instant = DateTime.utc(
      year,
      month,
      day,
      hour,
      minute,
      second,
      millis,
    ).millisecondsSinceEpoch;
    final zone = match.group(8);
    if (zone != null && zone.toUpperCase() != 'Z') {
      final z = RegExp(r'^([+-])(\d{2}):?(\d{2})$').firstMatch(zone)!;
      final zh = int.parse(z.group(2)!);
      final zm = int.parse(z.group(3)!);
      if (zh > 23 || zm > 59) {
        throw CalcDateException(
          'invalid_iso',
          '时区偏移无效：${truncateForEcho(zone)}。',
        );
      }
      final offset = (zh * 60 + zm) * 60000;
      instant += z.group(1) == '+' ? -offset : offset;
    }
    _checkRange(instant);
    final normalized =
        DateTime.fromMillisecondsSinceEpoch(instant, isUtc: true);
    if (normalized.year < calcDateMinYear ||
        normalized.year > calcDateMaxYear) {
      throw const CalcDateException('date_overflow', '日期超出支持范围。');
    }
    return CalcDateValue(millis: instant, iso: _iso(instant));
  }

  CalcDateValue _parseTimestamp(String source) {
    final value = num.tryParse(source);
    if (value == null || !value.isFinite) {
      throw CalcDateException(
        'invalid_timestamp',
        'Unix 时间戳无效：${truncateForEcho(source)}。',
      );
    }
    // 毫秒换算对齐固定参考的 JS Math.round（半值向 +Infinity 取整）。
    final millis =
        value.abs() < 1e11 ? _jsRound(value * 1000) : _jsRound(value);
    _checkRange(millis);
    final date = DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
    if (date.year < calcDateMinYear || date.year > calcDateMaxYear) {
      throw const CalcDateException('date_overflow', '日期超出支持范围。');
    }
    return CalcDateValue(millis: millis, iso: _iso(millis));
  }

  /// JS `Math.round` 语义：`floor(x + 0.5)`，半值向 +Infinity
  /// （Math.round(-0.5)=0、Math.round(-2.5)=-2）。仅用于时间戳毫秒换算；
  /// 算术 round 函数保持 half-away-from-zero，不混用。
  static int _jsRound(num x) => (x.toDouble() + 0.5).floor();

  CalcDateDuration parseDuration(String source) {
    var text = source.trim();
    if (text.isEmpty) {
      throw const CalcDateException('invalid_duration', '时长不能为空，请使用 1y2mo3d。');
    }
    if (text.length > CalcLimits.maxDateInputLength) {
      throw const CalcDateException(
        'limit_exceeded',
        '时长输入过长，不能超过 ${CalcLimits.maxDateInputLength} 个字符。',
      );
    }
    var sign = 1;
    if (text.startsWith('+') || text.startsWith('-')) {
      sign = text[0] == '-' ? -1 : 1;
      text = text.substring(1);
    }
    final re = RegExp(r'(\d+)(y|mo|d)', caseSensitive: false);
    var index = 0;
    var years = 0;
    var months = 0;
    var days = 0;
    var count = 0;
    while (index < text.length) {
      final m = re.matchAsPrefix(text, index);
      if (m == null) {
        throw CalcDateException(
          'invalid_duration',
          '不支持的时长「${truncateForEcho(source)}」，仅支持 y、mo、d。',
        );
      }
      final n = int.tryParse(m.group(1)!);
      if (n == null || n > CalcLimits.maxDurationComponent) {
        throw const CalcDateException('limit_exceeded', '时长数值超出范围。');
      }
      switch (m.group(2)!.toLowerCase()) {
        case 'y':
          years += n;
        case 'mo':
          months += n;
        case 'd':
          days += n;
      }
      count++;
      index = m.end;
    }
    if (count == 0) {
      throw CalcDateException('invalid_duration', '不支持的时长「$source」。');
    }
    return CalcDateDuration(years * sign, months * sign, days * sign);
  }

  /// 月移位 + 可选天数加法。返回结果毫秒与月移位步是否发生月末钳制
  /// （钳制与后续天数加法无关，不得用最终日期反推）。
  ({int millis, bool clamped}) _add(int millis, CalcDateDuration d) {
    final base = DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
    final totalMonths =
        base.year * 12 + (base.month - 1) + d.years * 12 + d.months;
    final year = totalMonths ~/ 12;
    final month = totalMonths % 12 + 1;
    if (year < calcDateMinYear || year > calcDateMaxYear) {
      throw const CalcDateException('date_overflow', '日期超出支持范围。');
    }
    final lastDay = _daysInMonth(year, month);
    final day = base.day.clamp(1, lastDay);
    final clamped = (d.years != 0 || d.months != 0) && base.day > lastDay;
    final shifted = DateTime.utc(
      year,
      month,
      day,
      base.hour,
      base.minute,
      base.second,
      base.millisecond,
    );
    final result = shifted.add(Duration(days: d.days));
    _checkRange(result.millisecondsSinceEpoch);
    if (result.year < calcDateMinYear || result.year > calcDateMaxYear) {
      throw const CalcDateException('date_overflow', '日期超出支持范围。');
    }
    return (millis: result.millisecondsSinceEpoch, clamped: clamped);
  }

  Map<String, dynamic> _between(int a, int b) {
    final sign = b < a ? -1 : 1;
    final lo = sign < 0 ? b : a;
    final hi = sign < 0 ? a : b;
    final elapsed = hi - lo;
    final start = DateTime.fromMillisecondsSinceEpoch(lo, isUtc: true);
    final end = DateTime.fromMillisecondsSinceEpoch(hi, isUtc: true);
    var months = (end.year - start.year) * 12 + end.month - start.month;
    while (months > 0 && _add(lo, CalcDateDuration(0, months, 0)).millis > hi) {
      months--;
    }
    final at = _add(lo, CalcDateDuration(0, months, 0)).millis;
    // UTC 无夏令时，整日步进是纯毫秒算术：直接整除取天数，
    // 不构造越界日期（避免 9999-12-31 的下一日触发 date_overflow）。
    final days = (hi - at) ~/ 86400000;
    final rest = hi - at - days * 86400000;
    final years = months ~/ 12;
    final remMonths = months % 12;
    final calendarParts = <String>[];
    if (years != 0) calendarParts.add('${years}y');
    if (remMonths != 0) calendarParts.add('${remMonths}mo');
    if (days != 0) calendarParts.add('${days}d');
    final hours = rest ~/ 3600000;
    final minutes = (rest % 3600000) ~/ 60000;
    final seconds = (rest % 60000) ~/ 1000;
    final ms = rest % 1000;
    if (hours != 0) calendarParts.add('${hours}h');
    if (minutes != 0) calendarParts.add('${minutes}m');
    if (seconds != 0) calendarParts.add('${seconds}s');
    if (ms != 0) calendarParts.add('${ms}ms');
    int multiplier(int x) => x * sign;
    return {
      'elapsedMs': multiplier(elapsed),
      'elapsedDays': elapsed / 86400000 * sign,
      'elapsedHours': elapsed / 3600000 * sign,
      'elapsedMinutes': elapsed / 60000 * sign,
      'elapsedSeconds': elapsed / 1000 * sign,
      'calendar': (sign < 0 ? '-' : '') +
          (calendarParts.isEmpty ? '0d' : calendarParts.join(' ')),
    };
  }

  static int _daysInMonth(int year, int month) =>
      DateTime.utc(year, month + 1, 0).day;
  static void _validateParts(
    int year,
    int month,
    int day,
    int hour,
    int minute,
    int second,
  ) {
    if (year < calcDateMinYear ||
        year > calcDateMaxYear ||
        month < 1 ||
        month > 12 ||
        day < 1 ||
        day > _daysInMonth(year, month) ||
        hour > 23 ||
        minute > 59 ||
        second > 59) {
      throw const CalcDateException('invalid_iso', '日期或时间不存在。');
    }
  }

  static void _checkRange(int millis) {
    if (millis.abs() > calcDateMaxMillis) {
      throw const CalcDateException('date_overflow', '日期超出支持范围。');
    }
  }

  static String _iso(int millis) {
    final d = DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
    String p(int n, [int width = 2]) => n.toString().padLeft(width, '0');
    final fraction = d.millisecond == 0
        ? ''
        : '.${p(d.millisecond, 3).replaceFirst(RegExp(r'0+$'), '')}';
    return '${p(d.year, 4)}-${p(d.month)}-${p(d.day)}T${p(d.hour)}:${p(d.minute)}:${p(d.second)}$fraction'
        'Z';
  }
}

class CalcDateDuration {
  const CalcDateDuration(this.years, this.months, this.days);
  final int years;
  final int months;
  final int days;
}
