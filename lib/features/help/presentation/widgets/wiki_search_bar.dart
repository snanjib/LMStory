import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// Wiki 主目录顶部搜索框。
///
/// 设计参考 iOS/Android 系统设置搜索：
/// - 圆角容器 + 搜索图标 + 清除按钮（有输入时显示）
/// - 不自动聚焦，避免移动端键盘弹出遮挡列表
class WikiSearchBar extends StatelessWidget {
  const WikiSearchBar({
    required this.controller,
    required this.hint,
    required this.onChanged,
    required this.onClear,
    super.key,
  });

  final TextEditingController controller;
  final String hint;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;

    return Container(
      margin: const EdgeInsets.fromLTRB(
        SimpleSpacing.sLg,
        SimpleSpacing.sSm,
        SimpleSpacing.sLg,
        SimpleSpacing.sMd,
      ),
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
      ),
      child: ValueListenableBuilder<TextEditingValue>(
        valueListenable: controller,
        builder: (_, value, __) {
          final hasText = value.text.isNotEmpty;
          return TextField(
            controller: controller,
            onChanged: onChanged,
            style: SimpleTextStyles.body.copyWith(color: colors.ink),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: SimpleTextStyles.body.copyWith(color: colors.muted),
              prefixIcon: Icon(
                Icons.search_rounded,
                color: colors.muted,
                size: 20,
              ),
              suffixIcon: hasText
                  ? IconButton(
                      icon: Icon(
                        Icons.close_rounded,
                        color: colors.muted,
                        size: 18,
                      ),
                      tooltip: t.common.clear,
                      onPressed: onClear,
                      splashRadius: 16,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 32,
                        minHeight: 32,
                      ),
                    )
                  : null,
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: SimpleSpacing.sMd,
                vertical: SimpleSpacing.sMd,
              ),
            ),
          );
        },
      ),
    );
  }
}
