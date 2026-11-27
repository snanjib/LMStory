import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/chat/domain/services/simple_failure_classifier.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 页面内联错误横幅（自 chat_mode_page.dart 拆出，逻辑原样搬运）。
///
/// 加载/清除/摘要操作失败此前写入 state.error 但从未渲染——错误被静默
/// 吞掉。此处内联展示，下次发送消息时 controller 会置 null 自动消失；
/// 关闭按钮供用户不再发送消息时主动清除（此前只能重进会话）。
class ChatErrorBanner extends StatelessWidget {
  const ChatErrorBanner({
    required this.message,
    required this.onDismiss,
    super.key,
  });

  /// 错误文案（非空才渲染本横幅，判空由宿主负责）。
  final String message;

  /// 关闭横幅回调（清除 controller 的 state.error）。
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final labels = Translations.of(context).chat.failure;
    final payload = SimpleErrorPayload.tryDecode(message);
    final code = payload?.code;
    final String display;
    if (payload != null) {
      final summary = code == null || code.isEmpty
          ? payload.message
          : labels.displayFormat(message: payload.message, code: code);
      display = [
        summary,
        if (payload.suggestion case final suggestion?) suggestion,
      ].join('\n');
    } else {
      display = message.startsWith(SimpleErrorPayload.prefix)
          ? labels.messages.unknown
          : message;
    }
    return Material(
      color: colors.error.withValues(alpha: 0.1),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: SimpleSpacing.sMd,
          vertical: SimpleSpacing.sSm,
        ),
        child: Row(
          children: [
            Icon(
              Icons.error_outline,
              size: 16,
              color: colors.error,
            ),
            const SizedBox(width: SimpleSpacing.sSm),
            Expanded(
              child: Text(
                display,
                style: SimpleTextStyles.caption.copyWith(
                  color: colors.error,
                ),
                maxLines: payload == null ? 3 : null,
                overflow: payload == null ? TextOverflow.ellipsis : null,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 16),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              tooltip: labels.dismissBanner,
              onPressed: onDismiss,
            ),
          ],
        ),
      ),
    );
  }
}
