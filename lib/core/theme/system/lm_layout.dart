import 'package:flutter/widgets.dart';

/// 阅读列限宽：正文行长红线。
///
/// 720 逻辑像素 ≈ 中文 40–45 字/行、西文 85–95 字符/行，落在可读性
/// （Nielsen / Bringhurst 口径）的舒适带内。**不要因为窗口变宽就放宽它**——
/// 大屏下的正确做法是把版面其余部件（输入区、工具栏、空态）对齐到同一
/// 版心，而不是把正文拉长（见 [LmLayout] 头注释）。
abstract final class LmReadingConstraints {
  /// 阅读列宽度（含消费面内部水平 padding）。
  static const double width = 720;
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
/// ## 与阅读列的关系
///
/// 大屏下正文列**不放宽**（可读性红线，参见 [LmReadingConstraints]）；
/// 大屏修正做的是「把版面其余部件对齐到同一版心」：
/// 主会话输入区、故事模式正文列，此前分别是「通铺整窗」与「无上限」，
/// 这才是左右留白失衡的真正来源。
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

  /// 设置 / 表单类单列页面的版心（设置域全部子页、供应商编辑等）。
  static const double formMeasure = 880;

  /// 列表 / 卡片类页面的版心（资源库、记忆库、模板管理、帮助中心）。
  static const double listMeasure = 1120;

  // ── 浮层 ────────────────────────────────────────────────────────────

  /// 模态对话框最大宽度（规格上限；Flutter 默认不施加，由本项目补上）。
  static const double dialogMaxWidth = 560;

  /// 表单型对话框最大宽度（编辑类，需要更紧凑的阅读宽度）。
  static const double dialogNarrowWidth = 480;

  /// 底部浮层（sheet）最大宽度——宽屏不得通铺整窗。
  static const double sheetMaxWidth = 640;

  /// 页面内嵌侧面板宽度（如 AI 建卡会话面板）。
  static const double panelWidth = 560;

  /// 页面内嵌窄面板宽度。
  static const double panelNarrowWidth = 440;

  // ── 壳层 ────────────────────────────────────────────────────────────

  /// 桌面侧栏宽度。
  static const double sidebarWidth = 240;

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

/// 窗口宽度档位。语义与 [LmLayout] 头部的分档表一致。
enum LmLayoutTier { compact, medium, wide, ultra }

/// 宽屏版心容器：窗口宽度达到 [LmLayout.mediumMax] 才启用。
///
/// - 宽度 < [LmLayout.mediumMax]：[child] 原样返回（**逐像素零变化**，
///   历史 golden 不受影响）。
/// - 宽度 ≥ [LmLayout.mediumMax]：钳制到 [maxWidth] 并水平居中，使单列内容
///   不再被拉成整窗长的超长行。
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

  /// 版心宽度，取 [LmLayout] 的语义槽，不要在调用点写裸数字。
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    if (!LmLayout.usesMeasure(MediaQuery.sizeOf(context).width)) {
      return child;
    }
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}
