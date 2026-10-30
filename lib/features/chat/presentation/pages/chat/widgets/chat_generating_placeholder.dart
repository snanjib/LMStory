import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/shared/components/lm_arrival.dart';
import 'package:lmstory/core/theme/system/structures/classic/conversation/simple_message_bubble.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/settings/domain/entities/display_preferences.dart';

/// 「生成中」占位气泡内容（发送后/重生成后，等待第一个 token 期间），
/// 自 chat_mode_page.dart 拆出，逻辑原样搬运。
///
/// 对标 ChatBox：等待首个 token 时显示空助手气泡 + loading 指示器——
/// 复用 [SimpleMessageBubble]（空助手消息 + isStreaming=true）自动渲染
/// 旋转头像 + bouncing dots 指示器。
///
/// 注意：ListView itemBuilder 中本件外层由调用方以
/// `RepaintBoundary(key: ValueKey('__generating_placeholder__'))` 包裹
/// （ValueKey 在外层），该结构属近期性能改造终案，不可内移或改动。
class ChatGeneratingPlaceholderBubble extends StatelessWidget {
  const ChatGeneratingPlaceholderBubble({
    required this.sessionId,
    required this.displayPreferences,
    required this.fontScale,
    this.parentUserMsgId,
    this.forkIndex,
    this.forkCount,
    this.onForkPrev,
    this.onForkNext,
    super.key,
  });

  /// 占位气泡归属会话 id（物化后的真实 id，非 draft id）。
  final String sessionId;

  /// 关联到 Fork 锚点（regenerate/editAndResend 的生成锚点），
  /// 使分支导航在生成过程中就显示；无锚点为 null。
  final String? parentUserMsgId;

  final DisplayPreferences displayPreferences;

  final double fontScale;

  final int? forkIndex;

  final int? forkCount;

  final VoidCallback? onForkPrev;

  final VoidCallback? onForkNext;

  @override
  Widget build(BuildContext context) {
    return LmArrival(child: _buildBubble(context));
  }

  Widget _buildBubble(BuildContext context) {
    return SimpleMessageBubble(
      message: ChatMessage(
        messageId: '__generating_placeholder__',
        sessionId: sessionId,
        role: 'assistant',
        createdAt: DateTime.now(),
        // 关联到 Fork 锚点，使分支导航在生成过程中就显示
        parentUserMsgId: parentUserMsgId,
      ),
      isStreaming: true,
      isConsecutive: false,
      isGenerating: true,
      displayPreferences: displayPreferences,
      fontScale: fontScale,
      forkIndex: forkIndex,
      forkCount: forkCount,
      onForkPrev: onForkPrev,
      onForkNext: onForkNext,
    );
  }
}
