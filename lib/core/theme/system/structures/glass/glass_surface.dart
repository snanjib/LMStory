import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';

/// 结构感知表面助手：琉璃结构下启用玻璃表面，Classic 结构保持原样。
///
/// 批A 表面 craft 的接线层——同一表面代码按当前结构轴分流，不复制页面。
extension GlassSurfaceContext on BuildContext {
  /// 当前是否琉璃结构（catalog 结构轴）。
  bool get isGlassSurface =>
      Theme.of(this).extension<LmTokens>()?.structureId == 'glass';

  /// 场地装饰：琉璃=渐变+暗角承载氛围；Classic=原样返回（平色 bg 兜底）。
  Widget glassVenue(Widget child) => lmUi.venue(this, child);

  /// Scaffold 底色：琉璃=透明（透出场地渐变）；Classic=palette.bg。
  ///
  /// 兜底：琉璃下若**没有任何场地祖先**，透明底
  /// 会透出空黑——此时回落到 `classicBg`（= `Theme.scaffoldBackgroundColor`
  /// = `palette.bg`），保证任何路由层级都不透黑。
  Color scaffoldBgOf(Color classicBg) =>
      lmUi.scaffoldBackground(this, classicBg);
}
