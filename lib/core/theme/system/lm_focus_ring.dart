import 'package:flutter/widgets.dart';
import 'package:lmstory/core/theme/system/lm_palette.dart';

/// 键盘焦点指示口径（**唯一事实源**）。
///
/// ## 为什么需要它（实测）
///
/// classic 侧此前**只**吃 Material 默认焦点 overlay（`focusColor` 12% 叠色）。
/// 逐像素实测（`test/core/theme/t07_focus_contrast_report_test.dart`）：
/// 四组合 × 四类按钮共 16 组，「聚焦态 vs 未聚焦态同一像素」的**对比度变化
/// 峰值只有 1.14–1.39:1**，远低于 WCAG 2.2 SC 2.4.11（焦点外观）的 3:1
/// 门槛——键盘用户实际上看不出焦点落在哪个控件上。 观察到的「均Δ≈20」
/// 正是这一低对比度的低分辨率代理。
///
/// ## 只在键盘焦点态生效
///
/// 所有消费点都走 `WidgetState.focused`。Material 的 `ButtonStyleButton`
/// **只在 `FocusHighlightMode.traditional`（键盘 / 焦点遍历）下**才上报
/// `focused`；指针交互（鼠标悬停 / 触摸按压）拿到的是 `hovered` / `pressed`。
/// 因此默认观感（含 golden 基线）零变化——派发红线「不许把 classic 的默认
/// 观感改掉」由构造保证，而不是靠自律。
///
/// ## 为什么实心与透明底用不同环色
///
/// 环画在控件**内部**（`side` / `Border` 均内绘），所以「环色对什么形成对比」
/// 取决于该位置**未聚焦时**是什么：
///
/// | 控件 | 环像素原本是 | 环色 | 四组合实测变化 |
/// |---|---|---|---|
/// | filled / elevated（填充 = `primary`） | `primary` | `onPrimary` | 8.09–16.8:1 |
/// | outlined / text（透明底） | 页面底色（outlined 最外 1.5px 是既有描边） | `ink` | ≥12:1 |
///
/// 单个颜色**无法同时**对浅色页面底与深色品牌填充都达到 3:1：浅色主题下
/// `bg` 亮度 0.896、`primary` 亮度 0.076，要同时对二者 3:1 需要亮度既
/// ≥0.329 又 ≤0.265，区间为空。故必须按控件类型分化环色。
abstract final class LmFocusRing {
  /// 键盘焦点环宽（2px）。
  ///
  /// 与玻璃工厂 `GlassMaterials.focusRingWidth` **同值**——两结构的焦点环
  /// 粗细必须一致，否则同一键盘用户在 classic / glass 间切换时会觉得
  /// 「焦点环一会儿粗一会儿细」。
  static const double width = 2;

  /// outlined 按钮的**默认**描边宽（classic 既有值，不要改）。
  static const double defaultOutlinedWidth = 1.5;

  /// outlined 按钮聚焦时的环宽。
  ///
  /// 为什么不沿用 [width]：outlined 的既有描边占住最外
  /// [defaultOutlinedWidth] 1.5px，若焦点环只有 2px，则「**新变化**且达到
  /// 3:1 的像素带」只有 2 − 1.5 = 0.5px 厚，不满足 SC 2.4.11 对指示区域
  /// 「至少 2px 厚」的要求。取 4px 使新增变化带 = 4 − 1.5 = **2.5px ≥ 2px**。
  static const double outlinedFocusWidth = 4;

  /// 实心按钮（filled / elevated）的焦点环。
  static BorderSide solid(LmPalette palette) =>
      BorderSide(color: palette.onPrimary, width: width);

  /// 透明底按钮（text）的焦点环。
  static BorderSide plain(LmPalette palette) =>
      BorderSide(color: palette.ink, width: width);

  /// outlined 按钮的焦点环（宽见 [outlinedFocusWidth]）。
  static BorderSide outlined(LmPalette palette) =>
      BorderSide(color: palette.ink, width: outlinedFocusWidth);

  /// outlined 按钮的**未聚焦**描边（保持既有观感）。
  static BorderSide outlinedIdle(LmPalette palette) =>
      BorderSide(color: palette.primary, width: defaultOutlinedWidth);

  /// 依 `focused` 解析 [WidgetStateProperty]。
  ///
  /// [idle] 为 null 时表示未聚焦态无描边（filled / elevated / text 原状）。
  static WidgetStateProperty<BorderSide?> side({
    required BorderSide Function() focused,
    BorderSide Function()? idle,
  }) =>
      WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.focused)) return focused();
        return idle?.call();
      });
}
