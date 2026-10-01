import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 回到最新浮标（滚动终案）：生成中上滚脱离底部时浮现的右下角胶囊。
/// 与导演模式 _JumpToLatestPill 同款交互（Simple 主题配色）。
///
/// 原 chat_mode_page.dart 私有件 `_JumpToLatestPill`，跨库引用改公开
/// `Chat` 前缀命名，视觉与交互逐字符搬运。
class ChatJumpToLatestPill extends StatelessWidget {
  const ChatJumpToLatestPill({
    required this.visible,
    required this.onTap,
    super.key,
  });

  /// 是否显示（脱离底部时）。用 IgnorePointer + Opacity 保持布局稳定。
  final bool visible;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: LmMotion.fast,
        child: Material(
          color: colors.surfaceVariant,
          shape: StadiumBorder(
            side: BorderSide(color: colors.divider, width: 0.5),
          ),
          child: InkWell(
            onTap: onTap,
            customBorder: const StadiumBorder(),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: SimpleSpacing.sMd,
                vertical: 8,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.arrow_downward, size: 13, color: colors.muted),
                  const SizedBox(width: SimpleSpacing.s2xs),
                  Text(
                    t.chat.scrollToLatest,
                    style: SimpleTextStyles.caption.copyWith(
                      color: colors.muted,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
