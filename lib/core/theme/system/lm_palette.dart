import 'package:flutter/material.dart';

/// Stable semantic colors shared by all appearance packages.
@immutable
class LmPalette {
  const LmPalette({
    required this.bg,
    required this.surface,
    required this.surfaceElevated,
    required this.surfaceVariant,
    required this.ink,
    required this.muted,
    required this.faint,
    required this.primary,
    required this.primaryDim,
    required this.onPrimary,
    required this.accent,
    required this.accentDim,
    required this.divider,
    required this.dividerStrong,
    required this.success,
    required this.warning,
    required this.error,
    required this.scrim,
    Color? bgGlow,
  }) : _bgGlow = bgGlow;

  final Color bg;
  final Color surface;
  final Color surfaceElevated;
  final Color surfaceVariant;
  final Color ink;
  final Color muted;
  final Color faint;
  final Color primary;
  final Color primaryDim;
  final Color onPrimary;
  final Color accent;
  final Color accentDim;
  final Color divider;

  /// 结构分隔线（侧栏边界等导航结构）：对 bg ≥3:1 的可辨识台阶。
  /// 内容分隔线仍用 [divider]（装饰性，低对比）。 语义拆分。
  final Color dividerStrong;
  final Color success;
  final Color warning;
  final Color error;
  final Color scrim;
  final Color? _bgGlow;

  /// Optional backdrop decoration; absent values preserve a flat background.
  Color get bgGlow => _bgGlow ?? bg;

  LmPalette lerp(LmPalette other, double t) => LmPalette(
        bg: Color.lerp(bg, other.bg, t) ?? bg,
        surface: Color.lerp(surface, other.surface, t) ?? surface,
        surfaceElevated:
            Color.lerp(surfaceElevated, other.surfaceElevated, t) ??
                surfaceElevated,
        surfaceVariant: Color.lerp(surfaceVariant, other.surfaceVariant, t) ??
            surfaceVariant,
        ink: Color.lerp(ink, other.ink, t) ?? ink,
        muted: Color.lerp(muted, other.muted, t) ?? muted,
        faint: Color.lerp(faint, other.faint, t) ?? faint,
        primary: Color.lerp(primary, other.primary, t) ?? primary,
        primaryDim: Color.lerp(primaryDim, other.primaryDim, t) ?? primaryDim,
        onPrimary: Color.lerp(onPrimary, other.onPrimary, t) ?? onPrimary,
        accent: Color.lerp(accent, other.accent, t) ?? accent,
        accentDim: Color.lerp(accentDim, other.accentDim, t) ?? accentDim,
        divider: Color.lerp(divider, other.divider, t) ?? divider,
        dividerStrong:
            Color.lerp(dividerStrong, other.dividerStrong, t) ?? dividerStrong,
        success: Color.lerp(success, other.success, t) ?? success,
        warning: Color.lerp(warning, other.warning, t) ?? warning,
        error: Color.lerp(error, other.error, t) ?? error,
        scrim: Color.lerp(scrim, other.scrim, t) ?? scrim,
        bgGlow: Color.lerp(bgGlow, other.bgGlow, t) ?? bgGlow,
      );
}

abstract interface class LmPaletteFamily {
  String get id;
  LmPalette of(Brightness brightness);
}
