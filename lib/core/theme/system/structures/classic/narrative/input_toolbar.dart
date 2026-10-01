import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';
import 'package:lmstory/core/theme/system/lm_narrative_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 输入框工具栏（2026-07-29 新增）
///
/// 在输入框上方显示一行左对齐的功能按钮，提供快速编辑操作：
/// - **添加引号**：在光标位置插入成对英文引号 `""`，光标移到引号中间
/// - **添加括号**：在光标位置插入成对英文括号 `()`，光标移到括号中间
/// - **推荐回复**：调用 LLM 生成 3 条候选回复，气泡浮层展示供选择
///
/// **视觉设计**（遵循 impeccable 原则 + 夜航配色）：
/// - Restrained 策略：按钮默认 muted 色，hover/press 时 primary 色
/// - 紧凑布局：图标 + 文字 chip 样式，左对齐排列，间距 sSm
/// - 圆角 rSm（8px）chip 规范；背景透明，hover 时 primaryDim
/// - 推荐按钮生成中显示 loading 指示器替代图标
///
/// **按钮可用性**：
/// - 添加引号/括号：始终可用（不依赖会话状态）
/// - 推荐回复：需至少 1 轮历史消息（无上下文无法生成）；
///   生成中禁用避免重复点击
///
/// **尾部插槽**：[trailing] 渲染在行末（`Spacer` 右推），供模式专属内容
/// 挂载（导演模式上下文圆环 chip，长会话退化治理）。null = 不渲染，
/// 故事模式零变化。
class InputToolbar extends StatelessWidget {
  const InputToolbar({
    required this.onAddQuote,
    required this.onAddParen,
    required this.onSuggest,
    required this.isGeneratingSuggest,
    required this.canSuggest,
    this.trailing,
    super.key,
  });

  /// 点击"添加引号"回调
  final VoidCallback onAddQuote;

  /// 点击"添加括号"回调
  final VoidCallback onAddParen;

  /// 点击"推荐回复"回调
  final VoidCallback onSuggest;

  /// 是否正在生成推荐回复（true 时按钮显示 loading）
  final bool isGeneratingSuggest;

  /// 是否允许推荐回复（需至少 1 轮历史消息）
  final bool canSuggest;

  /// 行末插槽（模式专属内容；null = 不渲染）
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(
        left: LmSpacing.sMd,
        right: LmSpacing.sMd,
        bottom: LmSpacing.s2xs,
      ),
      child: Row(
        children: [
          _ToolbarButton(
            icon: Icons.format_quote_outlined,
            label: Translations.of(context).intermediate.chat.toolbar.addQuote,
            onPressed: onAddQuote,
          ),
          const SizedBox(width: LmSpacing.sSm),
          _ToolbarButton(
            icon: Icons.rounded_corner,
            label: Translations.of(context).intermediate.chat.toolbar.addParen,
            onPressed: onAddParen,
          ),
          const SizedBox(width: LmSpacing.sSm),
          _ToolbarButton(
            icon: Icons.auto_awesome_outlined,
            label: Translations.of(context).intermediate.chat.toolbar.suggest,
            onPressed: canSuggest && !isGeneratingSuggest ? onSuggest : null,
            isLoading: isGeneratingSuggest,
            tooltip: Translations.of(context)
                .intermediate
                .chat
                .toolbar
                .suggestTooltip,
          ),
          if (trailing != null) ...[const Spacer(), trailing!],
        ],
      ),
    );
  }
}

/// 工具栏单个按钮（图标 + 文字 chip 样式）
class _ToolbarButton extends StatefulWidget {
  const _ToolbarButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.isLoading = false,
    this.tooltip,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool isLoading;
  final String? tooltip;

  @override
  State<_ToolbarButton> createState() => _ToolbarButtonState();
}

class _ToolbarButtonState extends State<_ToolbarButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final isEnabled = widget.onPressed != null;
    final accentColor = isEnabled ? colors.primary : colors.faint;

    final button = MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: InkWell(
        onTap: widget.onPressed,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
        child: AnimatedContainer(
          duration: LmMotion.micro,
          padding: const EdgeInsets.symmetric(
            horizontal: LmSpacing.sSm,
            vertical: LmSpacing.s2xs,
          ),
          decoration: BoxDecoration(
            color: _isHovered && isEnabled
                ? colors.primaryDim
                : Colors.transparent,
            borderRadius:
                BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
            border: Border.all(
              color: _isHovered && isEnabled
                  ? colors.primary.withValues(alpha: 0.3)
                  : colors.divider,
              width: 0.5,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.isLoading)
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: accentColor,
                  ),
                )
              else
                Icon(widget.icon, size: 14, color: accentColor),
              const SizedBox(width: LmSpacing.s2xs),
              Flexible(
                child: Text(
                  widget.label,
                  style: LmNarrativeTextStyles.caption.copyWith(
                    color: isEnabled ? colors.muted : colors.faint,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (widget.tooltip != null) {
      return Tooltip(
        message: widget.tooltip,
        child: button,
      );
    }
    return button;
  }
}
