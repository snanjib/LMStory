import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/system/lm_button_metrics.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';
import 'package:lmstory/core/theme/system/lm_shortcuts.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/system/structures/brutal/brutal_materials.dart';
import 'package:lmstory/core/theme/system/structures/brutal/brutal_radii.dart';
import 'package:lmstory/core/theme/system/structures/brutal/brutal_text_styles.dart';

/// 棱角组件工厂（首批 8 件，《棱角档案》§3 配方 + 03 计划 §3.1）。
///
/// 每个工厂锁定 描边档 × 圆角档 × 字层 × 状态集；工厂之外不新增容器
/// 语法。全部经 `context.lm` 取槽位；几何/材质/动效来自结构常量
/// （动效一律取 [LmMotion]，禁就地字面量）。
///
/// ── 交互五态 ──────────────────────────────────────────────────────
/// - rest     纸面（surface / surfaceVariant / 透明）+ 结构墨色描边
/// - hover    primaryDim 撞色台阶（可按压面）或位移预压（按钮）
/// - pressed  位移终态：元素平移 (4,4) 且阴影偏移归零（"按进纸里"）
/// - focus    accent 描边（功能标注走撞色预算；focus-visible 语义）
/// - disabled surfaceVariant + ink@50% 描边 + faint 内容（形态可辨）
/// - loading  rest 视觉 + accent 尾部静态方块，交互一律抑制
///
/// ── 红线（守卫测试化）─────────────────────────────────────────────
/// 禁 blur（一切阴影 blur 0）、禁渐变、禁 bounce；卡片静止零阴影——
/// 阴影只在可按压元素（按钮），层级靠描边三档表达。

// ── 五态原语（8 工厂共用；工厂之外不新增容器语法）──────────────────

/// 交互五态快照。
class _BrutalStates {
  const _BrutalStates({
    this.hovered = false,
    this.focused = false,
    this.pressed = false,
    this.enabled = true,
  });

  final bool hovered;
  final bool focused;
  final bool pressed;
  final bool enabled;

  bool get disabled => !enabled;
}

/// 控件激活键（Enter / Space）→ `ActivateIntent`（键位来自快捷键注册表
/// 单源，与玻璃件同源；static final 缓存热路径）。
final Map<ShortcutActivator, Intent> _activationShortcuts =
    LmShortcuts.intentBindings(
  LmShortcuts.idControlActivate,
  const ActivateIntent(),
);

/// 五态采集器：hover + focus-visible + pressed + disabled。
///
/// focus-visible 语义由 [FocusableActionDetector.onShowFocusHighlight]
/// 提供（鼠标点击不点亮焦点环）；键盘 Enter/Space 经 ActivateIntent
/// 映射到 [onActivate]，保证棱角件键盘可达。
class _BrutalInteractive extends StatefulWidget {
  const _BrutalInteractive({
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
  final Widget Function(BuildContext context, _BrutalStates states) builder;
  final FocusNode? focusNode;
  final bool autofocus;
  final bool focusVisibleOnly;
  final MouseCursor cursor;

  @override
  State<_BrutalInteractive> createState() => _BrutalInteractiveState();
}

class _BrutalInteractiveState extends State<_BrutalInteractive> {
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
          _BrutalStates(
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

/// 交互包装：静态件（无 onTap 且 enabled）走原路径——不给纯容器
/// 凭空加焦点停靠点。
Widget _brutalInteractive({
  required bool interactive,
  required bool enabled,
  required Widget Function(_BrutalStates states) builder,
  VoidCallback? onTap,
  FocusNode? focusNode,
  bool autofocus = false,
  bool focusVisibleOnly = true,
  MouseCursor cursor = SystemMouseCursors.click,
}) {
  if (!interactive) return builder(const _BrutalStates());
  return _BrutalInteractive(
    enabled: enabled,
    onActivate: onTap,
    focusNode: focusNode,
    autofocus: autofocus,
    focusVisibleOnly: focusVisibleOnly,
    cursor: cursor,
    builder: (_, states) => builder(states),
  );
}

/// 五态描边：focus（accent）> 禁用（结构墨色@50%）> rest（结构墨色）。
Border? _brutalStateBorder(
  _BrutalStates states, {
  required LmPalette palette,
  required double width,
}) {
  if (states.focused) {
    return Border.fromBorderSide(
      BorderSide(color: palette.accent, width: width),
    );
  }
  if (states.disabled) {
    return Border.fromBorderSide(
      BorderSide(
        color: BrutalMaterials.frameOf(palette)
            .withValues(alpha: BrutalMaterials.disabledOpacity),
        width: width,
      ),
    );
  }
  return Border.fromBorderSide(
    BorderSide(color: BrutalMaterials.frameOf(palette), width: width),
  );
}

/// 禁用态内容降比：文字/图标落到 faint，形状与描边保留。
Widget _brutalDisabledContent(Color faint, Widget child) => IconTheme.merge(
      data: IconThemeData(color: faint),
      child: DefaultTextStyle.merge(
        style: TextStyle(color: faint),
        child: child,
      ),
    );

/// 签名位移面：位移与阴影同一 [AnimatedContainer] 补间，保证同步。
///
/// 位移轴（rest → hover → pressed）：
/// - rest：元素 (0,0)，阴影 offset (4,4)；
/// - hover：元素 (2,2)（预压，阴影不动——阴影被元素遮挡一半而变薄）；
/// - pressed：元素 (4,4)，阴影 offset 归零（阴影落到元素正后方，
///   视觉等效消失——"按进纸里"）。
///
/// 曲线一律 [LmMotion.linear]（位移是等速物理平移，不做缓动修辞）；
/// 减弱动态下不启动补间，直接静态终态。
class _ShiftFace extends StatelessWidget {
  const _ShiftFace({
    required this.states,
    required this.decoration,
    required this.child,
  });

  final _BrutalStates states;
  final Decoration decoration;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final Offset shift;
    switch ((states.hovered, states.pressed)) {
      case (_, true):
        shift = BrutalRadii.pressOffset;
      case (true, false):
        shift = BrutalRadii.hoverOffset;
      case (false, false):
        shift = Offset.zero;
    }
    final duration = states.pressed ? LmMotion.press : LmMotion.hover;
    // 曲线不显式传：AnimatedContainer 默认 Curves.linear 即位移签名
    //（等速平移，无缓动修辞；守卫测试断言实际曲线恒 linear）。
    if (!LmMotion.shouldAnimate(context)) {
      return Container(
        transform: Matrix4.translationValues(shift.dx, shift.dy, 0),
        decoration: decoration,
        child: child,
      );
    }
    return AnimatedContainer(
      transform: Matrix4.translationValues(shift.dx, shift.dy, 0),
      duration: duration,
      decoration: decoration,
      child: child,
    );
  }
}

// ── 1. button 按钮（签名交互载体）──────────────────────────────────

enum BrutalButtonVariant { primary, secondary, destructive }

/// 按钮：填充色块 + frameInline 描边 + 实心阴影 + 按压"按进纸里"。
///
/// primary=primary 填充 + onPrimary 字（每屏至多一颗主操作）；
/// secondary=surface 纸面 + ink 字；destructive=error 填充 + onPrimary 字。
/// hover 预位移 (2,2)、pressed 平移 (4,4) 且阴影偏移同步归零
/// （[_ShiftFace] 位移轴）；度量（min 44 / padding / 标签字重）同源
/// [LmButtonMetrics]；disabled 去阴影（不漂浮）+ faint 内容；
/// loading 抑制交互并在尾部挂 accent 静态方块。
class BrutalButton extends StatelessWidget {
  const BrutalButton({
    required this.label,
    required this.onPressed,
    super.key,
    this.variant = BrutalButtonVariant.primary,
    this.focusNode,
    this.autofocus = false,
    this.loading = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final BrutalButtonVariant variant;
  final FocusNode? focusNode;
  final bool autofocus;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final palette = context.lm.palette;
    final enabled = onPressed != null && !loading;

    final (background, foreground) = switch (variant) {
      BrutalButtonVariant.primary => (palette.primary, palette.onPrimary),
      BrutalButtonVariant.secondary => (palette.surface, palette.ink),
      BrutalButtonVariant.destructive => (palette.error, palette.onPrimary),
    };

    return _brutalInteractive(
      interactive: true,
      enabled: enabled,
      onTap: onPressed,
      focusNode: focusNode,
      autofocus: autofocus,
      builder: (states) {
        final disabled = states.disabled;
        final fill = disabled ? palette.surfaceVariant : background;
        final labelColor = disabled ? palette.faint : foreground;
        return _ShiftFace(
          states: states,
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(BrutalRadii.cornerField),
            border: _brutalStateBorder(
              states,
              palette: palette,
              width: BrutalRadii.frameInline,
            ),
            // 阴影唯一公式：只在可用态出现（disabled 不漂浮）。
            boxShadow: disabled
                ? null
                : BrutalMaterials.shadow(
                    palette,
                    pressed: states.pressed,
                  ),
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: enabled ? onPressed : null,
              canRequestFocus: false,
              borderRadius: BorderRadius.circular(BrutalRadii.cornerField),
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: LmButtonMetrics.minInteractiveHeight,
                ),
                child: Padding(
                  padding: LmButtonMetrics.solidPadding,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        label,
                        style: LmButtonMetrics.label(
                          BrutalTextStyles.bodySm,
                        ).copyWith(color: labelColor),
                      ),
                      if (loading) ...[
                        const SizedBox(width: 8),
                        _BrutalLoadingBlock(color: palette.accent),
                      ],
                    ],
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

/// loading 静态指示方块（accent 铅字块；无循环动效——减弱动态零例外，
/// 「正在处理」由方块占位表达）。
class _BrutalLoadingBlock extends StatelessWidget {
  const _BrutalLoadingBlock({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(color: color),
      child: const SizedBox(width: 8, height: 8),
    );
  }
}

// ── 2. card 卡片（描边即层级，静止零阴影）─────────────────────────

/// 卡片：frameCard 描边 + 直角 + surface 纸面 + 静止零阴影
/// （两库共识：位移语言专属按钮，卡片保持静止；可交互卡的 hover
/// 走 primaryDim 撞色台阶，不走位移）。
class BrutalCard extends StatelessWidget {
  const BrutalCard({
    required this.child,
    super.key,
    this.padding = const EdgeInsets.all(16),
    this.selected = false,
    this.onTap,
    this.enabled = true,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final bool selected;
  final VoidCallback? onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final palette = context.lm.palette;

    return _brutalInteractive(
      interactive: onTap != null || !enabled,
      enabled: enabled,
      onTap: onTap,
      builder: (states) {
        final Color fill;
        if (states.disabled) {
          fill = palette.surfaceVariant;
        } else if (states.pressed || selected) {
          fill = Color.alphaBlend(
            palette.primary.withValues(alpha: BrutalMaterials.fillPressedAlpha),
            palette.surface,
          );
        } else if (states.hovered) {
          fill = Color.alphaBlend(palette.primaryDim, palette.surface);
        } else {
          fill = palette.surface;
        }
        return DecoratedBox(
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(BrutalRadii.cornerNone),
            border: _brutalStateBorder(
              states,
              palette: palette,
              width: BrutalRadii.frameCard,
            ),
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: states.enabled ? onTap : null,
              canRequestFocus: false,
              borderRadius: BorderRadius.circular(BrutalRadii.cornerNone),
              child: Padding(
                padding: padding,
                child: states.disabled
                    ? _brutalDisabledContent(palette.faint, child)
                    : child,
              ),
            ),
          ),
        );
      },
    );
  }
}

// ── 3. input 输入框容器（配 TextField 使用）────────────────────────

/// 输入框容器：surface 白纸底 + frameInline 描边 + cornerField；
/// focus（hasFocus，非 focus-visible——文本输入焦点必须始终可见）
/// 描边转 3px；disabled=surfaceVariant + faint 描边。
///
/// [focusNode] 应同时交给内部 TextField，二者共用同一节点。
class BrutalInput extends StatefulWidget {
  const BrutalInput({
    required this.child,
    super.key,
    this.enabled = true,
    this.focusNode,
  });

  final Widget child;
  final bool enabled;
  final FocusNode? focusNode;

  @override
  State<BrutalInput> createState() => _BrutalInputState();
}

class _BrutalInputState extends State<BrutalInput> {
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
    return _BrutalInteractive(
      enabled: widget.enabled,
      focusNode: _focusNode,
      focusVisibleOnly: false,
      cursor: SystemMouseCursors.text,
      builder: (context, states) => DecoratedBox(
        decoration: BoxDecoration(
          color: states.disabled ? palette.surfaceVariant : palette.surface,
          borderRadius: BorderRadius.circular(BrutalRadii.cornerField),
          border: states.focused
              ? Border.fromBorderSide(
                  BorderSide(
                    color: BrutalMaterials.frameOf(palette),
                    width: BrutalMaterials.focusFrameWidth,
                  ),
                )
              : _brutalStateBorder(
                  states,
                  palette: palette,
                  width: BrutalRadii.frameInline,
                ),
        ),
        child: widget.child,
      ),
    );
  }
}

// ── 4. checkbox 复选框（直角方块 + 主色填充）──────────────────────

/// 复选框：16×16 直角方块 + frameInline 描边；选中 = primary 填充 +
/// onPrimary 对勾；disabled 整体半透明（形态可辨）；focus = accent 描边。
class BrutalCheckbox extends StatelessWidget {
  const BrutalCheckbox({
    required this.value,
    required this.onChanged,
    super.key,
    this.enabled = true,
    this.focusNode,
  });

  final bool? value;
  final ValueChanged<bool>? onChanged;
  final bool enabled;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final palette = context.lm.palette;
    final checked = value ?? false;

    return _brutalInteractive(
      interactive: onChanged != null || !enabled,
      enabled: enabled,
      onTap: onChanged == null ? null : () => onChanged!(!checked),
      focusNode: focusNode,
      builder: (states) => Semantics(
        checked: checked,
        enabled: enabled,
        child: Opacity(
          opacity: states.disabled ? BrutalMaterials.disabledOpacity : 1,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: checked ? palette.primary : palette.surface,
              borderRadius: BorderRadius.circular(BrutalRadii.cornerNone),
              border: _brutalStateBorder(
                states,
                palette: palette,
                width: BrutalRadii.frameInline,
              ),
            ),
            child: SizedBox(
              width: 16,
              height: 16,
              child: checked
                  ? Icon(
                      Icons.check,
                      size: 12,
                      color: palette.onPrimary,
                    )
                  : null,
            ),
          ),
        ),
      ),
    );
  }
}

// ── 5. chip 标签（cornerField 非药丸；药丸只给开关类）──────────────

/// 标签：surfaceVariant 底 + frameInline 描边 + cornerField + ink 字；
/// 选中 primaryDim 底；hover surface 底；pressed primary@20% 合成。
class BrutalChip extends StatelessWidget {
  const BrutalChip({
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

    return _brutalInteractive(
      interactive: onTap != null || !enabled,
      enabled: enabled,
      onTap: onTap,
      builder: (states) {
        final Color fill;
        if (states.disabled) {
          fill = palette.surfaceVariant;
        } else if (states.pressed) {
          fill = Color.alphaBlend(
            palette.primary.withValues(alpha: BrutalMaterials.fillPressedAlpha),
            palette.surfaceVariant,
          );
        } else if (selected) {
          fill = Color.alphaBlend(palette.primaryDim, palette.surfaceVariant);
        } else if (states.hovered) {
          fill = palette.surface;
        } else {
          fill = palette.surfaceVariant;
        }
        final textColor = states.disabled ? palette.faint : palette.ink;
        return DecoratedBox(
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(BrutalRadii.cornerField),
            border: _brutalStateBorder(
              states,
              palette: palette,
              width: BrutalRadii.frameInline,
            ),
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: states.enabled ? onTap : null,
              canRequestFocus: false,
              borderRadius: BorderRadius.circular(BrutalRadii.cornerField),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                child: Text(
                  label,
                  style: BrutalTextStyles.caption.copyWith(color: textColor),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ── 6. dialog 模态内容卡（浮层走描边不走投影）──────────────────────

/// 模态内容卡：surfaceElevated 纸面 + frameOverlay 描边 + 直角 +
/// 零阴影零 elevation（遮罩由 `showDialog` 的 barrierColor 承担，
/// 装配层已钉 palette.scrim）。
class BrutalDialog extends StatelessWidget {
  const BrutalDialog({
    required this.child,
    super.key,
    this.title,
    this.actions,
    this.padding = const EdgeInsets.all(24),
  });

  final Widget child;
  final Widget? title;
  final List<Widget>? actions;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final palette = context.lm.palette;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.surfaceElevated,
        borderRadius: BorderRadius.circular(BrutalRadii.cornerNone),
        border: Border.fromBorderSide(
          BorderSide(
            color: BrutalMaterials.frameOf(palette),
            width: BrutalRadii.frameOverlay,
          ),
        ),
      ),
      child: Padding(
        padding: padding,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (title != null) ...[
              DefaultTextStyle(
                style: BrutalTextStyles.title2.copyWith(color: palette.ink),
                child: title!,
              ),
              const SizedBox(height: 12),
            ],
            DefaultTextStyle(
              style: BrutalTextStyles.body.copyWith(color: palette.muted),
              child: child,
            ),
            if (actions != null) ...[
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  for (final (i, action) in actions!.indexed) ...[
                    if (i > 0) const SizedBox(width: 8),
                    action,
                  ],
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ── 7. banner 横幅（语义填充 + 描边卡）─────────────────────────────

enum BrutalBannerTone { info, success, warning, error, accent }

/// 横幅：语义色@15% 合成填充 + frameInline 描边 + 直角；文本一律 ink
/// （纪律：彩色只做填充不承载文字；语义@15% 底上 ink 5.11-7.45
/// 全过，两族对比度档案在案）。可点按（整卡）。
class BrutalBanner extends StatelessWidget {
  const BrutalBanner({
    required this.message,
    required this.tone,
    super.key,
    this.onTap,
    this.enabled = true,
  });

  final String message;
  final BrutalBannerTone tone;
  final VoidCallback? onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final palette = context.lm.palette;
    final baseFill = switch (tone) {
      BrutalBannerTone.info => palette.surfaceVariant,
      BrutalBannerTone.success => palette.success.withValues(alpha: 0.15),
      BrutalBannerTone.warning => palette.warning.withValues(alpha: 0.15),
      BrutalBannerTone.error => palette.error.withValues(alpha: 0.15),
      BrutalBannerTone.accent => palette.accentDim,
    };

    return _brutalInteractive(
      interactive: onTap != null || !enabled,
      enabled: enabled,
      onTap: onTap,
      builder: (states) {
        final fill = states.disabled
            ? palette.surfaceVariant
            : states.pressed || states.hovered
                ? Color.alphaBlend(
                    palette.primary.withValues(
                      alpha: BrutalMaterials.fillPressedAlpha,
                    ),
                    baseFill,
                  )
                : baseFill;
        final textColor = states.disabled ? palette.faint : palette.ink;
        return DecoratedBox(
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(BrutalRadii.cornerNone),
            border: _brutalStateBorder(
              states,
              palette: palette,
              width: BrutalRadii.frameInline,
            ),
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: states.enabled ? onTap : null,
              canRequestFocus: false,
              borderRadius: BorderRadius.circular(BrutalRadii.cornerNone),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Text(
                  message,
                  style: BrutalTextStyles.bodySm.copyWith(color: textColor),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ── 8. snackBar 浮层提示（floating 描边卡）────────────────────────

enum BrutalSnackBarTone { info, success, warning, error }

/// 浮层提示：surface 纸面 + frameInline 描边 + 直角 + 零阴影（轻浮层
/// 不进投影层级）；语义 tone 由 leading 语义色小方块表达（语义色
/// 只做标注不承载文字）。
class BrutalSnackBar extends StatelessWidget {
  const BrutalSnackBar(
    this.message, {
    super.key,
    this.tone = BrutalSnackBarTone.info,
  });

  final String message;
  final BrutalSnackBarTone tone;

  @override
  Widget build(BuildContext context) {
    final palette = context.lm.palette;
    final marker = switch (tone) {
      BrutalSnackBarTone.info => palette.accent,
      BrutalSnackBarTone.success => palette.success,
      BrutalSnackBarTone.warning => palette.warning,
      BrutalSnackBarTone.error => palette.error,
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(BrutalRadii.cornerNone),
        border: Border.fromBorderSide(
          BorderSide(
            color: BrutalMaterials.frameOf(palette),
            width: BrutalRadii.frameInline,
          ),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(color: marker),
              child: const SizedBox(width: 8, height: 8),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                message,
                style: BrutalTextStyles.bodySm.copyWith(color: palette.ink),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
