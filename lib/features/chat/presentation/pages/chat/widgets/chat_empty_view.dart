import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 无消息状态的空态引导页（自 chat_mode_page.dart 拆出，逻辑原样搬运）。
///
/// 空会话不再是白板——给出空态引导；action「开始对话」聚焦输入框
/// （[onStart] 由宿主传输入框 FocusNode 的 requestFocus）。
class ChatEmptyView extends StatelessWidget {
  const ChatEmptyView({required this.onStart, super.key});

  /// 点击「开始对话」回调（聚焦输入框）。
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    return context.lmUi.emptyState(
      context,
      title: t.chat.empty.noMessage,
      actionLabel: t.chat.empty.startAction,
      onAction: onStart,
    );
  }
}
