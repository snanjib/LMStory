import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/system/lm_ui_text_styles.dart'
    show LmUiTextStyles;

/// 琉璃字体三层语法：UI 层 / 技术字幕层（mono）/ 品牌时刻层。
///
/// - UI 层＝Inter（pubspec 打包）+ 系统 CJK 回退，字重仅 400/500/600，
///   字号沿用捕获阶梯 11/12/14/15/16/18/22/28（复用 [LmUiTextStyles]）。
/// - 技术字幕层＝LMMono（打包子集）：全大写（仅拉丁）、宽字距 0.15-0.25em、
///   `//` 分隔语法；版本号/模型 ID/状态标签/分区头；默认 muted、活动 accent。
/// - 品牌时刻层＝表现性字效，全 app 仅启动/关于页一处（accent 字 + glow），
///   禁渐变文字。
/// - 阅读字体槽：琉璃结构正文＝UI sans（圆润无衬线锚定）。
abstract final class GlassTextStyles {
  GlassTextStyles._();

  /// 技术字幕层族名（打包子集）。
  static const String monoFamily = 'LMMono';

  /// UI sans（与 Classic 共享 Inter）。
  static const String sansFamily = 'Inter';

  // ── 技术字幕层 ─────────────────────────────────────────────────────

  /// 状态标签/区块 meta：11px / 500 / 宽字距 0.15em（≈1.65 逻辑像素）。
  static const TextStyle metaCaps = TextStyle(
    fontFamily: monoFamily,
    fontSize: 11,
    fontWeight: FontWeight.w500,
    height: 1.35,
    letterSpacing: 1.65,
  );

  /// 模型 ID/端口/路径/版本号：12px / 400 / 字距 0.15em；数字 tabular。
  static const TextStyle metaValue = TextStyle(
    fontFamily: monoFamily,
    fontSize: 12,
    fontWeight: FontWeight.w400,
    height: 1.4,
    letterSpacing: 1.8,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  /// 分区头：11px / 500 / 宽字距 0.25em（≈2.75），`//` 前缀语法由消费面拼。
  static const TextStyle sectionHeader = TextStyle(
    fontFamily: monoFamily,
    fontSize: 11,
    fontWeight: FontWeight.w500,
    height: 1.35,
    letterSpacing: 2.75,
  );

  // ── 阅读槽（琉璃默认 sans，字号/行高沿捕获值）──────────────────

  /// 正文：16px / 400 / 1.75。
  static const TextStyle readingBody = TextStyle(
    fontFamily: sansFamily,
    fontSize: 16,
    fontWeight: FontWeight.w400,
    height: 1.75,
  );

  /// 引用：16px / 400 / 1.7（中文不做合成斜体；拉丁斜体由消费面按语种施加）。
  static const TextStyle readingQuote = TextStyle(
    fontFamily: sansFamily,
    fontSize: 16,
    fontWeight: FontWeight.w400,
    height: 1.7,
  );

  /// 展示：24px / 500 / 1.5。
  static const TextStyle readingDisplay = TextStyle(
    fontFamily: sansFamily,
    fontSize: 24,
    fontWeight: FontWeight.w500,
    height: 1.5,
    letterSpacing: -0.01,
  );

  // ── 品牌时刻层 ─────────────────────────────────────────────────────
  // 仅启动/关于页 wordmark 消费；品牌 glow 配色取自材质常量（brand 档）。

  /// wordmark「LMStory」：28px / 700 / -0.02（accent 着色 + glow 由消费面配）。
  static const TextStyle brandWordmark = TextStyle(
    fontFamily: sansFamily,
    fontSize: 28,
    fontWeight: FontWeight.w700,
    height: 1.3,
    letterSpacing: -0.02,
  );
}

// FontFeature 导入别名避免与 material 冲突（dart:ui 提供）。
