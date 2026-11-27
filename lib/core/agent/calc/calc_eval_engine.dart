import 'package:lmstory/core/agent/calc/calc_limits.dart';
import 'package:lmstory/core/agent/calc/fraction.dart';

class CalcEvalResult {
  const CalcEvalResult({required this.value, required this.places});
  final Fraction value;
  final int places;
  String get exactFraction => value.exact;
  String get decimal => value.decimal(places).text;
  bool get truncated => value.decimal(places).truncated;
}

class CalcEvalException implements Exception {
  const CalcEvalException(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => message;
}

class CalcEvalEngine {
  const CalcEvalEngine();

  CalcEvalResult evaluate(String source, {int places = 20}) {
    if (source.length > CalcLimits.maxExpressionLength) {
      throw const CalcEvalException('limit_exceeded', '表达式过长，请缩短后重试。');
    }
    if (places < 0 || places > 1000) {
      throw const CalcEvalException(
        'limit_exceeded',
        'places 必须在 0 到 1000 之间。',
      );
    }
    try {
      final parser = _Parser(source);
      final value = parser.parse();
      return CalcEvalResult(value: value, places: places);
    } on CalcEvalException {
      rethrow;
    } on FractionException catch (e) {
      throw CalcEvalException(e.code, e.message);
    } catch (_) {
      // 兜底不外泄 Dart 异常原文（信封面向模型，须中文可操作）；
      // 具体解析失败均已在词法/语法层以中文 _fail 分类。
      throw const CalcEvalException(
        'invalid_expression',
        '表达式无法解析，请检查括号、运算符与数字写法后重试。',
      );
    }
  }
}

enum _TokenType { number, name, op, leftParen, rightParen, comma, eof }

class _Token {
  const _Token(this.type, this.text, {this.grouped = false});
  final _TokenType type;
  final String text;

  /// 数字 token 是否含被词法层吞并的千分位逗号（用于函数参数歧义预检）。
  final bool grouped;
}

class _Parser {
  _Parser(String source) : _tokens = _Lexer(source).scan();
  final List<_Token> _tokens;
  int _index = 0;
  int _depth = 0;

  /// 当前是否处于函数调用括号内（含嵌套）：此上下文中的千分位逗号
  /// 与参数分隔逗号不可区分，含分组逗号的数字必须拒绝。
  int _functionArgDepth = 0;

  _Token get _peek => _tokens[_index];
  bool _take(String text) {
    if (_peek.text == text) {
      _index++;
      return true;
    }
    return false;
  }

  Fraction parse() {
    if (_peek.type == _TokenType.eof) _fail('invalid_expression', '表达式不能为空。');
    final value = _expr();
    if (_peek.type != _TokenType.eof) {
      _fail('invalid_expression', '无法解析「${truncateForEcho(_peek.text)}」。');
    }
    return value;
  }

  Fraction _expr() {
    var value = _term();
    while (true) {
      if (_take('+')) {
        value = value.add(_term());
      } else if (_take('-')) {
        value = value.subtract(_term());
      } else {
        return value;
      }
    }
  }

  Fraction _term() {
    var value = _unary();
    while (true) {
      if (_take('*')) {
        value = value.multiply(_unary());
      } else if (_take('/')) {
        value = value.divide(_unary());
      } else if (_take('%')) {
        value = value.mod(_unary());
      } else {
        return value;
      }
    }
  }

  Fraction _unary() {
    if (_take('-')) return _unary().negate();
    if (_take('+')) return _unary();
    return _power();
  }

  Fraction _power() {
    final value = _atom();
    if (_take('^') || _take('**')) {
      final exponent = _unary();
      if (!exponent.isInteger) _fail('invalid_expression', '幂指数必须是整数。');
      return value.pow(exponent.numerator);
    }
    return value;
  }

  Fraction _atom() {
    if (++_depth > CalcLimits.maxDepth) _fail('limit_exceeded', '表达式嵌套过深。');
    try {
      final token = _peek;
      if (token.type == _TokenType.number) {
        if (token.grouped && _functionArgDepth > 0) {
          _fail(
            'invalid_expression',
            '函数参数内不能使用千分位逗号（与参数分隔逗号存在歧义）：'
                '请把数字写成不含逗号的形式（如 9100），或多参数用「, 」（逗号后加空格）分隔。',
          );
        }
        _index++;
        return _parseNumber(token.text);
      }
      if (_take('(')) {
        final value = _expr();
        if (!_take(')')) _fail('invalid_expression', '缺少右括号。');
        return value;
      }
      if (token.type == _TokenType.name) {
        _index++;
        final name = token.text.toLowerCase();
        if (!_take('(')) _fail('invalid_expression', '函数 $name 后需要左括号。');
        _functionArgDepth++;
        final args = <Fraction>[];
        if (!_take(')')) {
          args.add(_expr());
          while (_take(',')) {
            args.add(_expr());
          }
          if (!_take(')')) _fail('invalid_expression', '函数 $name 缺少右括号。');
        }
        _functionArgDepth--;
        return _call(name, args);
      }
      _fail('invalid_expression', '表达式在此处不完整。');
    } finally {
      _depth--;
    }
  }

  Fraction _call(String name, List<Fraction> args) {
    const unary = {'abs', 'floor', 'ceil', 'round', 'trunc', 'fact'};
    const variadic = {'min', 'max', 'gcd', 'lcm'};
    if (!unary.contains(name) && !variadic.contains(name)) {
      _fail(
        'unknown_function',
        '不支持函数 ${truncateForEcho(name)}。可用：abs、floor、ceil、round、trunc、min、max、gcd、lcm、fact。',
      );
    }
    if (unary.contains(name) && args.length != 1) {
      _fail('invalid_argument', '$name 需要且只能需要一个参数。');
    }
    if (variadic.contains(name) && args.isEmpty) {
      _fail('invalid_argument', '$name 至少需要一个参数。');
    }
    switch (name) {
      case 'abs':
        return args.single.abs();
      case 'floor':
        return args.single.floor();
      case 'ceil':
        return args.single.ceil();
      case 'round':
        return args.single.roundHalfAwayFromZero();
      case 'trunc':
        return args.single.trunc();
      case 'min':
        return args.reduce((a, b) => a.compareTo(b) <= 0 ? a : b);
      case 'max':
        return args.reduce((a, b) => a.compareTo(b) >= 0 ? a : b);
      case 'gcd':
        if (args.any((a) => !a.isInteger)) {
          _fail('invalid_argument', 'gcd 只接受整数。');
        }
        return Fraction(args.map((a) => a.numerator.abs()).reduce(_gcd));
      case 'lcm':
        if (args.any((a) => !a.isInteger)) {
          _fail('invalid_argument', 'lcm 只接受整数。');
        }
        var result = BigInt.one;
        for (final arg in args) {
          final n = arg.numerator.abs();
          if (result == BigInt.zero || n == BigInt.zero) {
            result = BigInt.zero;
          } else {
            if (result.bitLength + n.bitLength > CalcLimits.maxBigIntBits) {
              _fail('limit_exceeded', 'lcm 结果的整数位数超出上限。');
            }
            result = (result * n) ~/ _gcd(result, n);
          }
        }
        return Fraction(result);
      case 'fact':
        final n = args.single.numerator;
        if (!args.single.isInteger ||
            n.isNegative ||
            n > BigInt.from(CalcLimits.maxFactArgument)) {
          _fail(
            'invalid_argument',
            'fact 只接受 0 到 ${CalcLimits.maxFactArgument} 的整数。',
          );
        }
        var result = BigInt.one;
        for (var i = BigInt.two; i <= n; i += BigInt.one) {
          result *= i;
        }
        return Fraction(result);
    }
    throw StateError('unreachable function');
  }

  Fraction _parseNumber(String source) {
    if (source.contains('_') && !_validUnderscores(source)) {
      _fail('invalid_number', '数字分隔符 _ 必须位于数字之间，不能连续或贴近小数点/指数。');
    }
    final text = source.replaceAll('_', '');
    try {
      final sign = text.startsWith('-') ? -1 : 1;
      final unsigned = (text.startsWith('+') || text.startsWith('-'))
          ? text.substring(1)
          : text;
      if (RegExp(r'^0[xX][0-9a-fA-F]+$').hasMatch(unsigned)) {
        return Fraction(
          BigInt.parse(unsigned.substring(2), radix: 16) * BigInt.from(sign),
        );
      }
      if (RegExp(r'^0[bB][01]+$').hasMatch(unsigned)) {
        return Fraction(
          BigInt.parse(unsigned.substring(2), radix: 2) * BigInt.from(sign),
        );
      }
      if (RegExp(r'^0[oO][0-7]+$').hasMatch(unsigned)) {
        return Fraction(
          BigInt.parse(unsigned.substring(2), radix: 8) * BigInt.from(sign),
        );
      }
      final match = RegExp(r'^(\d*)(?:\.(\d*))?(?:[eE]([+-]?\d+))?$')
          .firstMatch(unsigned);
      if (match == null ||
          (match.group(1)!.isEmpty && (match.group(2) ?? '').isEmpty)) {
        _fail('invalid_number', '无法解析数字「${truncateForEcho(source)}」。');
      }
      final whole = match.group(1) ?? '';
      final fraction = match.group(2) ?? '';
      var numerator = BigInt.parse((whole.isEmpty ? '0' : whole) + fraction);
      var denominator = BigInt.from(10).pow(fraction.length);
      final exponentText = match.group(3);
      var exponent = 0;
      if (exponentText != null) {
        final parsed = int.tryParse(exponentText);
        if (parsed == null) {
          _fail(
            'limit_exceeded',
            '数字指数超出整数范围，绝对值不能超过 ${CalcLimits.maxDecimalExponent}，请改写为更小的指数。',
          );
        }
        exponent = parsed;
      }
      if (exponent.abs() > CalcLimits.maxDecimalExponent) {
        _fail(
          'limit_exceeded',
          '数字指数绝对值不能超过 ${CalcLimits.maxDecimalExponent}。',
        );
      }
      if (exponent > 0) numerator *= BigInt.from(10).pow(exponent);
      if (exponent < 0) denominator *= BigInt.from(10).pow(-exponent);
      return Fraction(BigInt.from(sign) * numerator, denominator);
    } on FormatException {
      _fail('invalid_number', '无法解析数字「${truncateForEcho(source)}」。');
    }
  }

  bool _validUnderscores(String source) {
    final unsigned = (source.startsWith('+') || source.startsWith('-'))
        ? source.substring(1)
        : source;
    final base = RegExp(r'^0[xX]([0-9a-fA-F_]+)$').firstMatch(unsigned) ??
        RegExp(r'^0[bB]([01_]+)$').firstMatch(unsigned) ??
        RegExp(r'^0[oO]([0-7_]+)$').firstMatch(unsigned);
    if (base != null) {
      return _validDigitGroup(
        base.group(1)!,
        hexadecimal: unsigned.startsWith('0x') || unsigned.startsWith('0X'),
      );
    }
    final decimal = RegExp(
      r'^(\d*)(?:\.(\d*))?(?:[eE]([+-]?\d+))?$',
    ).firstMatch(unsigned);
    if (decimal == null) return false;
    return _validDigitGroup(decimal.group(1)!) &&
        _validDigitGroup(decimal.group(2) ?? '') &&
        _validDigitGroup(decimal.group(3) ?? '');
  }

  bool _validDigitGroup(String group, {bool hexadecimal = false}) {
    if (group.isEmpty) return true;
    if (group.startsWith('_') || group.endsWith('_') || group.contains('__')) {
      return false;
    }
    for (var i = 0; i < group.length; i++) {
      final digitPattern =
          hexadecimal ? RegExp('[0-9a-fA-F]') : RegExp('[0-9]');
      if (group[i] == '_' &&
          (!digitPattern.hasMatch(group[i - 1]) ||
              !digitPattern.hasMatch(group[i + 1]))) {
        return false;
      }
    }
    return true;
  }

  static BigInt _gcd(BigInt a, BigInt b) {
    var x = a;
    var y = b;
    while (y != BigInt.zero) {
      final t = x % y;
      x = y;
      y = t;
    }
    return x.abs();
  }

  Never _fail(String code, String message) =>
      throw CalcEvalException(code, message);
}

class _Lexer {
  _Lexer(this.source);
  final String source;

  List<_Token> scan() {
    final out = <_Token>[];
    var i = 0;
    while (i < source.length) {
      final c = source[i];
      if (RegExp(r'\s').hasMatch(c)) {
        i++;
        continue;
      }
      if (_isDigit(c) || c == '.') {
        final start = i;
        if (source.startsWith('0x', i) ||
            source.startsWith('0X', i) ||
            source.startsWith('0b', i) ||
            source.startsWith('0B', i) ||
            source.startsWith('0o', i) ||
            source.startsWith('0O', i)) {
          i += 2;
          while (
              i < source.length && RegExp('[0-9a-fA-F_]').hasMatch(source[i])) {
            i++;
          }
        } else {
          while (
              i < source.length && (_isDigit(source[i]) || source[i] == '_')) {
            i++;
          }
          final firstGroupLength = i - start;
          while (firstGroupLength <= 3 &&
              i + 3 < source.length &&
              source[i] == ',' &&
              _isDigit(source[i + 1]) &&
              _isDigit(source[i + 2]) &&
              _isDigit(source[i + 3]) &&
              (i + 4 >= source.length || !_isDigit(source[i + 4]))) {
            i += 4;
            while (i < source.length &&
                (_isDigit(source[i]) || source[i] == '_')) {
              i++;
            }
          }
          if (i < source.length && source[i] == '.') {
            i++;
            while (i < source.length &&
                (_isDigit(source[i]) || source[i] == '_')) {
              i++;
            }
          }
          if (i < source.length && (source[i] == 'e' || source[i] == 'E')) {
            i++;
            if (i < source.length && (source[i] == '+' || source[i] == '-')) {
              i++;
            }
            while (i < source.length && _isDigit(source[i])) {
              i++;
            }
          }
        }
        var text = source.substring(start, i);
        final grouped = text.contains(',');
        if (grouped) text = text.replaceAll(',', '');
        out.add(_Token(_TokenType.number, text, grouped: grouped));
      } else if (_isName(c)) {
        final start = i++;
        while (i < source.length && _isName(source[i])) {
          i++;
        }
        out.add(
          _Token(_TokenType.name, source.substring(start, i).toLowerCase()),
        );
      } else if (source.startsWith('**', i)) {
        out.add(const _Token(_TokenType.op, '**'));
        i += 2;
      } else {
        final token = switch (c) {
          '(' => const _Token(_TokenType.leftParen, '('),
          ')' => const _Token(_TokenType.rightParen, ')'),
          ',' => const _Token(_TokenType.comma, ','),
          _ => _Token(_TokenType.op, c),
        };
        out.add(token);
        i++;
      }
      if (out.length > CalcLimits.maxTokens) {
        throw const CalcEvalException('limit_exceeded', '表达式 token 数过多。');
      }
    }
    out.add(const _Token(_TokenType.eof, ''));
    return out;
  }

  static bool _isDigit(String c) =>
      c.codeUnitAt(0) >= 48 && c.codeUnitAt(0) <= 57;
  static bool _isName(String c) => RegExp('[A-Za-z_]').hasMatch(c);
}
