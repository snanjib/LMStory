import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/system/lm_palette.dart';

/// Classic 配色族 — 日间「Daylight」+ 夜间「夜航收编」。
///
/// Restrained color strategy: tinted neutrals + one accent ≤10%.
/// The tool disappears into the task.
///
/// 夜档为原故事模式「夜航」配色原值收编：
/// 深蓝黑底 + 单一琥珀金强调，"夜航点灯"。色值源自 OKLCH 规格（DOC-06B）。
class ClassicPaletteValues {
  ClassicPaletteValues._();

  // ── Light Theme ("Daylight") ──────────────────────────────────────
  // 背景色采用偏冷中性灰，偏离 AI 默认 cream/sand 色带（OKLCH hue 40-100）
  static const lightBg = Color(0xFFF4F5F7);
  // 场地渐变端点（唯一消费点 = GlassBackdrop）：本族冷灰自身色相
  // （OKLCH hue ≈263）低彩度加深，日间 dL −0.055 —— 「琉璃+经典」下
  // 场地可辨但不抢内容、不改变克制中性性格。
  static const lightBgGlow = Color(0xFFDDE3EE);
  static const lightSurface = Color(0xFFFFFFFF);
  static const lightSurfaceElevated = Color(0xFFEEF0F3);
  static const lightSurfaceVariant = Color(0xFFE7E9ED);
  static const lightInk = Color(0xFF22222E);
  // muted/faint 为信息文本档（WCAG AA 手算实测）：
  // muted 对四种背景 5.13-6.24:1，faint 4.55-5.70:1，全部 ≥4.5。
  static const lightMuted = Color(0xFF5F5F72);
  static const lightFaint = Color(0xFF67677A);
  static const lightPrimary = Color(0xFF4338CA);
  static const lightPrimaryDim = Color(0x1F4338CA);
  // primary 上的文字/图标前景色（7.9:1）
  static const lightOnPrimary = Color(0xFFFFFFFF);
  static const lightAccent = Color(0xFF9E7520);
  static const lightAccentDim = Color(0x1F9E7520);
  static const lightDivider = Color(0xFFDDE0E5);
  // 结构分隔线：对 bg ≥3:1（侧栏边界等导航结构， 语义拆分）
  static const lightDividerStrong = Color(0xFF757684);
  static const lightSuccess = Color(0xFF1A8A52);
  static const lightWarning = Color(0xFFA07A20);
  static const lightError = Color(0xFFB02E2E);
  static const lightScrim = Color(0x66161616);

  // ── Dark Theme（夜航收编，V3/：全局夜间基础）──────────────────
  // 对比度档案（WCAG 相对亮度手算，sRGB 分段线性化，四背景=
  // bg 0xFF0E1018 / surface 0xFF141722 / surfaceElevated 0xFF1B1E2C /
  // surfaceVariant 0xFF171A26）：
  //   ink 14.13-16.21 | muted 8.23-9.45 | faint 5.80-6.65 | primary 7.02-8.05
  //   accent 5.11-5.87 | success 6.04-6.93 | warning 8.46-9.71
  //   error 3.40-3.90（夜航原值既有属性：大红亮度高，深底上作正文不达
  //   4.5，消费面按图标/描边/配 accentDim 底使用；收编=原值，不调值）
  // onPrimary 对 primary 8.04:1（按钮前景接线随本收编生效）。
  static const darkBg = Color(0xFF0E1018);
  // 夜间场地端点：夜航深蓝黑抬升一档（OKLCH L 0.175→0.287，hue 265 同族，
  // 彩度 0.043 约为波尔多夜 0.093 的一半）——可辨而克制。
  static const darkBgGlow = Color(0xFF202A40);
  static const darkSurface = Color(0xFF141722);
  static const darkSurfaceElevated = Color(0xFF1B1E2C);
  static const darkSurfaceVariant = Color(0xFF171A26);
  static const darkInk = Color(0xFFEFEDE6);
  static const darkMuted = Color(0xFFB9B7AE);
  static const darkFaint = Color(0xFF9B9990);
  static const darkPrimary = Color(0xFFD4A042);
  static const darkPrimaryDim = Color(0x1FD4A042);
  static const darkOnPrimary = Color(0xFF14100A);
  static const darkAccent = Color(0xFFB8862E);
  static const darkAccentDim = Color(0x1FB8862E);
  static const darkDivider = Color(0xFF2A2D3A);
  static const darkDividerStrong = Color(0xFF6E7484);
  static const darkSuccess = Color(0xFF4CAF6E);
  static const darkWarning = Color(0xFFD4B842);
  static const darkError = Color(0xFFC44830);
  static const darkScrim = Color(0xB30E1018);

  // ── Semantic aliases (resolve per brightness) ─────────────────────

  /// Returns the appropriate color set for the given [Brightness].
  static LmPalette of(Brightness brightness) {
    return brightness == Brightness.light ? light : dark;
  }

  static const LmPalette light = LmPalette(
    bg: lightBg,
    bgGlow: lightBgGlow,
    surface: lightSurface,
    surfaceElevated: lightSurfaceElevated,
    surfaceVariant: lightSurfaceVariant,
    ink: lightInk,
    muted: lightMuted,
    faint: lightFaint,
    primary: lightPrimary,
    primaryDim: lightPrimaryDim,
    onPrimary: lightOnPrimary,
    accent: lightAccent,
    accentDim: lightAccentDim,
    divider: lightDivider,
    dividerStrong: lightDividerStrong,
    success: lightSuccess,
    warning: lightWarning,
    error: lightError,
    scrim: lightScrim,
  );

  static const LmPalette dark = LmPalette(
    bg: darkBg,
    bgGlow: darkBgGlow,
    surface: darkSurface,
    surfaceElevated: darkSurfaceElevated,
    surfaceVariant: darkSurfaceVariant,
    ink: darkInk,
    muted: darkMuted,
    faint: darkFaint,
    primary: darkPrimary,
    primaryDim: darkPrimaryDim,
    onPrimary: darkOnPrimary,
    accent: darkAccent,
    accentDim: darkAccentDim,
    divider: darkDivider,
    dividerStrong: darkDividerStrong,
    success: darkSuccess,
    warning: darkWarning,
    error: darkError,
    scrim: darkScrim,
  );
}

class ClassicPaletteFamily implements LmPaletteFamily {
  const ClassicPaletteFamily();
  @override
  String get id => 'classic';
  @override
  LmPalette of(Brightness brightness) => ClassicPaletteValues.of(brightness);
}
