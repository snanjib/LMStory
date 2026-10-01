import 'package:flutter/material.dart';

/// 结构无关的动效单源：时长语义槽 + 曲线语义槽 + 减弱动态降级。
///
/// 与 `LmButtonMetrics`（按钮度量单源）、`GlassMaterials`（材质单源）、
/// `GlassRadii`（几何单源）同一范式：结构轴（classic / glass）与业务面
/// （features）都从这里取，**禁止就地写时长/曲线字面量**。
///
/// 守卫：`test/core/theme/lm_motion_guard_test.dart` 扫描 `lib/` 全域的
/// `Duration(milliseconds: <数字>)` / `Curves.<名>` / `Cubic(<数字>…)`，
/// 唯一的豁免通道是在该语句**上方一行**写 `// lm-motion-exempt: <理由>`
/// （用于网络超时、定时器、流式引擎节奏等**非过渡动效**的时长）。
///
/// 红线：
/// - **禁 bounce / elastic**（Apple 原则）：曲线只允许减速族与双向缓入缓出，
///   任何回弹曲线一律不准入表；
/// - **数值即经典现值**：本轮收编"只换来源、不改数值"，保证 Classic 组合
///   零视觉零行为变化（golden 实证）；
/// - **尊重减弱动态**：`MediaQuery.disableAnimations` 为真时一切过渡退化为
///   [instant]（直接终态）或 [micro]（极短纯淡入），循环动效**不得启动**。
abstract final class LmMotion {
  LmMotion._();

  // ── 时长语义槽（刻度）────────────────────────────────────────────
  // 语义槽之间是"档"的关系：消费面优先按语义选档，而不是按"看起来差不多"。

  /// 终态：减弱动态下的直接落点（不做补间，动画不启动）。
  static const Duration instant = Duration.zero;

  /// 微反馈：悬停/聚焦环淡入、进度环、搜索高亮——最小可感档。
  static const Duration micro = Duration(milliseconds: 120);

  /// 快档：按压反馈、状态切换、跳转药丸。
  static const Duration fast = Duration(milliseconds: 150);

  /// 常规档：绝大多数过渡的默认档（模态、条目淡入、面板切换）。
  static const Duration base = Duration(milliseconds: 200);

  /// 慢档：显著过渡与出场（crossfade、收起）。
  static const Duration slow = Duration(milliseconds: 250);

  /// 强调档：强调/布局形变（抽屉、导航、面板展开）。
  static const Duration emphasis = Duration(milliseconds: 300);

  /// 进场档：列表条目/消息入场。
  static const Duration enter = Duration(milliseconds: 400);

  /// 整场转场：模式切换级别的画面过渡。
  static const Duration transition = Duration(milliseconds: 500);

  // 语义别名（与刻度同值，只为调用点自解释——不是新档位）。
  /// 按压态时长（= [fast]）。
  static const Duration press = fast;

  /// 悬停态时长（= [fast]）。
  static const Duration hover = fast;

  /// 聚焦态时长（= [micro]）。
  static const Duration focus = micro;

  /// 出场态时长（= [slow]）。
  static const Duration exit = slow;

  // ── 元素专属刻度（主刻度之外、经实测锚定的节奏）──────────────────
  // 这些不是"新档位"，而是某个具体元素的开合/扫描节奏；集中在此避免散落。

  /// 展开/收起（工具卡、条目折叠）。
  static const Duration unfold = Duration(milliseconds: 160);

  /// 折叠（AnimatedSize 类双向尺寸过渡）。
  static const Duration fold = Duration(milliseconds: 180);

  /// 分页步进（引导页等一步一屏的位移）。
  static const Duration step = Duration(milliseconds: 220);

  /// 幕线扫过（单次入场扫描）。
  static const Duration sweep = Duration(milliseconds: 240);

  // ── 循环节奏（repeat / repeat-reverse 的周期）────────────────────
  // 循环动效在减弱动态下**不得启动**（守卫断言）；消费面须跳静态终态。

  /// 流式光标闪烁周期。
  static const Duration blink = Duration(milliseconds: 540);

  /// 呼吸/光标脉冲周期。
  static const Duration pulse = Duration(milliseconds: 800);

  /// 输入区脉冲周期（与 [pulse] 同法不同相位）。
  static const Duration pulseSoft = Duration(milliseconds: 900);

  /// 打字点循环 / 微光扫掠周期。
  static const Duration loop = Duration(milliseconds: 1200);

  /// 呼吸点周期（状态点上最慢的一档）。
  static const Duration breathe = Duration(milliseconds: 1500);

  // ── 曲线语义槽 ───────────────────────────────────────────────────
  // 全部为减速或对称曲线；禁 bounce / elastic / 任何带回弹的 spring。

  /// 标准减速：位移、状态过渡的默认曲线。
  static const Curve easeStandard = Curves.easeOut;

  /// 双向缓入缓出：尺寸/颜色开合、循环呼吸。
  static const Curve easeBoth = Curves.easeInOut;

  /// 强调减速：跳转、步进等较大位移。
  static const Curve easeEmphasis = Curves.easeOutCubic;

  /// 强减速：短距离快速收束（原 GlassMotion.easeMove 与
  /// Curves.easeOutQuart 同值， 合一）。
  static const Curve easeSnap = Curves.easeOutQuart;

  /// 颜色/透明度专用减速（自定义 cubic，波尔多夜间白药丸按压反馈在用）。
  static const Curve easeColor = Cubic(0.33, 1, 0.68, 1);

  /// 加速段（仅用于对称往返的后半程，与 [easeStandard] 成对使用）。
  static const Curve easeRecede = Curves.easeIn;

  /// 无补间。
  static const Curve linear = Curves.linear;

  // ── 几何（动效过程量）────────────────────────────────────────────

  /// 模态入场缩放起点（fade + scale → 1）。
  static const double modalScaleFrom = 0.97;

  // ── 减弱动态 ─────────────────────────────────────────────────────

  /// 是否处于减弱动态。
  ///
  /// 判据取全仓历史上的最严并集：`disableAnimations`（OS「减少动态效果」）
  /// 或 `accessibleNavigation`（辅助导航）任一为真。此前 21 处消费点判据不
  /// 一致（部分只看前者），本轮统一到此处（对无障碍偏好只会更保守）。
  static bool reducedMotion(BuildContext context) =>
      (MediaQuery.maybeDisableAnimationsOf(context) ?? false) ||
      MediaQuery.accessibleNavigationOf(context);

  /// 是否允许启动动画（减弱动态下为 false：消费面据此直接跳终态）。
  static bool shouldAnimate(BuildContext context) => !reducedMotion(context);

  /// 时长降级：减弱动态 → [instant]（直接终态），否则取 [normal]。
  ///
  /// 仅用于**一次性**过渡（入场/开合/位移）。循环动效不要用本方法把时长压到
  /// 零（`repeat()` 会空转），应改用 [shouldAnimate] 判断后不启动。
  static Duration durationFor(BuildContext context, Duration normal) =>
      reducedMotion(context) ? instant : normal;

  /// 时长降级（保留最小可感淡入，适合「骤然消失会被当成渲染故障」的场景）。
  static Duration fadeFor(BuildContext context, Duration normal) =>
      reducedMotion(context) ? micro : normal;
}
