import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/system/lm_button_metrics.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';
import 'package:lmstory/core/theme/system/lm_shortcuts.dart';
import 'package:lmstory/core/theme/system/lm_structure.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/system/structures/glass/glass_materials.dart';
import 'package:lmstory/core/theme/system/structures/glass/glass_radii.dart';
import 'package:lmstory/core/theme/system/structures/glass/glass_text_styles.dart';

/// 琉璃组件工厂（§2.8 清单闭集，18 个）。
///
/// 每个工厂锁定 材质档 × 圆角档 × 字层 × 状态集；工厂之外不新增容器
/// 语法。全部经 `context.lm` 取槽位；材质/几何/动效来自结构常量
/// （动效一律取 [LmMotion]，本轮起零散字面量由守卫测试拦停）。
/// bgGlow 唯一消费点=[GlassBackdrop]；（BackdropFilter）白名单闭集=
/// [GlassModal] / [GlassBottomSheet] / [GlassFloatingBar]（同屏 ≤2 由
/// [GlassT0Tracker] 运行时对账，流式中 floatingBar 降级）。
///
/// ── 交互五态（完备化）──────────────────────────────────────────
/// 交互件（panel / card / pillButton / input / listRow / settingRow /
/// banner / chip / segmented）共用一套状态语义，档位全部取自白玻璃台阶
/// 与语义槽，不新造色：
/// - rest     基档（fill6 / fill10 / surface / transparent）
/// - hover    基档 +1 级（fill6→fill10，fill10→fill16，透明→fill6）
/// - pressed  基档 +2 级（fill6→fill16，fill10→fill22，透明→fill10）
/// - focus    accent 2px 环 + focusGlow(accent) 辉光，**不换底**
/// - disabled surfaceVariant / faint 描边 + 内容降比（形态仍可辨，不隐形）
/// - loading  rest 视觉 + accent 尾部指示器，交互一律抑制
/// 纯装饰件（backdrop / readingCard / sectionHeader / modal / bottomSheet /
/// floatingBar / tag / snackBar / divider）无交互语义，不参与状态集。

// ── 1. backdrop 场地装饰（唯一 bgGlow 消费点）────────────────────

/// 场地在场标记：由 [GlassBackdrop] 安装，供 `scaffoldBgOf` 判定
/// 「透明底之下确实有场地渐变承接」。
///
/// 若某页面不在任何场地之下（脱离 `MaterialApp.builder` 的导航器、
/// 自建 Overlay / 独立 Navigator），透明底会透出空黑。此时
/// `scaffoldBgOf` 必须回落到 palette.bg——这是「永不透出黑」的兜底。
class GlassVenueScope extends InheritedWidget {
  const GlassVenueScope({required super.child, super.key});

  static GlassVenueScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<GlassVenueScope>();

  @override
  bool updateShouldNotify(GlassVenueScope oldWidget) => false;
}

/// 根场地：对角渐变（左下 bgGlow → 右上 bg）+ 可选暗角。
///
/// 静态绘制（1–2 层 Decoration，无逐帧动画、无 blur、无 ImageFilter）；
/// 流式期照常存在。光晕端点放屏幕角部，主体内容列从渐变中段开始。
class GlassBackdrop extends StatelessWidget {
  const GlassBackdrop({super.key, this.vignette = true, this.child});

  /// 暗角（RadialGradient 反向 overlay）；低端屏可关。
  final bool vignette;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final palette = context.lm.palette;
    return RepaintBoundary(
      child: GlassVenueScope(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomLeft,
              end: Alignment.topRight,
              colors: [palette.bgGlow, palette.bg],
            ),
          ),
          child: vignette
              ? DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      radius: 1.2,
                      colors: [
                        const Color(0x00000000),
                        Colors.black.withValues(alpha: 0.18),
                      ],
                    ),
                  ),
                  child: child,
                )
              : child,
        ),
      ),
    );
  }
}

// ── 五态原语（18 工厂共用；工厂之外不新增容器语法）────────────────

/// 交互五态快照。
class _GlassStates {
  const _GlassStates({
    this.hovered = false,
    this.focused = false,
    this.pressed = false,
    this.enabled = true,
  });

  final bool hovered;

  /// 焦点高亮：默认按 focus-visible（键盘导航才亮环）；输入类件传
  /// `focusVisibleOnly: false`，改为「只要有输入焦点就亮」——文本输入
  /// 的焦点必须始终可见（输入类件的标准例外）。
  final bool focused;

  final bool pressed;
  final bool enabled;

  bool get disabled => !enabled;
}

/// 控件激活键（Enter / Space）→ `ActivateIntent`。
///
/// 键位来自快捷键注册表（[LmShortcuts.idControlActivate]）而不是就地写死
/// `SingleActivator` 字面量——玻璃件的键盘可达性与页面/浮层级同源，
/// 「这个键干什么」全仓只有一份答案（守卫扫裸 `SingleActivator`）。
/// `static final` 缓存：本件是热路径，不按 build 次数重建绑定表。
final Map<ShortcutActivator, Intent> _activationShortcuts =
    LmShortcuts.intentBindings(
  LmShortcuts.idControlActivate,
  const ActivateIntent(),
);

/// 五态采集器：hover + focus-visible + pressed + disabled。
///
/// focus-visible 语义由 [FocusableActionDetector.onShowFocusHighlight] 提供
/// （鼠标点击不点亮焦点环）；键盘 Enter/Space 经 ActivateIntent 映射到
/// [onActivate]，保证玻璃件键盘可达（本轮 a11y 对账项）。
class _GlassInteractive extends StatefulWidget {
  const _GlassInteractive({
    required this.enabled,
    required this.builder,
    this.onActivate,
    this.focusNode,
    this.autofocus = false,
    this.focusVisibleOnly = true,
    this.cursor = SystemMouseCursors.click,
  });

  final bool enabled;
  final VoidCallback? onActivate;
  final Widget Function(BuildContext context, _GlassStates states) builder;
  final FocusNode? focusNode;
  final bool autofocus;
  final bool focusVisibleOnly;
  final MouseCursor cursor;

  @override
  State<_GlassInteractive> createState() => _GlassInteractiveState();
}

class _GlassInteractiveState extends State<_GlassInteractive> {
  bool _hovered = false;
  bool _showFocusHighlight = false;
  bool _hasFocus = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      enabled: widget.enabled,
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      mouseCursor: widget.enabled ? widget.cursor : MouseCursor.defer,
      onShowFocusHighlight: (value) {
        if (_showFocusHighlight != value) {
          setState(() => _showFocusHighlight = value);
        }
      },
      onShowHoverHighlight: (value) {
        if (_hovered != value) {
          setState(() => _hovered = value);
        }
      },
      onFocusChange: (value) {
        if (_hasFocus != value) {
          setState(() => _hasFocus = value);
        }
      },
      shortcuts: widget.onActivate != null ? _activationShortcuts : null,
      actions: widget.onActivate != null
          ? <Type, Action<Intent>>{
              ActivateIntent: CallbackAction<ActivateIntent>(
                onInvoke: (_) {
                  widget.onActivate?.call();
                  return null;
                },
              ),
            }
          : null,
      child: Listener(
        onPointerDown: widget.enabled
            ? (_) {
                if (!_pressed) setState(() => _pressed = true);
              }
            : null,
        onPointerUp: (_) {
          if (_pressed) setState(() => _pressed = false);
        },
        onPointerCancel: (_) {
          if (_pressed) setState(() => _pressed = false);
        },
        child: widget.builder(
          context,
          _GlassStates(
            hovered: _hovered,
            focused: widget.focusVisibleOnly ? _showFocusHighlight : _hasFocus,
            pressed: _pressed,
            enabled: widget.enabled,
          ),
        ),
      ),
    );
  }
}

/// 交互包装：静态件（无 onTap 且 enabled）走原路径——**不引入任何
/// Focus / MouseRegion 节点**，避免给纯容器凭空加焦点停靠点。
Widget _glassInteractive({
  required bool interactive,
  required bool enabled,
  required Widget Function(_GlassStates states) builder,
  VoidCallback? onTap,
  FocusNode? focusNode,
  bool autofocus = false,
  bool focusVisibleOnly = true,
  MouseCursor cursor = SystemMouseCursors.click,
}) {
  if (!interactive) return builder(const _GlassStates());
  return _GlassInteractive(
    enabled: enabled,
    onActivate: onTap,
    focusNode: focusNode,
    autofocus: autofocus,
    focusVisibleOnly: focusVisibleOnly,
    cursor: cursor,
    builder: (_, states) => builder(states),
  );
}

/// focus-visible 焦点环：accent 2px；四组合（结构 × 配色）下环色取当前
/// 配色族 accent，故「琉璃+经典」为琥珀、「琉璃+波尔多」为粉红，恒可见。
BorderSide _glassFocusRing(Color accent) =>
    BorderSide(color: accent, width: GlassMaterials.focusRingWidth);

/// focus-visible 辉光：focusGlow(accent)（已收口为运行时派生）。
List<BoxShadow> _glassFocusGlow(Color accent) => [
      BoxShadow(
        color: GlassMaterials.focusGlow(accent),
        blurRadius: GlassMaterials.focusGlowBlur,
      ),
    ];

/// 禁用态内容降比：文字/图标落到 faint，形状与描边保留。
Widget _glassDisabledContent(Color faint, Widget child) => IconTheme.merge(
      data: IconThemeData(color: faint),
      child: DefaultTextStyle.merge(
        style: TextStyle(color: faint),
        child: child,
      ),
    );

/// 五态描边：focus 环 > 禁用描边 > [rest]（各工厂静止描边，默认无）。
Border? _glassStateBorder(
  _GlassStates states, {
  required Color accent,
  required Color faint,
  BorderSide rest = BorderSide.none,
}) {
  if (states.focused) return Border.fromBorderSide(_glassFocusRing(accent));
  if (states.disabled) {
    return Border.fromBorderSide(
      BorderSide(
        color: faint.withValues(alpha: GlassMaterials.disabledBorderAlpha),
      ),
    );
  }
  return rest == BorderSide.none ? null : Border.fromBorderSide(rest);
}

/// 玻璃件尾部加载指示器（loading 态）。
///
/// 说明：不定进度指示器在减弱动态下**保留**——它承载「正在处理」这一状态
/// 信息（WCAG 2.3.3 的 essential 例外），不属于装饰性过渡动效。
class _GlassLoadingDot extends StatelessWidget {
  const _GlassLoadingDot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 14,
      height: 14,
      child: CircularProgressIndicator(strokeWidth: 2, color: color),
    );
  }
}

// ── 2/3. panel / card（平玻璃）────────────────────────────────

/// 面板：侧栏/分组容器/上下文面板。 fill6 + card 圆角，hover fill10。
///
/// 无 [onTap] 时为静态容器（零 Focus / 零 MouseRegion）；给了 [onTap] 或
/// [enabled] 为 false 才进入交互状态集。
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    required this.child,
    super.key,
    this.padding = const EdgeInsets.all(16),
    this.floating = false,
    this.onTap,
    this.enabled = true,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final bool floating;
  final VoidCallback? onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final palette = context.lm.palette;

    Widget face(BuildContext context, _GlassStates states) {
      final Color? fill;
      if (states.disabled) {
        fill = palette.surfaceVariant;
      } else if (states.pressed) {
        fill = GlassMaterials.fill16(palette.bg);
      } else if (states.hovered) {
        fill = GlassMaterials.fill10(palette.bg);
      } else {
        fill = GlassMaterials.fill6(palette.bg);
      }
      return DecoratedBox(
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(GlassRadii.card),
          border: states.focused
              ? Border.fromBorderSide(_glassFocusRing(palette.accent))
              : states.disabled
                  ? Border.fromBorderSide(
                      BorderSide(
                        color: palette.faint.withValues(
                          alpha: GlassMaterials.disabledBorderAlpha,
                        ),
                      ),
                    )
                  : const Border(
                      top: BorderSide(color: GlassMaterials.topInnerHighlight),
                    ),
          boxShadow: states.focused
              ? _glassFocusGlow(palette.accent)
              : floating
                  ? GlassMaterials.floatShadow(brightness)
                  : null,
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: states.enabled ? onTap : null,
            canRequestFocus: false,
            borderRadius: BorderRadius.circular(GlassRadii.card),
            child: Padding(
              padding: padding,
              child: states.disabled
                  ? _glassDisabledContent(palette.faint, child)
                  : child,
            ),
          ),
        ),
      );
    }

    return _glassInteractive(
      interactive: onTap != null || !enabled,
      enabled: enabled,
      onTap: onTap,
      builder: (states) => face(context, states),
    );
  }
}

/// 卡片：会话卡/设置卡/记忆卡。 fill6（浮起加短阴影），选中 fill16。
/// hover fill10 / pressed fill16 / focus 环 / disabled 形态保留。
class GlassCard extends StatelessWidget {
  const GlassCard({
    required this.child,
    super.key,
    this.padding = const EdgeInsets.all(16),
    this.floating = false,
    this.selected = false,
    this.onTap,
    this.enabled = true,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final bool floating;
  final bool selected;
  final VoidCallback? onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final palette = context.lm.palette;

    final brightness = Theme.of(context).brightness;
    Widget face(BuildContext context, _GlassStates states) {
      final Color fill;
      if (states.disabled) {
        fill = palette.surfaceVariant;
      } else if (states.pressed) {
        fill = GlassMaterials.fill16(palette.bg);
      } else if (states.hovered) {
        fill = GlassMaterials.fill10(palette.bg);
      } else if (selected) {
        fill = GlassMaterials.fill16(palette.bg);
      } else {
        fill = GlassMaterials.fill6(palette.bg);
      }
      return DecoratedBox(
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(GlassRadii.card),
          border: states.focused
              ? Border.fromBorderSide(_glassFocusRing(palette.accent))
              : states.disabled
                  ? Border.fromBorderSide(
                      BorderSide(
                        color: palette.faint.withValues(
                          alpha: GlassMaterials.disabledBorderAlpha,
                        ),
                      ),
                    )
                  : const Border(
                      top: BorderSide(color: GlassMaterials.topInnerHighlight),
                    ),
          boxShadow: states.focused
              ? _glassFocusGlow(palette.accent)
              : floating
                  ? GlassMaterials.floatShadow(brightness)
                  : null,
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: states.enabled ? onTap : null,
            canRequestFocus: false,
            borderRadius: BorderRadius.circular(GlassRadii.card),
            child: Padding(
              padding: padding,
              child: states.disabled
                  ? _glassDisabledContent(palette.faint, child)
                  : child,
            ),
          ),
        ),
      );
    }

    return _glassInteractive(
      interactive: onTap != null || !enabled,
      enabled: enabled,
      onTap: onTap,
      builder: (states) => face(context, states),
    );
  }
}

// ── 4. readingCard 阅读卡（surface 不透明；零 blur 零 glow）────────

/// 阅读卡：稿件卡/Recap。surface 不透明填充（流式重绘不透底、对比度稳定），
/// 流式宿主；readingWidth 限宽由消费面用 [LmReadingConstraints] 施加。
class GlassReadingCard extends StatelessWidget {
  const GlassReadingCard({
    required this.child,
    super.key,
    this.padding = const EdgeInsets.all(20),
    this.floating = true,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final bool floating;

  @override
  Widget build(BuildContext context) {
    final palette = context.lm.palette;
    final brightness = Theme.of(context).brightness;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(GlassRadii.card),
        boxShadow: floating ? GlassMaterials.floatShadow(brightness) : null,
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}

// ── 5. pillButton 药丸按钮（实体主操作）────────────────────────

enum GlassPillVariant { primary, secondary, ghost, destructive }

/// 药丸按钮。primary=（夜间白药丸+深字；日间酒药丸+浅字，每屏至多一颗）；
/// secondary= fill10；ghost 无底；destructive=error 填充+onPrimary 深字
/// （夜间）或 error 填充+onPrimary 浅字（日间）。focus=accent 环+glow。
///
/// 五态：hover 上一档；pressed 上两档+ scale（减弱动态下不启动）；
/// 方向与档位均由 `GlassMaterials` 从底面亮度派生，本件只选底面。
/// disabled 保留 surfaceVariant 形态 + faint 内容（不隐形）；loading 抑制
/// 交互并在尾部挂 accent 指示器。
class GlassPillButton extends StatelessWidget {
  const GlassPillButton({
    required this.label,
    required this.onPressed,
    super.key,
    this.variant = GlassPillVariant.primary,
    this.focusNode,
    this.autofocus = false,
    this.loading = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final GlassPillVariant variant;
  final FocusNode? focusNode;
  final bool autofocus;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final palette = context.lm.palette;
    final enabled = onPressed != null && !loading;

    // 台阶方向由「叠色即将压上去的那一层」的亮度派生。
    // ghost 没有自己的面 → 底面就是场地；secondary 的面是半透明台阶压在
    // 场地上的合成结果，必须先合成再判方向（半透明台阶的 rgb 恒为 0 或
    // 255，直接拿它判方向会得到错误的结论）。
    final venue = palette.bg;
    late final Color background;
    late final Color foreground;
    late final Color stepBase;
    switch (variant) {
      case GlassPillVariant.primary:
        background = palette.primary;
        foreground = palette.onPrimary;
        stepBase = palette.primary;
      case GlassPillVariant.secondary:
        background = GlassMaterials.fill10(venue);
        foreground = palette.ink;
        stepBase = GlassMaterials.stepped(venue, background);
      case GlassPillVariant.ghost:
        background = Colors.transparent;
        foreground = palette.ink;
        stepBase = venue;
      case GlassPillVariant.destructive:
        background = palette.error;
        foreground = palette.onPrimary;
        stepBase = palette.error;
    }

    Color fillOf(_GlassStates states) {
      if (states.disabled) return palette.surfaceVariant;
      if (states.pressed) {
        return Color.alphaBlend(GlassMaterials.fill16(stepBase), background);
      }
      if (states.hovered) {
        // 与面板/chip/行统一到同一条台阶（=hover / =pressed）。
        // 药丸的静息面是**裸底**（不含），故 hover 直接取 ；
        // 沿用旧的  时最没余量的底面（波尔多夜 error）只有 Δ8.7，不过线。
        return Color.alphaBlend(GlassMaterials.fill10(stepBase), background);
      }
      return background;
    }

    final labelColor = enabled ? foreground : palette.faint;

    return _glassInteractive(
      interactive: true,
      enabled: enabled,
      onTap: onPressed,
      focusNode: focusNode,
      autofocus: autofocus,
      builder: (states) => _PressedScale(
        pressed: states.pressed,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: states.disabled ? palette.surfaceVariant : fillOf(states),
            borderRadius: BorderRadius.circular(GlassRadii.stadium),
            border: _glassStateBorder(
              states,
              accent: palette.accent,
              faint: palette.faint,
            ),
            boxShadow: states.focused ? _glassFocusGlow(palette.accent) : null,
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: states.enabled ? onPressed : null,
              canRequestFocus: false,
              borderRadius: BorderRadius.circular(GlassRadii.stadium),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 10,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        color: labelColor,
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        height: 1.4,
                      ),
                    ),
                    if (loading) ...[
                      const SizedBox(width: 8),
                      _GlassLoadingDot(color: labelColor),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PressedScale extends StatelessWidget {
  const _PressedScale({required this.pressed, required this.child});

  final bool pressed;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // 减弱动态：不启动任何补间，直接返回终态（守卫：不启动动画）。
    if (!LmMotion.shouldAnimate(context)) return child;
    return AnimatedScale(
      scale: pressed ? GlassMaterials.pressedScale : 1.0,
      duration: LmMotion.press,
      curve: LmMotion.easeSnap,
      child: child,
    );
  }
}

// ── 6. input 输入框（resting  / focus  焦点环）────────────────

/// 输入框容器（配 TextField 使用）：resting=surfaceVariant；hover=fill6；
/// focus=fill16 + accent 焦点环 + glow；disabled=surfaceVariant + faint 描边。
///
/// 焦点例外：输入件按 **hasFocus** 亮环（不使用 focus-visible 抑制）——
/// 文本输入焦点必须始终可见；[focusNode] 应同时交给内部 TextField，二者
/// 共用同一节点（已确立「同一焦点节点只挂一个 Focus」）。
class GlassInput extends StatefulWidget {
  const GlassInput({
    required this.child,
    super.key,
    this.hint,
    this.enabled = true,
    this.focusNode,
  });

  final Widget child;
  final String? hint;
  final bool enabled;
  final FocusNode? focusNode;

  @override
  State<GlassInput> createState() => _GlassInputState();
}

class _GlassInputState extends State<GlassInput> {
  FocusNode? _ownedFocusNode;

  FocusNode get _focusNode =>
      widget.focusNode ?? (_ownedFocusNode ??= FocusNode());

  @override
  void dispose() {
    _ownedFocusNode?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.lm.palette;
    return _GlassInteractive(
      enabled: widget.enabled,
      focusNode: _focusNode,
      focusVisibleOnly: false,
      cursor: SystemMouseCursors.text,
      builder: (context, states) => DecoratedBox(
        decoration: BoxDecoration(
          color: states.disabled
              ? palette.surfaceVariant
              : states.focused
                  ? GlassMaterials.fill16(palette.surfaceVariant)
                  : states.hovered
                      ? GlassMaterials.fill6(palette.surfaceVariant)
                      : palette.surfaceVariant,
          borderRadius: BorderRadius.circular(GlassRadii.input),
          border: _glassStateBorder(
            states,
            accent: palette.accent,
            faint: palette.faint,
            rest: const BorderSide(color: Colors.transparent),
          ),
          boxShadow: states.focused ? _glassFocusGlow(palette.accent) : null,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          // 同一焦点节点只允许挂一个 Focus：内层曾再包一颗同节点
          // Focus，装配即触发「child into a parent of itself」断言
          // （辉光守卫实锤；工厂此前零生产消费故未暴露）。
          child: states.disabled
              ? _glassDisabledContent(palette.faint, widget.child)
              : widget.child,
        ),
      ),
    );
  }
}

// ── 7/8. listRow / settingRow（台阶）────────────────────────────

/// 列表行：透明→hover fill6→selected fill16→pressed fill10；选中态文字一律
/// ink；focus 环 accent；disabled 保留轮廓 + 内容降比。
class GlassListRow extends StatelessWidget {
  const GlassListRow({
    required this.child,
    super.key,
    this.selected = false,
    this.onTap,
    this.enabled = true,
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
  });

  final Widget child;
  final bool selected;
  final VoidCallback? onTap;
  final bool enabled;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final palette = context.lm.palette;

    return _glassInteractive(
      interactive: onTap != null || !enabled,
      enabled: enabled,
      onTap: onTap,
      builder: (states) {
        Color? fill;
        if (states.disabled) {
          fill = null;
        } else if (selected) {
          fill = GlassMaterials.fill16(palette.bg);
        } else if (states.pressed) {
          fill = GlassMaterials.fill10(palette.bg);
        } else if (states.hovered) {
          fill = GlassMaterials.fill6(palette.bg);
        }
        return DecoratedBox(
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(GlassRadii.input),
            border: _glassStateBorder(
              states,
              accent: palette.accent,
              faint: palette.faint,
            ),
            boxShadow: states.focused ? _glassFocusGlow(palette.accent) : null,
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: states.enabled ? onTap : null,
              canRequestFocus: false,
              borderRadius: BorderRadius.circular(GlassRadii.input),
              child: Padding(
                padding: padding,
                child: states.disabled
                    ? _glassDisabledContent(palette.faint, child)
                    : child,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 设置行（标题+说明+值）：listRow 语义 + 尾 chevron；值一律技术字幕层。
class GlassSettingRow extends StatelessWidget {
  const GlassSettingRow({
    required this.title,
    super.key,
    this.subtitle,
    this.value,
    this.onTap,
    this.selected = false,
    this.enabled = true,
  });

  final String title;
  final String? subtitle;
  final String? value;
  final VoidCallback? onTap;
  final bool selected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final palette = context.lm.palette;
    final titleColor = enabled ? palette.ink : palette.faint;
    final onSelected = enabled && selected;
    return GlassListRow(
      selected: onSelected,
      onTap: onTap,
      enabled: enabled,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: onSelected ? palette.ink : titleColor,
                    fontSize: 15,
                    fontWeight: FontWeight.w400,
                    height: 1.5,
                  ),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: TextStyle(
                      color: enabled ? palette.muted : palette.faint,
                      fontSize: 12,
                      fontWeight: FontWeight.w400,
                      height: 1.4,
                    ),
                  ),
              ],
            ),
          ),
          if (value != null)
            Padding(
              padding: const EdgeInsets.only(left: 12),
              child: Text(
                value!,
                style: GlassTextStyles.metaValue.copyWith(
                  color: enabled ? palette.muted : palette.faint,
                ),
              ),
            ),
          Icon(Icons.chevron_right, size: 20, color: palette.faint),
        ],
      ),
    );
  }
}

// ── 9. sectionHeader 分区头（技术字幕层）──────────────────────────

/// 分区头：mono 大写宽字距 `//` 前缀语法；默认 muted、活动 accent。
class GlassSectionHeader extends StatelessWidget {
  const GlassSectionHeader(this.label, {super.key, this.active = false});

  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final palette = context.lm.palette;
    return Text(
      '// ${label.toUpperCase()}',
      style: GlassTextStyles.sectionHeader.copyWith(
        color: active ? palette.accent : palette.muted,
      ),
    );
  }
}

// ── 10. banner 横幅（四语义）──────────────────────────────────────

enum GlassBannerTone { info, success, warning, error, accent }

/// 横幅：info=fill10；success/warning/error=语义色@15%；accent 活动=accentDim。
/// 文字配对已验算（语义色文字对语义@15% 合成底全过）。
///
/// 五态：hover/pressed 在语义底上叠白玻璃台阶；focus accent 环；disabled
/// 形态保留 + 内容降比。
class GlassBanner extends StatelessWidget {
  const GlassBanner({
    required this.message,
    required this.tone,
    super.key,
    this.onTap,
    this.enabled = true,
  });

  final String message;
  final GlassBannerTone tone;
  final VoidCallback? onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final palette = context.lm.palette;
    final (baseFill, fg) = switch (tone) {
      GlassBannerTone.info => (
          GlassMaterials.fill10(palette.bg),
          palette.ink,
        ),
      GlassBannerTone.success => (
          palette.success.withValues(alpha: 0.15),
          palette.success
        ),
      GlassBannerTone.warning => (
          palette.warning.withValues(alpha: 0.15),
          palette.warning
        ),
      GlassBannerTone.error => (
          palette.error.withValues(alpha: 0.15),
          palette.error
        ),
      GlassBannerTone.accent => (palette.accentDim, palette.ink),
    };
    // 横幅自己的面 = 半透明底压在场地上的合成结果；台阶方向按它判。
    final bannerFace = GlassMaterials.stepped(palette.bg, baseFill);

    return _glassInteractive(
      interactive: onTap != null || !enabled,
      enabled: enabled,
      onTap: onTap,
      builder: (states) {
        final fill = states.disabled
            ? palette.surfaceVariant
            : states.pressed
                ? Color.alphaBlend(
                    GlassMaterials.fill16(bannerFace),
                    baseFill,
                  )
                : states.hovered
                    ? Color.alphaBlend(
                        GlassMaterials.fill6(bannerFace),
                        baseFill,
                      )
                    : baseFill;
        final textColor = states.disabled ? palette.faint : fg;
        return DecoratedBox(
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(GlassRadii.input),
            border: _glassStateBorder(
              states,
              accent: palette.accent,
              faint: palette.faint,
            ),
            boxShadow: states.focused ? _glassFocusGlow(palette.accent) : null,
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: states.enabled ? onTap : null,
              canRequestFocus: false,
              borderRadius: BorderRadius.circular(GlassRadii.input),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                child: Text(
                  message,
                  style: TextStyle(
                    color: textColor,
                    fontSize: 14,
                    fontWeight: FontWeight.w400,
                    height: 1.4,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ── 11. modal 模态（白名单①）──────────────────────────────────

/// （真 blur）同屏实例运行时对账。
///
/// 静态白名单守卫（glass_redline_guard_test ①②）只保证 BackdropFilter
/// 源码闭集 3 处；「同屏 ≤2」红线此前无运行时对账。三类  工厂的
/// BackdropFilter 均经 [_T0BlurScope] 挂载：进入 +1、销毁 −1，
/// debug 下超限即断言失败。
abstract final class GlassT0Tracker {
  static int _live = 0;

  /// 当前存活的 （真 blur）实例数（守卫测试读取）。
  static int get live => _live;

  /// 仅供守卫测试隔离使用（生产代码禁止调用）。
  @visibleForTesting
  static void resetForTest() => _live = 0;

  static void _enter() {
    _live++;
    assert(
      _live <= 2,
      'T0 (real blur) live instances exceeded: $_live > 2. Red line: the '
      'modal/bottomSheet/floatingBar closed allowlist allows <= 2 on screen; '
      'stacked overlays must downgrade to T1 or consolidate overlays.',
    );
  }

  static void _exit() {
    _live--;
  }
}

///  计数挂载点：包住 BackdropFilter 子树，随挂载/销毁对账。
class _T0BlurScope extends StatefulWidget {
  const _T0BlurScope({required this.child});

  final Widget child;

  @override
  State<_T0BlurScope> createState() => _T0BlurScopeState();
}

class _T0BlurScopeState extends State<_T0BlurScope> {
  @override
  void initState() {
    super.initState();
    GlassT0Tracker._enter();
  }

  @override
  void dispose() {
    GlassT0Tracker._exit();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// 模态容器（：scrim + blur24 + surfaceElevated 合成）。
/// 开=fade+scale0.97→1；关=crossfade；流式中禁 blur 动画（入场纯 fade）。
/// 每模态一颗  主操作由消费面保证。
class GlassModal extends StatelessWidget {
  const GlassModal({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final palette = context.lm.palette;
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(GlassRadii.card),
        child: _T0BlurScope(
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(
              sigmaX: GlassMaterials.t0Blur,
              sigmaY: GlassMaterials.t0Blur,
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Color.alphaBlend(
                  GlassMaterials.t0Fill,
                  palette.surfaceElevated,
                ),
                borderRadius: BorderRadius.circular(GlassRadii.card),
                border: const Border(
                  top: BorderSide(color: GlassMaterials.topInnerHighlight),
                ),
                boxShadow: GlassMaterials.t0Shadow,
              ),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

// ── 12. bottomSheet 底部动作条（白名单②）──────────────────────

/// 底部弹层容器（blur24；顶角 card；拖拽把手 stadium）。
///
/// [showHandle] 供统一浮层入口（lm_overlays.showLmSheet）在内容件已
/// 自绘把手时关掉工厂把手，避免双把手；直读本工厂时保持默认开。
class GlassBottomSheet extends StatelessWidget {
  const GlassBottomSheet({
    required this.child,
    super.key,
    this.showHandle = true,
  });

  final Widget child;

  /// 是否渲染工厂拖拽把手。
  final bool showHandle;

  @override
  Widget build(BuildContext context) {
    final palette = context.lm.palette;
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(
        top: Radius.circular(GlassRadii.card),
      ),
      child: _T0BlurScope(
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(
            sigmaX: GlassMaterials.t0Blur,
            sigmaY: GlassMaterials.t0Blur,
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Color.alphaBlend(
                GlassMaterials.t0Fill,
                palette.surfaceElevated,
              ),
              border: const Border(
                top: BorderSide(color: GlassMaterials.topInnerHighlight),
              ),
            ),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (showHandle) ...[
                    const SizedBox(height: 10),
                    Center(
                      child: Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: GlassMaterials.fill22(palette.bg),
                          borderRadius: BorderRadius.circular(
                            GlassRadii.stadium,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],
                  Flexible(child: child),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── 13. floatingBar 悬浮操作条（白名单③；流式降级）─────────

/// 悬浮操作条（消息导航浮条/建议回复浮层）。
/// [streaming] 为真时降级 （平玻璃无 blur）——流式渲染红线。
class GlassFloatingBar extends StatelessWidget {
  const GlassFloatingBar({
    required this.child,
    super.key,
    this.streaming = false,
  });

  final Widget child;
  final bool streaming;

  @override
  Widget build(BuildContext context) {
    final palette = context.lm.palette;
    if (streaming) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: GlassMaterials.fill10(palette.bg),
          borderRadius: BorderRadius.circular(GlassRadii.stadium),
          border: const Border(
            top: BorderSide(color: GlassMaterials.topInnerHighlight),
          ),
        ),
        child: child,
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(GlassRadii.stadium),
      child: _T0BlurScope(
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(
            sigmaX: GlassMaterials.t0Blur,
            sigmaY: GlassMaterials.t0Blur,
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Color.alphaBlend(GlassMaterials.t0Fill, palette.surface),
              borderRadius: BorderRadius.circular(GlassRadii.stadium),
              border: const Border(
                top: BorderSide(color: GlassMaterials.topInnerHighlight),
              ),
              boxShadow: GlassMaterials.t0Shadow,
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

// ── 14/15. chip 药丸 / tag 小徽标 ──────────────────────────────────

/// 药丸 chip：过滤/标签选择。fill6→selected fill16；选中底文字 ink。
/// 五态：hover fill10、pressed fill16、focus accent 环、disabled 形态保留。
class GlassChip extends StatelessWidget {
  const GlassChip({
    required this.label,
    super.key,
    this.selected = false,
    this.onTap,
    this.enabled = true,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final palette = context.lm.palette;

    return _glassInteractive(
      interactive: onTap != null || !enabled,
      enabled: enabled,
      onTap: onTap,
      builder: (states) {
        final Color fill;
        if (states.disabled) {
          fill = palette.surfaceVariant;
        } else if (states.pressed || selected) {
          fill = GlassMaterials.fill16(palette.bg);
        } else if (states.hovered) {
          fill = GlassMaterials.fill10(palette.bg);
        } else {
          fill = GlassMaterials.fill6(palette.bg);
        }
        final textColor = states.disabled
            ? palette.faint
            : (selected || states.hovered || states.pressed)
                ? palette.ink
                : palette.muted;
        return DecoratedBox(
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(GlassRadii.stadium),
            border: _glassStateBorder(
              states,
              accent: palette.accent,
              faint: palette.faint,
            ),
            boxShadow: states.focused ? _glassFocusGlow(palette.accent) : null,
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: states.enabled ? onTap : null,
              canRequestFocus: false,
              borderRadius: BorderRadius.circular(GlassRadii.stadium),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                child: Text(
                  label,
                  style: TextStyle(
                    color: textColor,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    height: 1.5,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 小徽标：版本号/计数/状态点。mono captionSm；技术字幕层主战场。
class GlassTag extends StatelessWidget {
  const GlassTag(this.label, {super.key, this.color});

  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final palette = context.lm.palette;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: GlassMaterials.fill6(palette.bg),
        borderRadius: BorderRadius.circular(GlassRadii.chip),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Text(
          label,
          style: GlassTextStyles.metaCaps.copyWith(
            color: color ?? palette.muted,
          ),
        ),
      ),
    );
  }
}

// ── 16. segmented 分段控件 ─────────────────────────────────────────

/// 分段控件：轨道=surfaceVariant；thumb=fill22；thumb 上文字 ink；
/// 单选即时生效。
///
/// 五态（逐项）：hover fill10（未选中项）、pressed fill22、focus accent 环、
/// disabled 内容降比；分段项最小高度取触控红线 44（[LmButtonMetrics]）。
class GlassSegmented<T extends Enum> extends StatelessWidget {
  const GlassSegmented({
    required this.values,
    required this.selected,
    required this.onSelected,
    required this.labelOf,
    super.key,
    this.enabled = true,
  });

  final List<T> values;
  final T selected;
  final ValueChanged<T> onSelected;
  final String Function(T) labelOf;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final palette = context.lm.palette;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: palette.surfaceVariant,
        borderRadius: BorderRadius.circular(GlassRadii.stadium),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final value in values)
            _GlassSegmentedItem(
              label: labelOf(value),
              selected: value == selected,
              enabled: enabled,
              onActivate: () => onSelected(value),
            ),
        ],
      ),
    );
  }
}

class _GlassSegmentedItem extends StatelessWidget {
  const _GlassSegmentedItem({
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onActivate,
  });

  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback onActivate;

  @override
  Widget build(BuildContext context) {
    final palette = context.lm.palette;
    return _glassInteractive(
      interactive: true,
      enabled: enabled,
      onTap: onActivate,
      builder: (states) {
        final Color fill;
        if (!states.enabled) {
          fill = Colors.transparent;
        } else if (states.pressed || selected) {
          fill = GlassMaterials.fill22(palette.surfaceVariant);
        } else if (states.hovered) {
          fill = GlassMaterials.fill10(palette.surfaceVariant);
        } else {
          fill = Colors.transparent;
        }
        final Color foreground;
        if (states.disabled) {
          foreground = palette.faint;
        } else if (selected || states.hovered) {
          foreground = palette.ink;
        } else {
          foreground = palette.muted;
        }
        return AnimatedContainer(
          duration: LmMotion.durationFor(context, LmMotion.base),
          curve: LmMotion.easeColor,
          constraints: const BoxConstraints(
            minHeight: LmButtonMetrics.minInteractiveHeight,
          ),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(GlassRadii.stadium),
            border: _glassStateBorder(
              states,
              accent: palette.accent,
              faint: palette.faint,
            ),
            boxShadow: states.focused ? _glassFocusGlow(palette.accent) : null,
          ),
          child: Text(
            label,
            style: TextStyle(
              color: foreground,
              fontSize: 12,
              fontWeight: FontWeight.w500,
              height: 1.4,
            ),
          ),
        );
      },
    );
  }
}

// ── 17. snackBar 轻提示（floating + 语义左边线）────────────────────

enum GlassSnackBarTone { info, success, warning, error }

/// SnackBar 内容工厂（须以 floating behavior 展示——CI 守卫红线）。
/// 语义色左边线 3px 承载类型； fill10；stadium（短）。
class GlassSnackBar extends StatelessWidget {
  const GlassSnackBar(
    this.message, {
    super.key,
    this.tone = GlassSnackBarTone.info,
  });

  final String message;
  final GlassSnackBarTone tone;

  @override
  Widget build(BuildContext context) {
    final palette = context.lm.palette;
    final line = switch (tone) {
      GlassSnackBarTone.info => palette.accent,
      GlassSnackBarTone.success => palette.success,
      GlassSnackBarTone.warning => palette.warning,
      GlassSnackBarTone.error => palette.error,
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        color: GlassMaterials.fill10(palette.bg),
        borderRadius: BorderRadius.circular(GlassRadii.stadium),
        border: Border(
          left: BorderSide(color: line, width: 3),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Text(
          message,
          style: TextStyle(
            color: palette.ink,
            fontSize: 14,
            fontWeight: FontWeight.w400,
            height: 1.55,
          ),
        ),
      ),
    );
  }
}

// ── 18. divider 分隔线（装饰性）───────────────────────────────────

/// 分隔线：divider 槽 1px；仅密集列表必需处（层级优先材质分档）。
class GlassDivider extends StatelessWidget {
  const GlassDivider({super.key, this.indent = 0});

  final double indent;

  @override
  Widget build(BuildContext context) {
    return Divider(
      height: 1,
      thickness: 1,
      indent: indent,
      endIndent: indent,
      color: context.lm.palette.divider,
    );
  }
}
