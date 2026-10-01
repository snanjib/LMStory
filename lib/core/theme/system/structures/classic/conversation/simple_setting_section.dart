import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/system/lm_ui_text_styles.dart';

/// 设置区块容器：标题 + 内容。
///
/// Simple 模式设置页内通用的分组容器，在 GeneralSettingsPage 与
/// ChatSettingsPage 中复用，保持各 section 的标题样式一致。
///
/// 删除对两个 presentation 页的
/// import——core→feature 反向引用且仅存在于本注释，纯注释驱动死依赖。
///
/// 视觉：仅渲染标题（body + w600）+ 间距 + child，不提供背景色；
/// 背景色由各 section 自身的容器负责（surfaceVariant 圆角容器）。
class SimpleSettingSection extends StatelessWidget {
  const SimpleSettingSection({
    required this.title,
    required this.child,
    super.key,
  });

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: LmSpacing.sSm),
          child: Text(
            title,
            style: LmUiTextStyles.body.copyWith(
              fontWeight: FontWeight.w600,
              color: colors.ink,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        child,
      ],
    );
  }
}
