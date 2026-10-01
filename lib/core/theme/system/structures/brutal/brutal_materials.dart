import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/system/lm_palette.dart';
import 'package:lmstory/core/theme/system/structures/brutal/brutal_radii.dart';

/// 棱角材质 token：描边墨色 + 阴影唯一公式 + 按压联动。
///
/// 数值出处：《棱角结构_Neubrutalism设计语言调研.md》§2.1（边框）、
/// §2.2（阴影公式 `offset(4,4) · blur 0 · spread 0 · 近黑`）、§3（组件配方）。
///
/// 日间轮廓取 ink，夜间取 dividerStrong：保留印刷骨架，同时避免
/// 大面积近白粗线与正文争夺视觉重心。两档均来自当前配色族。
///
/// 红线（守卫测试化，不靠自觉）：
/// - 禁 blur：一切阴影 blurRadius == 0（阴影是几何色块，不是氛围光）；
/// - 禁渐变：brutal 子树零 gradient（黑白骨架平涂）；
/// - 禁 bounce/elastic：曲线只走 LmMotion（位移是签名，回弹不是）；
/// - 卡片静止零阴影：阴影只在可按压元素上出现，层级靠描边三档表达。
abstract final class BrutalMaterials {
  BrutalMaterials._();

  /// 描边/阴影墨色：按背景明暗选取结构色，正文仍独立使用 ink。
  static Color frameOf(LmPalette palette) =>
      palette.bg.computeLuminance() < palette.ink.computeLuminance()
          ? palette.dividerStrong
          : palette.ink;

  /// 阴影唯一公式：实心色块 offset(4,4)，blur 0 / spread 0，方向右下
  /// （45° 对角，《棱角档案》§2.2 三源一致：TW globals.css、
  /// FB neubrutalism_ui.dart、MD 规格）。
  ///
  /// [pressed] 为真时偏移归零：按压 = 元素平移 (4,4) 且阴影偏移同步
  /// 归零——阴影色块落到元素正后方被完全遮挡，视觉等效消失，与
  /// FB `_button.dart` 的 `widget.offset - _animation.value` 同构。
  /// blur/spread 恒 0（BoxShadow 默认值，不显式传参；守卫测试断言
  /// 实际渲染值恒 0）。
  static List<BoxShadow> shadow(LmPalette palette, {bool pressed = false}) => [
        BoxShadow(
          color: frameOf(palette),
          offset: pressed ? Offset.zero : BrutalRadii.pressOffset,
        ),
      ];

  /// 禁用态不透明度：形态仍可辨（TW 库 `opacity-50` 惯例，
  /// 《棱角档案》§3 Button disabled）。
  static const double disabledOpacity = 0.5;

  /// 可按压表面的 pressed 撞色台阶：primary 槽 @20% 合成（hover 档
  /// 直接消费 primaryDim 槽 @12%，不另设常量）。
  static const double fillPressedAlpha = 0.2;

  /// 焦点描边升级：输入框聚焦时描边由 2px（frameInline）转 3px
  /// （frameCard 档）——焦点表达走描边加粗，不走辉光（03 计划 §3.1）。
  static const double focusFrameWidth = 3;
}
