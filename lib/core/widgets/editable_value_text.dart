import 'package:flutter/material.dart';

/// 可点按编辑的数值文本。
///
/// 此前三处（chat/intermediate 会话设置、推荐回复、生成参数）用裸
/// GestureDetector 包纯文本，视觉上与不可点文字无异——精确输入入口
/// 完全不可发现。本组件给值文本附加编辑小图标 + Tooltip + 按钮语义，
/// 点击回调仍由调用方弹出数值输入对话框。
///
/// [textStyle] 由调用方传入（simple/intermediate 两套主题各自取样式）。
class EditableValueText extends StatelessWidget {
  const EditableValueText({
    required this.value,
    required this.label,
    required this.onTap,
    this.textStyle,
    this.iconColor,
    this.tooltip,
    this.enabled = true,
    super.key,
  });

  /// 展示的当前值文本（如 "0.80"）。
  final String value;

  /// 无障碍标签/Tooltip 文案（描述「点击编辑什么」）。
  final String label;
  final VoidCallback onTap;
  final TextStyle? textStyle;
  final Color? iconColor;
  final String? tooltip;

  /// false（如生成中禁编辑）时隐藏编辑图标且不可点。
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: enabled ? (tooltip ?? label) : '',
      child: Semantics(
        button: enabled,
        label: label,
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(4),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(value, style: textStyle),
                if (enabled) ...[
                  const SizedBox(width: 2),
                  Icon(Icons.edit_outlined, size: 11, color: iconColor),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
