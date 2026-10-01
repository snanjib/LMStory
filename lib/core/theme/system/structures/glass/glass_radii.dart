/// 琉璃结构圆角——四档闭锁（禁第五档）。
///
/// 与 Classic 六档共存互不映射；琉璃表面 craft 按 §2.4 映射提示逐件
/// 分流（rFull→stadium；rXl/rLg→card；rMd 按语义分流；rSm/rXs→chip）。
abstract final class GlassRadii {
  GlassRadii._();

  /// 9999 — 药丸按钮、分段控件、药丸 chip、悬浮操作条、snackBar（短）。
  static const double stadium = 9999;

  /// 24 — 卡片、面板、模态、底部弹层（顶角）、阅读卡。
  static const double card = 24;

  /// 14 — 输入框、列表行、设置行、横幅、内嵌元素。
  static const double input = 14;

  /// 8 — 小徽标 tag、版本号底。
  static const double chip = 8;
}
