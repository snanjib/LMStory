import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/simple/components/simple_message_navigation.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/features/chat/presentation/pages/chat/widgets/chat_jump_to_latest_pill.dart';

/// 消息导航浮层（滚动终案，导演终案同款互斥，自 chat_mode_page.dart
/// 拆出，逻辑原样搬运）：
///
/// 生成中上滚脱离底部 = 醒目「回到最新」胶囊；收工后 = 四键导航条
/// （滑动时出现，停止 2 秒消失）。
///
/// 两种形态互斥：[working] 为真渲染胶囊（右侧大间距），否则渲染导航条
/// （右侧小间距），定位参数与原 if/else Positioned 分支一致。
class ChatMessageNavigationOverlay extends StatelessWidget {
  const ChatMessageNavigationOverlay({
    required this.working,
    required this.pillVisible,
    required this.pillOnTap,
    required this.navigationVisible,
    required this.onJumpToTop,
    required this.onJumpToBottom,
    required this.onPrevUserMessage,
    required this.onNextUserMessage,
    super.key,
  });

  /// 是否处于生成类工作态（流式/思考/压缩）。
  final bool working;

  /// 「回到最新」胶囊是否可见（生成中且脱离底部）。
  final bool pillVisible;

  /// 「回到最新」胶囊点按回调。
  final VoidCallback pillOnTap;

  /// 四键导航条是否可见（滑动中且不在底部）。
  final bool navigationVisible;

  final VoidCallback onJumpToTop;

  final VoidCallback onJumpToBottom;

  final VoidCallback onPrevUserMessage;

  final VoidCallback onNextUserMessage;

  @override
  Widget build(BuildContext context) {
    if (working) {
      return Positioned(
        right: SimpleSpacing.sLg,
        bottom: SimpleSpacing.sMd,
        child: ChatJumpToLatestPill(
          visible: pillVisible,
          onTap: pillOnTap,
        ),
      );
    }
    return Positioned(
      right: SimpleSpacing.sSm,
      bottom: SimpleSpacing.sMd,
      child: SimpleMessageNavigation(
        visible: navigationVisible,
        onJumpToTop: onJumpToTop,
        onJumpToBottom: onJumpToBottom,
        onPrevUserMessage: onPrevUserMessage,
        onNextUserMessage: onNextUserMessage,
      ),
    );
  }
}
