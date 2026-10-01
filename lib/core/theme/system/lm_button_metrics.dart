import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';

/// 四类按钮（filled / elevated / outlined / text）的共享度量。
///
/// Classic 与 Glass 两结构只允许在「形状」（rMd 圆角 vs stadium）与
/// 「配色」上分化；触控目标、内边距、标签字重是全外观统一度量，
/// 由本类单一供应，禁止两个结构各自复制一份（控件度量统一）。
abstract final class LmButtonMetrics {
  /// 触控目标下限（a11y 红线，WCAG 2.5.5）。
  static const double minInteractiveHeight = 44;

  /// 实体按钮（filled / elevated / outlined）最小尺寸。
  static const Size minimumSize = Size(0, minInteractiveHeight);

  /// 实体按钮内边距。
  static const EdgeInsets solidPadding = EdgeInsets.symmetric(
    horizontal: LmSpacing.sLg,
    vertical: LmSpacing.sMd,
  );

  /// 文字按钮内边距（纵向更紧，与 Classic 现值一致）。
  static const EdgeInsets textPadding = EdgeInsets.symmetric(
    horizontal: LmSpacing.sLg,
    vertical: LmSpacing.sSm,
  );

  /// 按钮标签基线：bodySm + w500（Medium）。结构只允许覆写颜色，
  /// 字号/字重/行高由本基线锁定。
  static TextStyle label(TextStyle base) =>
      base.copyWith(fontWeight: FontWeight.w500);

  /// Classic 的**扁平口径**：四类按钮**全态零 elevation**。
  ///
  /// 取值走 `XxxButton.styleFrom(elevation: …)`：styleFrom 内部用
  /// `ButtonStyleButton.allOrNull` 把它铺成 `WidgetStatePropertyAll`，
  /// 即 **hover / pressed / focused / disabled 全部态**都是 0。
  ///
  ///  默认给 FilledButton 的 hover 抬 1、给 ElevatedButton 静止就抬 1
  /// （hover 3），阴影色一律取 `colorScheme.shadow`（纯黑）。Classic 的
  /// 语言刻意扁平，于是：classic 夜间 FilledButton 圆角外侧像素从页面底色
  /// `244,245,247` 变成 `0,0,0`（Δ247），同结构的 ElevatedButton 只有 Δ15
  /// ——同一结构内两类按钮的 hover 观感因此不一致（实测）。
  ///
  /// 全态钉 0 后，hover 反馈回到**面色**（Material 状态层，实测 Δ15–20，
  /// 仍可感知），不再凭空生阴影。
  ///
  /// 口径外的例外：FAB 仍保留 elevation（见 classic_structure 的
  /// `floatingActionButtonTheme` 注释）——浮起是 FAB 的成立条件。
  static const double flatElevation = 0;

  /// 同 [flatElevation]，但可直接覆盖 `ButtonStyle.elevation`。
  ///
  /// **为什么需要两个**：`ElevatedButton.styleFrom` 的 `elevation` 参数是
  /// **基数**——它把 hover 算成 `elevation + 2`、pressed 算成
  /// `elevation + 6`（见 `material/elevated_button.dart` 的 `styleFrom`）。
  /// 于是 `elevation: 0` 实际得到 hover=2 / pressed=6，扁平口径失效
  /// （被 `t10_flat_button_guard_test.dart` 逐态 resolve 抓住）。
  /// `Filled/Outlined/TextButton.styleFrom` 则是 `allOrNull(elevation)` 的
  /// 直接口径，用 [flatElevation] 即可。
  static const WidgetStateProperty<double> flatElevationProperty =
      WidgetStatePropertyAll<double>(0);
}
