import 'package:flutter/material.dart';

/// 中级模式字体层级令牌。
///
/// 双字体策略（DOC-06B §4.1）：
/// - 衬线（LMSerif + LMSerifSC，OFL 子集打包）：叙事文本，文学感；
///   打包子集缺字时逐级落到中文子集与系统默认字体（真机验收含缺字抽查）
/// - 无衬线（Inter，与 Simple 共享）：UI 元素，操作效率
///
/// 配对符合对比轴原则（衬线 vs 无衬线），避免相似字体冲突。
class LmNarrativeTextStyles {
  LmNarrativeTextStyles._();

  // ── 字体族名 ───────────────────────────────────────────────────────

  /// 衬线字体族名（拉丁字符，pubspec 打包子集）
  static const String serifFamily = 'LMSerif';

  /// 衬线字体族名（中文 fallback，pubspec 打包子集）
  static const String serifScFamily = 'LMSerifSC';

  /// 无衬线字体族名（UI 元素，与 Simple 共享）
  static const String sansFamily = 'Inter';

  // ── 衬线（叙事文本）──────────────────────────────────────────────
  // 打包字体 const 直引，无运行时加载与网络依赖。

  /// 消息正文：16px / 400 / 1.75
  static const TextStyle narrativeBody = TextStyle(
    fontFamily: serifFamily,
    fontFamilyFallback: [serifScFamily],
    fontSize: 16,
    fontWeight: FontWeight.w400,
    height: 1.75,
  );

  /// 引用、独白：16px / 400 斜体 / 1.7
  static const TextStyle narrativeQuote = TextStyle(
    fontFamily: serifFamily,
    fontFamilyFallback: [serifScFamily],
    fontSize: 16,
    fontWeight: FontWeight.w400,
    fontStyle: FontStyle.italic,
    height: 1.7,
  );

  /// 空状态引导大字：24px / 500 / 1.5
  static const TextStyle narrativeDisplay = TextStyle(
    fontFamily: serifFamily,
    fontFamilyFallback: [serifScFamily],
    fontSize: 24,
    fontWeight: FontWeight.w500,
    height: 1.5,
    letterSpacing: -0.01,
  );

  // ── 无衬线（UI 元素，Inter）──────────────────────────────────────
  // Inter 已在 pubspec.yaml 打包，直接用 const TextStyle 引用。

  /// AppBar 标题：18px / 600 / 1.4
  static const TextStyle title = TextStyle(
    fontFamily: sansFamily,
    fontSize: 18,
    fontWeight: FontWeight.w600,
    height: 1.4,
    letterSpacing: -0.01,
  );

  /// 标签、按钮文字：14px / 500 / 1.4
  static const TextStyle label = TextStyle(
    fontFamily: sansFamily,
    fontSize: 14,
    fontWeight: FontWeight.w500,
    height: 1.4,
  );

  /// UI 正文：15px / 400 / 1.5
  static const TextStyle bodyUi = TextStyle(
    fontFamily: sansFamily,
    fontSize: 15,
    fontWeight: FontWeight.w400,
    height: 1.5,
  );

  /// 时间戳、辅助说明：12px / 400 / 1.4
  static const TextStyle caption = TextStyle(
    fontFamily: sansFamily,
    fontSize: 12,
    fontWeight: FontWeight.w400,
    height: 1.4,
  );

  /// 微标签（模型元数据、chip 标注等）：11px / 500 / 1.35。
  /// 收敛此前散落各处的 `caption.copyWith(fontSize: 11)`。
  static const TextStyle captionSm = TextStyle(
    fontFamily: sansFamily,
    fontSize: 11,
    fontWeight: FontWeight.w500,
    height: 1.35,
  );

  /// 输入框文字：16px / 400 / 1.5
  static const TextStyle input = TextStyle(
    fontFamily: sansFamily,
    fontSize: 16,
    fontWeight: FontWeight.w400,
    height: 1.5,
  );
}
