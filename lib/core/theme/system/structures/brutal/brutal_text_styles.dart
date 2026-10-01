import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/system/lm_ui_text_styles.dart'
    show LmUiTextStyles;

/// 棱角排版 token：既有 8 档字号阶梯上的字重分化。
///
/// 数值出处：《棱角结构_Neubrutalism设计语言调研.md》§2.5（heading 700 /
/// body 500 / 正文长文 400；全大写限于短 label；标题 ≈2× 正文的字号对比）。
///
/// 分化规则：
/// - 标题/标签 w700、正文 w500 两档（UI 面）；阅读长文 w400（档案 §2.5）；
/// - 字号/行高沿用 [LmUiTextStyles] 捕获阶梯（11/12/14/15/16/18/22/28），
///   只分化字重，不开新字号；
/// - 全大写仅作用于拉丁 label（[labelUpper]），中文以字重 + 字距承担同等
///   语义，禁合成斜体（与琉璃同纪律）。
abstract final class BrutalTextStyles {
  BrutalTextStyles._();

  // ── 标题层（w700）───────────────────────────────────────────────

  /// 展示：28px / 700 / 1.3 / -0.02（沿 LmUiTextStyles.display 阶梯）。
  static const TextStyle display = TextStyle(
    fontSize: 28,
    fontWeight: FontWeight.w700,
    height: 1.3,
    letterSpacing: -0.02,
  );

  /// 标题一：22px / 700 / 1.35 / -0.015。
  static const TextStyle title1 = TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.w700,
    height: 1.35,
    letterSpacing: -0.015,
  );

  /// 标题二：18px / 700 / 1.4 / -0.01。
  static const TextStyle title2 = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.w700,
    height: 1.4,
    letterSpacing: -0.01,
  );

  /// 标题三：16px / 700 / 1.45。
  static const TextStyle title3 = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w700,
    height: 1.45,
  );

  // ── 正文层（w500）───────────────────────────────────────────────

  /// 正文：15px / 500 / 1.6。
  static const TextStyle body = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w500,
    height: 1.6,
  );

  /// 小号正文：14px / 500 / 1.55。
  static const TextStyle bodySm = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w500,
    height: 1.55,
  );

  /// 说明：12px / 500 / 1.5 / 0.02。
  static const TextStyle caption = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w500,
    height: 1.5,
    letterSpacing: 0.02,
  );

  // ── 标签层（拉丁全大写变体）─────────────────────────────────────

  /// 拉丁短标签：11px / 700 / 1.4 / 0.08 宽字距。
  ///
  /// 全大写由消费面 `String.toUpperCase()` 施加（TextStyle 无大写开关）；
  /// 仅限拉丁短 label（分区头、版本号、状态标签），长句禁全大写
  /// （可读性红线，《棱角档案》§2.5）。
  static const TextStyle labelUpper = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w700,
    height: 1.4,
    letterSpacing: 0.08,
  );

  // ── 阅读槽（长文 w400）──────────────────────────────────────────

  /// 阅读正文：16px / 400 / 1.75（正文长文 400，档案 §2.5；
  /// 正文阅读区豁免于结构语法，纸面沿用 surface 不透明）。
  static const TextStyle readingBody = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w400,
    height: 1.75,
  );

  /// 阅读展示：24px / 700 / 1.5 / -0.01（标题层字重延伸到阅读面）。
  static const TextStyle readingDisplay = TextStyle(
    fontSize: 24,
    fontWeight: FontWeight.w700,
    height: 1.5,
    letterSpacing: -0.01,
  );
}
