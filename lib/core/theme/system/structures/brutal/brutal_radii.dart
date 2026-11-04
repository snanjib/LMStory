import 'dart:ui' show Offset;

/// 棱角结构几何 token——边框三档语义锁定 + 直角基调 + 按压位移轴。
///
/// 数值出处：《棱角结构_Neubrutalism设计语言调研.md》§2.1（边框 2/3/4px
/// 三档）、§2.3（圆角词汇表：直角默认、表单小圆角例外）。
/// 层级靠描边粗细表达，不靠背景色深浅，也不靠投影——这是本结构
/// 与琉璃（材质台阶）互为镜像的分界（《棱角档案》§6.1）。
abstract final class BrutalRadii {
  BrutalRadii._();

  // ── 边框三档（语义锁定，禁第四档）─────────────────────────────

  /// 2 — 行内元素描边：按钮、输入框、chip、badge（TW 库 button.tsx `border-2`）。
  static const double frameInline = 2;

  /// 3 — 卡片描边：容器默认档（FB 包 `neuBorder = 3.0`）。
  static const double frameCard = 3;

  /// 4 — 浮层描边：dialog、bottomSheet 等模态（FG kit token 档）。
  static const double frameOverlay = 4;

  // ── 圆角词汇（直角基调 + 表单例外）─────────────────────────────

  /// 0 — 直角：容器与展示元素的默认形态（raw 身份与对齐网格）。
  static const double cornerNone = 0;

  /// 5 — 表单类控件小圆角：按钮、输入框等触屏控件的手指隐喻
  /// （TW 库全库 `rounded-base = 5px`；药丸只给开关类，不给主按钮）。
  static const double cornerField = 5;

  // ── 按压位移轴（结构签名）──────────────────────────────────────

  /// (4,4) — 按压位移与阴影偏移同源：静止时阴影在 (4,4)，按压时元素
  /// 平移 (4,4) 且阴影偏移归零——"按进纸里"（《棱角档案》§2.2，
  /// TW button.tsx 与 FB _button.dart 双库同构）。
  static const Offset pressOffset = Offset(4, 4);

  /// (2,2) — hover 预位移：按压位移的一半。与阴影同轴联动，形成
  /// rest(0,0)/阴影(4,4) → hover(2,2)/阴影(2,2) → pressed(4,4)/阴影(0,0)
  /// 的连续物理轴。
  static const Offset hoverOffset = Offset(2, 2);
}
