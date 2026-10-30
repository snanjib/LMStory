import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// 阅读列限宽**基线**。
///
/// 800 逻辑像素 ≈ 中文 48–50 字/行（正文基准 16px 衬线）、西文 ~95
/// 字符/行，作为阅读列在窄窗下的保底宽度。窗口更宽时版心随窗口按
/// [LmLayout.measureFraction] 流式放大（无固定上限），两侧同步留出
/// 百分比安全边距——见 [LmLayout.measureOf]。
abstract final class LmReadingConstraints {
  /// 阅读列基线宽度（含消费面内部水平 padding）。
  static const double width = 800;
}

/// 大屏布局口径（**唯一事实源**）。
///
/// 本项目主要跑桌面，但长期没有「大屏口径」：断点只有一个 600（移动/桌面
/// 壳分流），最大宽度字面量散落在 structures 与 features 各处，同一个窗口里
/// 可能同时存在 720 的正文列、440/560 的面板、以及通铺整窗的输入区。
/// 本类把「窗口分档」与「版心宽度」收成一组语义槽。
///
/// ## 断点（按窗口逻辑宽）
///
/// | 档位 | 宽度区间 | 典型场景 | 行为 |
/// |---|---|---|---|
/// | [LmLayoutTier.compact] | < 600 | 手机竖屏 | 单栏 + 抽屉壳 |
/// | [LmLayoutTier.medium] | 600 – 1279 | 平板 / 小笔记本 | 全幅铺满（沿用历史布局） |
/// | [LmLayoutTier.wide] | 1280 – 1919 | 桌面（1280/1440/1600） | 启用版心收敛 |
/// | [LmLayoutTier.ultra] | ≥ 1920 | 大屏 / 超宽（1920/2560） | 版心收敛 + 左右留白 |
///
/// **为什么版心从 1280 才启用**：600–1279 是历史已验证过的全幅布局区间，
/// 该区间内任何收敛都会改动既有观感（golden 可证）。1280 起窗口宽度已远超
/// 单列内容的舒适宽度，「卡片被拉成超长行」才开始成为真问题。
///
/// ## 版心（measure）
///
/// 版心的语义是「内容列的最大宽度」，消费面负责居中。断点以下一律返回
/// 原样（见 [LmMeasure]），因此 < 1280 的一切观感与引入本类之前逐像素相同。
///
/// ## 流式版心（宽屏不设固定上限）
///
/// 页面级版心（阅读/表单/列表槽）的**实际宽度** =
/// `max(槽固定值, 窗口宽 × [measureFraction])`（见 [LmLayout.measureOf]）：
/// 窗口越宽版心越宽，两侧各留 `(1 - 占比) / 2` 的百分比安全边距，不再钉死
/// 在固定像素上；槽固定值作为**保底**，窗口不足时避免出现比基线更窄的
/// 回退。会话正文列及其对齐件（输入卡、工具行、决策卡、建议浮层）走
/// [LmLayout.readingWidthOf] 拿同一宽度，全宽段恒同列。
///
/// 浮层/面板（对话框、sheet、侧面板、侧栏）是**局部容器**，保持固定
/// 上限——它们不是页面版心，不随窗口放大。
abstract final class LmLayout {
  // ── 断点 ────────────────────────────────────────────────────────────

  /// [LmLayoutTier.compact] 上限：低于此值走单栏 + 抽屉壳。
  ///
  /// 与 `main_layout` 既有移动/桌面壳分流的 600 是同一个值（对该字面量的
  /// 唯一合法来源就是这里）。
  static const double compactMax = 600;

  /// [LmLayoutTier.medium] 上限：低于此值不启用宽屏版心。
  static const double mediumMax = 1280;

  /// [LmLayoutTier.wide] 上限：达到即进入超宽档。
  static const double wideMax = 1920;

  // ── 版心 ────────────────────────────────────────────────────────────

  /// 正文阅读列（会话 / 故事 / 导演正文）。见 [LmReadingConstraints]。
  static const double readingMeasure = LmReadingConstraints.width;

  /// Available body height for compact home content, scaled with text size.
  static const double homeCompactHeight = 600;

  /// 设置 / 表单类单列页面的版心（设置域全部子页、供应商编辑等）。
  static const double formMeasure = 880;

  /// 列表 / 卡片类页面的版心（资源库、记忆库、模板管理、帮助中心）。
  static const double listMeasure = 1120;

  /// Two resource columns each retain enough space for a full name and actions.
  static const double resourceColumnsMinWidth = 760;

  /// Below these available heights, failure controls share a scroll surface.
  static const double failureFixedControlsMinHeight = 320;
  static const double failureLargeTextMinHeight = 600;

  // ── 浮层 ────────────────────────────────────────────────────────────

  /// 模态对话框最大宽度（规格上限；Flutter 默认不施加，由本项目补上）。
  static const double dialogMaxWidth = 560;

  /// 表单型对话框最大宽度（编辑类，需要更紧凑的阅读宽度）。
  static const double dialogNarrowWidth = 480;

  /// A long manuscript scrolls inside the editor while its actions stay visible.
  static const double messageEditorMaxHeight = 640;

  /// 底部浮层（sheet）最大宽度——宽屏不得通铺整窗。
  static const double sheetMaxWidth = 640;

  /// 页面内嵌侧面板宽度（如 AI 建卡会话面板）。
  static const double panelWidth = 560;

  /// 页面内嵌窄面板宽度。
  static const double panelNarrowWidth = 440;

  // ── 壳层 ────────────────────────────────────────────────────────────

  /// 桌面侧栏宽度。
  static const double sidebarWidth = 240;

  // ── 流式版心 ────────────────────────────────────────────────────────

  /// 版心安全占比：版心宽最大占窗口宽的比例（两侧各留
  /// `(1 - [measureFraction]) / 2` 的安全边距，随窗口同步缩放）。
  ///
  /// 仅在 [LmContentWidthMode.fluid] 下生效；capped 模式版心恒为槽保底值。
  static const double measureFraction = 0.85;

  /// 语义槽在窗口宽 [windowWidth] 下的**实际版心宽**：
  /// `max([base] 保底, 窗口宽 × [measureFraction])`。
  ///
  /// - 窗口宽 × 占比 ≤ base：取 base（窄窗保底，不产生比基线更窄的回退；
  ///   窗口本身不足 base 时约束自然失效，内容通铺）。
  /// - 窗口宽 × 占比 > base：随窗口流式放大，**无固定上限**。
  /// - [mode] 为 [LmContentWidthMode.capped]：恒返回 base（固定上限，
  ///   超宽屏不拉长——用户可在通用设置-外观切换）。
  static double measureOf(
    double windowWidth,
    double base, {
    LmContentWidthMode mode = LmContentWidthMode.fluid,
  }) {
    if (mode == LmContentWidthMode.capped) return base;
    return math.max(base, windowWidth * measureFraction);
  }

  /// 阅读列在当前窗口下的实际版心宽（基线 [LmReadingConstraints.width]；
  /// 跟随 [LmContentWidthScope] 的用户选择，缺省流式）。
  ///
  /// 会话正文列与全部对齐件（输入卡、工具行、决策卡、建议浮层、空态、
  /// 开场标题）统一经此取宽，保证任意窗口宽度下同列。
  static double readingWidthOf(BuildContext context) => measureOf(
        MediaQuery.sizeOf(context).width,
        LmReadingConstraints.width,
        mode: LmContentWidthScope.of(context),
      );

  /// 窗口宽度所属档位。
  static LmLayoutTier tierOf(double width) {
    if (width < compactMax) return LmLayoutTier.compact;
    if (width < mediumMax) return LmLayoutTier.medium;
    if (width < wideMax) return LmLayoutTier.wide;
    return LmLayoutTier.ultra;
  }

  /// 是否启用宽屏版心收敛（≥ [mediumMax]）。
  static bool usesMeasure(double width) => width >= mediumMax;
}

/// 内容宽度模式（通用设置-外观；版心的宽屏行为）。
enum LmContentWidthMode {
  /// 流式（默认）：版心 = max(基线, 窗口 × [LmLayout.measureFraction])，
  /// 随窗口放大、无固定上限，两侧留百分比安全边距。
  fluid,

  /// 固定上限：版心恒为语义槽基线宽度，超宽屏内容不拉长（两侧留白）。
  capped,
}

/// 内容宽度模式的下发作用域：应用顶层按用户设置挂载，版心消费面经
/// [LmContentWidthScope.of] 读取（theme 层不依赖任何状态管理库）。
/// 未挂载时缺省 [LmContentWidthMode.fluid]。
class LmContentWidthScope extends InheritedWidget {
  const LmContentWidthScope({
    required this.mode,
    required super.child,
    super.key,
  });

  final LmContentWidthMode mode;

  static LmContentWidthMode of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<LmContentWidthScope>()?.mode ??
      LmContentWidthMode.fluid;

  @override
  bool updateShouldNotify(LmContentWidthScope oldWidget) =>
      oldWidget.mode != mode;
}

/// 窗口宽度档位。语义与 [LmLayout] 头部的分档表一致。
enum LmLayoutTier { compact, medium, wide, ultra }

/// 宽屏版心容器：窗口宽度达到 [LmLayout.mediumMax] 才启用。
///
/// - 宽度 < [LmLayout.mediumMax]：[child] 原样返回（**逐像素零变化**，
///   历史 golden 不受影响）。
/// - 宽度 ≥ [LmLayout.mediumMax]：钳制到**流式版心宽**
///   （[LmLayout.measureOf]：`max([maxWidth] 保底, 窗口宽 × 占比)`）并水平
///   居中——窗口越宽版心越宽，不再钉死在固定像素。
///
/// 纵向不做任何限制：[child] 通常是 `ListView` / `SingleChildScrollView`，
/// 需要拿到完整的可用高度。
class LmMeasure extends StatelessWidget {
  const LmMeasure({
    required this.child,
    this.maxWidth = LmLayout.formMeasure,
    super.key,
  });

  final Widget child;

  /// 版心基线（保底宽度），取 [LmLayout] 的语义槽，不要在调用点写裸数字。
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final windowWidth = MediaQuery.sizeOf(context).width;
    if (!LmLayout.usesMeasure(windowWidth)) {
      return child;
    }
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: LmLayout.measureOf(
            windowWidth,
            maxWidth,
            mode: LmContentWidthScope.of(context),
          ),
        ),
        child: child,
      ),
    );
  }
}
