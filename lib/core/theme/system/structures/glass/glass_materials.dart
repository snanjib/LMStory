import 'package:flutter/material.dart';

/// 琉璃材质三档（真玻璃 /  平玻璃 /  实体）与 glow 预算。
///
/// 配方只消费配色槽位与 white-alpha 台阶（解耦保证）；层级语法
///  >  >  的亮度/透明度台阶承载层级，不靠描边。
///
/// 红线（守卫测试化，不靠自觉）：
/// -  白名单闭集＝modal / bottomSheet / floatingBar 三类，同屏 ≤2；
/// - 流式渲染进行中 floatingBar 降级 、模态入场禁 blur 动画；
/// - 正文/流式渲染区恒久零 BackdropFilter（阅读卡=surface 不透明）；
/// - glow 仅焦点环与品牌时刻（启动/关于）。
/// 白玻璃台阶的**方向**：由底面色亮度派生（裁决）。
///
/// 白叠白、黑叠黑都必然无变化——方向必须跟着底面走，与 Apple 材质
/// 「highlight / shadow 极性随环境翻转」同构。
enum GlassStepDirection {
  /// 提亮：底面暗 → 叠白。
  lift,

  /// 压暗：底面亮 → 叠黑。
  sink,
}

abstract final class GlassMaterials {
  GlassMaterials._();

  // ── 白玻璃台阶（结构常量，非配色槽）──────────────────────────────
  //
  // 状态台阶**不再按 Brightness 硬分档**，方向由 [directionOf] 从
  // 底面色亮度派生。旧实现（§3.0-1）为浅底把 alpha 从 6% 抬到 30/50/70%，
  // 方向仍是「只叠白」，于是：
  //   · 波尔多夜间主色药丸面色是纯白，hover 叠白 → Δ0（实测）；
  //   · 浅底 ghost 药丸 hover Δ8（贴线）／波尔多浅色 Δ0；
  //   · fill10(light) == fill16(light) == 白@50%，chip 的 +1/+2 塌掉一档。
  //
  // ── 两条语义轴（的关键切分，别再混成一条）────────────────────
  //
  // **A. 层级面 / 结构面（`fill6` 静息面、`fill22` 结构档）：恒提亮。**
  //    它们回答「这个构件从场地里浮起来了吗」，不回答「指针在上面吗」。
  //    alpha 仍由底面亮度派生（暗底 6%/22%，亮底 30%/70%），但**方向恒为
  //    叠白** —— 于是所有构件的静息面观感与改动前逐像素一致。
  //
  // **B. 状态台阶（`fill10` hover、`fill16` pressed/selected）：方向派生。**
  //    暗底叠白、亮底叠黑。这是本次真正修的东西。
  //
  // 为什么必须切开：浅底上「静息面 + hover + pressed 三档全压暗」在数学上
  // 无解——`muted` 文字在 #F4F5F7 上只有 5.13:1，压暗 ≤11% 就必须停手
  // （再暗就跌破 4.5），而 11% 的总量塞不进「Δ≥15 + 额外增量≥8」两档。
  // 让静息面留在提亮侧（它本来就只贡献 Δ3，观感等同旧值），状态台阶就
  // 拿回了全部对比度预算：实测 hover Δ21 / pressed Δ30，muted 仍有
  // 4.94 / 4.55。
  //
  // 档位序号沿用 `fill6/10/16/22` 的历史 alpha 编号，只作序号用。

  /// A 轴 · 静息面（叠白）：暗底 6% / 亮底 30%（旧 fillNight6 / fillDay30）。
  static const Color restLiftDark = Color(0x0FFFFFFF);
  static const Color restLiftLight = Color(0x4DFFFFFF);

  /// A 轴 · 结构档（叠白）：暗底 22% / 亮底 70%（旧 fillNight22 / fillDay70）。
  ///
  /// 消费点：chip 描边 / segmented thumb / bottomSheet 把手 /  模态面。
  static const Color structLiftDark = Color(0x38FFFFFF);
  static const Color structLiftLight = Color(0xB3FFFFFF);

  /// B 轴 · hover 台阶：暗底叠白 13% / 亮底叠黑 7%。
  ///
  /// alpha 由验收线反推，不是沿旧值：
  ///   · 提亮侧 Δ = a × (255 − 底面最小通道)；最没余量的真实底面是波尔多夜
  ///     error #FF6B7A（余量 148）→ a ≥ 10.1%，取 13%（余量给 pressed）。
  ///   · 压暗侧 Δ = a × 底面最大通道（静息面已提到 ≈249）→ a ≥ 6.1%，
  ///     取 7%（实测 Δ17）。
  static const Color liftHover = Color(0x21FFFFFF);
  static const Color sinkHover = Color(0x12000000);

  /// B 轴 · pressed / selected 台阶：暗底叠白 19% / 亮底叠黑 10.5%。
  ///
  /// 上限来自对比度：亮底按压面再暗，`muted`（classic 日对 bg 仅 5.13）就
  /// 跌破 4.5 —— 10.5% 时实测 4.54，是能过线的最深一档。
  /// 下限来自「相对 hover 还要有 ≥8 的额外增量」（10.5 − 7 = 3.5 个百分点
  /// × 249 ≈ 8.7）。两个边界之间是唯一解。
  static const Color liftPressed = Color(0x30FFFFFF);
  static const Color sinkPressed = Color(0x1B000000);

  /// 方向翻转阈值（WCAG 相对亮度）：sRGB 中灰 #BCBCBC 的亮度 ≈0.5。
  ///
  /// 底面比中灰亮时，叠白的增量 (255−B) 已不足以产生可感知台阶
  /// （实测 Δ≤8），必须压暗；底面比中灰暗则叠白。
  static const double stepFlipLuminance = 0.5;

  ///  模态任务面台阶：**恒提亮**（不随底面翻转）。
  ///
  /// 模态任务面的职责是「从 scrim 压暗后的场地里浮出来」做图底分离，
  /// 而 scrim 恒为暗色叠加（classic 日 0x66161616 / 夜 0xB30E1018，
  /// 波尔多 0x66301E26 / 0x99120A12）——场地侧永远被压暗，故提亮永远
  /// 正确。这是**层级台阶**，不是状态台阶，量级沿用既有明暗值，观感零变化。
  static const Color t2LiftLight = structLiftLight;
  static const Color t2LiftDark = structLiftDark;

  /// 顶部内侧高光（白@18%；单侧 boxShadow(0,-1) 实现，不占布局宽度）。
  static const Color topInnerHighlight = Color(0x2EFFFFFF);

  ///  真玻璃悬浮面填充（白@8%）。
  static const Color t0Fill = Color(0x14FFFFFF);

  ///  blur 锚值（20–30 区间取 24）。
  static const double t0Blur = 24;

  ///  长阴影（黑@40%，blur 32，offset(0,12)）。
  static const List<BoxShadow> t0Shadow = [
    BoxShadow(
      color: Color(0x66000000),
      blurRadius: 32,
      offset: Offset(0, 12),
    ),
  ];

  ///  浮起短阴影（黑@25%，blur 16，offset(0,4)）；静止  零阴影。
  static const List<BoxShadow> t1FloatShadow = [
    BoxShadow(
      color: Color(0x40000000),
      blurRadius: 16,
      offset: Offset(0, 4),
    ),
  ];

  /// 日间阴影（黑@12%，blur 20，offset(0,6)）——白高光在浅底弱化，
  /// 层级差由阴影补足（§3.0-1）。
  static const List<BoxShadow> dayShadow = [
    BoxShadow(
      color: Color(0x1F000000),
      blurRadius: 20,
      offset: Offset(0, 6),
    ),
  ];

  /// glow：焦点环（accent@30%，blur 12–24 取 16）。
  ///
  /// 颜色只能来自配色槽：辉光按当前配色族 accent **运行时派生**，
  /// 不允许任何族无关的字面量（历史上写死波尔多 accent 导致
  /// 「琉璃 + 经典配色」下聚焦辉光是粉红、与本族琥珀 accent 冲突的
  /// 跨轴泄漏， 收口）。
  static Color focusGlow(Color accent) => accent.withValues(alpha: 0x4D / 255);
  static const double focusGlowBlur = 16;

  /// glow：品牌时刻（accent@35%）；全 app 仅启动/关于页字效消费。
  static Color brandGlow(Color accent) => accent.withValues(alpha: 0x59 / 255);

  /// 焦点环线宽。
  static const double focusRingWidth = 2;

  /// 禁用态描边 alpha（五态完备）：形态仍可辨、不做成隐形。
  static const double disabledBorderAlpha = 0.4;

  /// 按压回弹禁用（无弹跳无弹性）；按压 scale。
  static const double pressedScale = 0.98;

  /// 台阶方向：由**底面色亮度**派生（不是按 Brightness 分档）。
  ///
  /// [base] 必须是「叠色即将压上去的那一层」的不透明色：
  /// 实心药丸传自己的面色，ghost / 面板 / chip 传它们所坐落的底面
  /// （通常为 `palette.bg`，即场地渐变锚点）。
  static GlassStepDirection directionOf(Color base) =>
      base.computeLuminance() >= stepFlipLuminance
          ? GlassStepDirection.sink
          : GlassStepDirection.lift;

  /// A 轴 · 静息面（第 1 级，构件自带面；药丸的静息是**裸底**，不含本档）。
  ///
  /// **恒提亮**——方向不翻转，只有 alpha 跟着底面亮度走。理由见类注释
  /// 「两条语义轴」：静息面是层级面，且必须为状态台阶留住对比度预算。
  static Color fill6(Color base) => base.computeLuminance() >= stepFlipLuminance
      ? restLiftLight
      : restLiftDark;

  /// B 轴 · hover 台阶（第 2 级）：方向由 [directionOf] 派生。
  static Color fill10(Color base) =>
      directionOf(base) == GlassStepDirection.sink ? sinkHover : liftHover;

  /// B 轴 · pressed / selected 台阶（第 3 级）：方向由 [directionOf] 派生。
  static Color fill16(Color base) =>
      directionOf(base) == GlassStepDirection.sink ? sinkPressed : liftPressed;

  /// A 轴 · 结构档（第 4 级：描边 / thumb / bottomSheet 把手 /  模态面）。
  /// **恒提亮**，不参与状态递进。
  static Color fill22(Color base) =>
      base.computeLuminance() >= stepFlipLuminance
          ? structLiftLight
          : structLiftDark;

  /// 把 [fill] 压到 [base] 上的**不透明合成色**。
  ///
  /// 供「以合成面为新底面继续叠档」与对比度核算使用——半透明台阶的
  /// `computeLuminance()` 只看 rgb（黑@8% 的 rgb 是 0），直接拿它判
  /// 方向会得到错误的「提亮」。
  static Color stepped(Color base, Color fill) => Color.alphaBlend(fill, base);

  /// 模态任务面（台阶）：surfaceElevated + 恒提亮档组合。
  ///
  /// Apple Liquid Glass「任务面随聚焦变实」的同构规则：半浮层展开为任务面时
  /// 提高不透明度，与 scrim 压暗后的场地拉开图底分离。玻璃+波尔多夜间的
  /// 弹窗面板（surfaceElevated）与酒色 scrim 后的场地明度几乎无差，
  /// 轮廓不可辨（发现 D）；本台阶提亮一档解决，不新增配色槽。
  static Color modalSurface(Brightness b, Color baseElevated) =>
      Color.alphaBlend(
        b == Brightness.light ? t2LiftLight : t2LiftDark,
        baseElevated,
      );

  ///  模态任务面阴影：ink 与 t1FloatShadow 同源（黑@25%）。
  ///
  /// dialogTheme 只能表达 elevation + shadowColor（Material 层无法携带
  /// BoxShadow 几何），量级对齐  浮起短阴影（弹窗面工艺微调）。
  static const Color t2ShadowColor = Color(0x40000000);
  static const double t2Elevation = 6;

  /// 浮起面阴影按明暗取档。
  static List<BoxShadow> floatShadow(Brightness b) =>
      b == Brightness.light ? dayShadow : t1FloatShadow;
}
