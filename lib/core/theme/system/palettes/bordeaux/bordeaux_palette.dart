import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/system/lm_palette.dart';

/// 波尔多配色族 — 夜「深夜酒馆雅座」+ 日「清晨画廊白墙」。
///
/// 色相纪律：彩色槽（accent/error 之外的一切着色）硬锁 OKLCH hue 345–15；
/// 语义色（success/warning）除外；中性档容差带 330–360（chroma<0.03）。
/// 夜间 primary=柔和浅酒粉（每屏最亮元素=主操作）；日间  反转为酒药丸
/// （每屏最深=主操作）。bgGlow 是场地渐变端点，仅 backdrop 工厂消费。
class BordeauxPaletteValues {
  BordeauxPaletteValues._();

  // ── 夜间（定稿锚值原值）──────────────────────────────────────────
  // 对比度档案（WCAG 相对亮度手算，四背景=bg 0xFF150C13 / surface 0xFF221420 /
  // surfaceElevated 0xFF2B1A28 / surfaceVariant 0xFF251524）：
  //   ink 14.18-16.60 | muted 7.17-8.40 | faint 5.27-6.17 | accent 5.15-6.03
  //   success 7.05-8.26 | warning 8.20-9.61 | error 5.96-6.98
  // onPrimary #231019 对浅酒粉 primary 保持高对比；对 error 6.59、对 accent 5.69
  // （error/accent 亮填充上的深标签复用 onPrimary）。divider 对 bg 1.36（装饰性
  // 分隔，不承担组件边界语义）。白玻璃选中底（fill16/22 合成）上文字一律 ink
  // （ink 对 fill22@surfaceVariant 7.44；muted 仅 3.76 不达标）；语义@15% 横幅
  // 配对 5.11-7.45 全过；accentDim 横幅 ink 12.52 / muted 6.33 全过。
  static const bg = Color(0xFF150C13);
  static const bgGlow = Color(0xFF5C1F38);
  static const surface = Color(0xFF221420);
  static const surfaceElevated = Color(0xFF2B1A28);
  static const surfaceVariant = Color(0xFF251524);
  static const ink = Color(0xFFF5ECF2);
  static const muted = Color(0xFFB9A6B5);
  static const faint = Color(0xFFA08CA0);
  static const primary = Color(0xFFE8DCE4);
  static const primaryDim = Color(0x1AE8DCE4);
  static const onPrimary = Color(0xFF231019);
  static const accent = Color(0xFFFF4F6E);
  static const accentDim = Color(0x26FF4F6E);
  static const divider = Color(0xFF3A2438);
  // 结构分隔线：对 bg ≥3:1（语义拆分；divider 本身保持装饰性低对比）
  static const dividerStrong = Color(0xFF7A6270);
  static const success = Color(0xFF3FBF8A);
  static const warning = Color(0xFFE0B054);
  static const error = Color(0xFFFF6B7A);
  static const scrim = Color(0x99120A12);

  /// 夜间档（bgGlow=场地渐变端点，唯一消费点=backdrop 工厂）。
  static const LmPalette night = LmPalette(
    bg: bg,
    bgGlow: bgGlow,
    surface: surface,
    surfaceElevated: surfaceElevated,
    surfaceVariant: surfaceVariant,
    ink: ink,
    muted: muted,
    faint: faint,
    primary: primary,
    primaryDim: primaryDim,
    onPrimary: onPrimary,
    accent: accent,
    accentDim: accentDim,
    divider: divider,
    dividerStrong: dividerStrong,
    success: success,
    warning: warning,
    error: error,
    scrim: scrim,
  );

  // ── 日间（画廊白墙定稿，2026-09-20 P3 回填）─────────────────────
  // 对比度档案（四背景=bg 0xFFF5F2F3 / surface 0xFFFFFFFF /
  // surfaceElevated 0xFFF9F1F3 / surfaceVariant 0xFFEFE7EA）：
  //   ink 11.96-14.53 | muted 5.52-6.71 | faint 4.87-5.92 | primary 7.08-8.60
  //   accent 4.91-5.96 | success 5.07-6.16 | warning 5.24-6.36 | error 4.79-5.81
  // onPrimary #FFF5F8 对 primary 8.06、对 error 5.44、对 accent 5.59；
  // accentDim@15% 上 ink 10.44-11.52 / muted 4.82-5.32；primaryDim@10% 选中底
  // ink 10.14-11.02 / muted 4.68-5.09。全过（口径：sRGB 分段线性化+相对亮度）。
  static const dayBg = Color(0xFFF5F2F3);
  static const dayBgGlow = Color(0xFFE9D9DE);
  static const daySurface = Color(0xFFFFFFFF);
  static const daySurfaceElevated = Color(0xFFF9F1F3);
  static const daySurfaceVariant = Color(0xFFEFE7EA);
  static const dayInk = Color(0xFF3A222C);
  static const dayMuted = Color(0xFF6E5560);
  static const dayFaint = Color(0xFF745E69);
  static const dayPrimary = Color(0xFF8C2440);
  static const dayPrimaryDim = Color(0x1A8C2440);
  static const dayOnPrimary = Color(0xFFFFF5F8);
  static const dayAccent = Color(0xFFB3325A);
  static const dayAccentDim = Color(0x26B3325A);
  static const dayDivider = Color(0xFFE5D8DC);
  static const dayDividerStrong = Color(0xFF8A7580);
  static const daySuccess = Color(0xFF1B6F47);
  static const dayWarning = Color(0xFF7A5A13);
  static const dayError = Color(0xFFB83444);
  static const dayScrim = Color(0x66301E26);

  /// 日间档（极淡酒晕端点）。
  static const LmPalette day = LmPalette(
    bg: dayBg,
    bgGlow: dayBgGlow,
    surface: daySurface,
    surfaceElevated: daySurfaceElevated,
    surfaceVariant: daySurfaceVariant,
    ink: dayInk,
    muted: dayMuted,
    faint: dayFaint,
    primary: dayPrimary,
    primaryDim: dayPrimaryDim,
    onPrimary: dayOnPrimary,
    accent: dayAccent,
    accentDim: dayAccentDim,
    divider: dayDivider,
    dividerStrong: dayDividerStrong,
    success: daySuccess,
    warning: dayWarning,
    error: dayError,
    scrim: dayScrim,
  );
}

class BordeauxPaletteFamily implements LmPaletteFamily {
  const BordeauxPaletteFamily();
  @override
  String get id => 'bordeaux';
  @override
  LmPalette of(Brightness brightness) => brightness == Brightness.light
      ? BordeauxPaletteValues.day
      : BordeauxPaletteValues.night;
}
