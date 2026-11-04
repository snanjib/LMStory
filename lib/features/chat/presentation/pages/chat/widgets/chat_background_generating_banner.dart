import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 后台分支生成中的输入区上方轻量指示条（自 chat_mode_page.dart 拆出，
/// 逻辑原样搬运）。
///
/// 后台分支生成中——被查看分支尾部无误导占位气泡，输入区上方以轻量
/// 指示告知生成仍在进行、完成后自动落在生成分支（样式对齐错误横幅的
/// 低调内联行）。
class ChatBackgroundGeneratingBanner extends StatelessWidget {
  const ChatBackgroundGeneratingBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    return Material(
      color: colors.primary.withValues(alpha: 0.08),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: SimpleSpacing.sMd,
          vertical: SimpleSpacing.s2xs,
        ),
        child: Row(
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: SimpleSpacing.sSm),
            Expanded(
              child: Text(
                t.chat.backgroundGenerating,
                style: SimpleTextStyles.caption.copyWith(
                  color: colors.muted,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
