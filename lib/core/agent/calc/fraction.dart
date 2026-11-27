import 'dart:core';

import 'package:lmstory/core/agent/calc/calc_limits.dart';
import 'package:meta/meta.dart';

/// Exact rational number backed by arbitrary precision integers.
@immutable
class Fraction implements Comparable<Fraction> {
  Fraction(BigInt numerator, [BigInt? denominator])
      : numerator = _normalizeNumerator(numerator, denominator ?? BigInt.one),
        denominator =
            _normalizeDenominator(numerator, denominator ?? BigInt.one);

  Fraction.fromInt(int value) : this(BigInt.from(value));

  final BigInt numerator;
  final BigInt denominator;

  /// Short aliases useful when mirroring the reference implementation.
  BigInt get n => numerator;
  BigInt get d => denominator;

  static BigInt _normalizeNumerator(BigInt n, BigInt d) {
    if (d == BigInt.zero) {
      throw const FractionException('division_by_zero', '分母不能为零');
    }
    var numerator = n;
    var denominator = d;
    if (denominator.isNegative) {
      numerator = -numerator;
      denominator = -denominator;
    }
    final g = _gcd(numerator.abs(), denominator);
    return numerator ~/ g;
  }

  static BigInt _normalizeDenominator(BigInt n, BigInt d) {
    if (d == BigInt.zero) {
      throw const FractionException('division_by_zero', '分母不能为零');
    }
    final denominator = d.isNegative ? -d : d;
    return denominator ~/ _gcd(n.abs(), denominator);
  }

  static BigInt _gcd(BigInt a, BigInt b) {
    var x = a;
    var y = b;
    while (y != BigInt.zero) {
      final t = x % y;
      x = y;
      y = t;
    }
    return x == BigInt.zero ? BigInt.one : x;
  }

  /// 分配前预检两个 BigInt 乘积位宽：bitLength 之和是乘积位宽的上界，
  /// 超出 [CalcLimits.maxBigIntBits] 时快速拒绝，避免大分配后才失败。
  static void _guardProductBits(BigInt a, BigInt b) {
    if (a.bitLength + b.bitLength > CalcLimits.maxBigIntBits) {
      throw const FractionException(
        'limit_exceeded',
        '中间结果的整数位数超出上限，请缩小参与运算的数值规模。',
      );
    }
  }

  Fraction add(Fraction other) {
    _guardProductBits(numerator, other.denominator);
    _guardProductBits(other.numerator, denominator);
    return Fraction(
      numerator * other.denominator + other.numerator * denominator,
      denominator * other.denominator,
    );
  }

  Fraction sub(Fraction other) => subtract(other);
  Fraction mul(Fraction other) => multiply(other);
  Fraction div(Fraction other) => divide(other);

  Fraction subtract(Fraction other) {
    _guardProductBits(numerator, other.denominator);
    _guardProductBits(other.numerator, denominator);
    return Fraction(
      numerator * other.denominator - other.numerator * denominator,
      denominator * other.denominator,
    );
  }

  Fraction multiply(Fraction other) {
    _guardProductBits(numerator, other.numerator);
    _guardProductBits(denominator, other.denominator);
    return Fraction(
      numerator * other.numerator,
      denominator * other.denominator,
    );
  }

  Fraction divide(Fraction other) {
    if (other.numerator == BigInt.zero) {
      throw const FractionException('division_by_zero', '除数不能为零');
    }
    _guardProductBits(numerator, other.denominator);
    _guardProductBits(denominator, other.numerator);
    return Fraction(
      numerator * other.denominator,
      denominator * other.numerator,
    );
  }

  /// Remainder using truncation toward zero, matching JavaScript `%`.
  Fraction mod(Fraction other) {
    if (other.numerator == BigInt.zero) {
      throw const FractionException('division_by_zero', '除数不能为零');
    }
    _guardProductBits(numerator, other.denominator);
    _guardProductBits(denominator, other.numerator);
    final q =
        (numerator * other.denominator) ~/ (denominator * other.numerator);
    return subtract(other.multiply(Fraction(q)));
  }

  Fraction pow(BigInt exponent) {
    if (exponent.abs() > BigInt.from(CalcLimits.maxPowExponent)) {
      throw const FractionException(
        'limit_exceeded',
        '幂指数绝对值不能超过 ${CalcLimits.maxPowExponent}',
      );
    }
    if (exponent == BigInt.zero) return Fraction(BigInt.one);
    final exp = exponent.abs().toInt();
    // 结果位宽上界 = 底数分子/分母位宽 × 指数；分配前估算并拒绝。
    if (numerator.abs().bitLength * exp > CalcLimits.maxBigIntBits ||
        denominator.bitLength * exp > CalcLimits.maxBigIntBits) {
      throw const FractionException(
        'limit_exceeded',
        '幂结果的整数位数超出上限，请降低指数或缩小底数。',
      );
    }
    var n = numerator.abs() == BigInt.zero && exponent.isNegative
        ? BigInt.zero
        : numerator.abs().pow(exp);
    final d = denominator.pow(exp);
    if (numerator.isNegative && exponent.isOdd) n = -n;
    if (exponent.isNegative) {
      if (n == BigInt.zero) {
        throw const FractionException('division_by_zero', '零不能取负幂');
      }
      return Fraction(d, n);
    }
    return Fraction(n, d);
  }

  Fraction negate() => Fraction(-numerator, denominator);
  Fraction neg() => negate();
  Fraction abs() => numerator.isNegative ? negate() : this;
  bool get isInteger => denominator == BigInt.one;
  bool get isInt => isInteger;
  bool get isZero => numerator == BigInt.zero;

  Fraction floor() {
    var q = numerator ~/ denominator;
    if (numerator.isNegative && q * denominator != numerator) q -= BigInt.one;
    return Fraction(q);
  }

  Fraction ceil() => negate().floor().negate();
  Fraction trunc() => numerator.isNegative ? ceil() : floor();

  Fraction roundHalfAwayFromZero() {
    final a = abs();
    final q = a.numerator ~/ a.denominator;
    final r = a.numerator % a.denominator;
    final rounded = r * BigInt.two >= a.denominator ? q + BigInt.one : q;
    final out = Fraction(rounded);
    return numerator.isNegative ? out.negate() : out;
  }

  String get exact =>
      isInteger ? numerator.toString() : '$numerator/$denominator';

  DecimalResult decimal([int places = 20]) {
    if (places < 0 || places > 1000) {
      throw const FractionException('limit_exceeded', '小数位数必须在 0 到 1000 之间');
    }
    // 分子 × 10^places 的位宽预检（log2(10) < 4，用 places × 4 做上界）。
    if (numerator.abs().bitLength + places * 4 > CalcLimits.maxBigIntBits) {
      throw const FractionException(
        'limit_exceeded',
        '十进制展开的位数超出上限，请降低 places 或缩小数值。',
      );
    }
    final negative = numerator.isNegative;
    final absNumerator = numerator.abs();
    final scale = BigInt.from(10).pow(places);
    var q = (absNumerator * scale) ~/ denominator;
    final remainder = (absNumerator * scale) % denominator;
    if (remainder * BigInt.two >= denominator) q += BigInt.one;
    final digits = q.toString().padLeft(places + 1, '0');
    final whole =
        places == 0 ? digits : digits.substring(0, digits.length - places);
    final frac = places == 0
        ? ''
        : digits
            .substring(digits.length - places)
            .replaceFirst(RegExp(r'0+$'), '');
    final text = frac.isEmpty ? whole : '$whole.$frac';
    return DecimalResult(
      text: negative && q != BigInt.zero ? '-$text' : text,
      truncated: remainder != BigInt.zero,
    );
  }

  @override
  int compareTo(Fraction other) =>
      (numerator * other.denominator).compareTo(other.numerator * denominator);

  @override
  bool operator ==(Object other) =>
      other is Fraction &&
      numerator == other.numerator &&
      denominator == other.denominator;

  @override
  int get hashCode => Object.hash(numerator, denominator);

  @override
  String toString() => exact;
}

class DecimalResult {
  const DecimalResult({required this.text, required this.truncated});
  final String text;
  final bool truncated;
}

class FractionException implements Exception {
  const FractionException(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => message;
}
