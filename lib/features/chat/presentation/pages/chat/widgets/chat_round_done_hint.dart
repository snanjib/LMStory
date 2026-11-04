import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/shared/components/lm_arrival.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 收工态顶部完成胶囊（自 chat_mode_page.dart 拆出，逻辑原样搬运）。
///
/// 复刻故事侧「轮完成轻提示」：5s 自动消失（由宿主计时控制可见性），
/// 点按跳底（[onTap] 由宿主清除可见位并跳底）。
class ChatRoundDoneHint extends StatelessWidget {
  const ChatRoundDoneHint({required this.onTap, super.key});

  /// 点按胶囊回调（隐藏胶囊并跳到底部）。
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    return Positioned(
      top: SimpleSpacing.sXs,
      left: 0,
      right: 0,
      child: Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: SimpleSpacing.sLg,
          ),
          child: LmArrival(
            child: ActionChip(
              avatar: Icon(
                Icons.check_circle_outline,
                size: 16,
                color: colors.primary,
              ),
              label: Text(t.chat.roundDoneHint),
              onPressed: onTap,
            ),
          ),
        ),
      ),
    );
  }
}
