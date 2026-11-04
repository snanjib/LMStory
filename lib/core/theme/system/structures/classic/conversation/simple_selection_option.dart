import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/system/lm_ui_text_styles.dart';

/// 统一的单选选项行：选中行底色 + 行内左置勾号。
///
/// 用于主题、语言、发送键、推理强度等多选一场景。在 surfaceVariant
/// 圆角容器内纵向排列多个 [SimpleSelectionOption] 即构成一个选择组。
///
/// - [isEnabled] 为 false 时显示 [disabledLabel]（如"(v0.2)"占位）并禁用点击。
/// - 选中态 = `primaryDim` 底色 + 行内左置 primary 色勾号：视线从指示
///   到标签就近扫读，宽屏（容器全宽 ~1900px）不再出现勾号贴最右端的
///   断裂（发现 F）；勾号-标签间距恒为 `LmSpacing.sSm`，跨宽度不变。
/// - 选中底色与勾号均不改变行高与标签缩进（margin+padding 与原行
///   padding 等值折算），未选中行零变化。
class SimpleSelectionOption extends StatelessWidget {
  const SimpleSelectionOption({
    required this.label,
    required this.isSelected,
    required this.onTap,
    this.isEnabled = true,
    this.disabledLabel,
    super.key,
  });

  final String label;
  final bool isSelected;
  final bool isEnabled;
  final VoidCallback onTap;
  final String? disabledLabel;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    //  语义修复：整行可点却无任何交互角色时，读屏器只当它是静态文本，
    // 用户不知道「能点」。这里给整行补 button 角色（标签由子树合并而来，
    // 语义节点仍是同一个，不新增空名节点）。
    return Semantics(
      button: true,
      enabled: isEnabled,
      child: context.lmUi.selectionRow(
        context,
        onTap: isEnabled ? onTap : null,
        selected: isSelected,
        child: Row(
          children: [
            if (isSelected) ...[
              Icon(Icons.check, size: 20, color: colors.primary),
              const SizedBox(width: LmSpacing.sSm),
            ],
            Expanded(
              child: Text(
                label,
                style: LmUiTextStyles.body.copyWith(
                  color: isEnabled ? colors.ink : colors.faint,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (!isEnabled && disabledLabel != null)
              Text(
                disabledLabel!,
                style: LmUiTextStyles.overline,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
      ),
    );
  }
}
