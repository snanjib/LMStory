import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/system/lm_ui_text_styles.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// Simple mode session card — Container + InkWell (no Card widget).
///
/// Displays session title, message preview, timestamp, and message count chip.
/// Long-press opens a context menu with rename / delete actions.
class SimpleSessionCard extends StatelessWidget {
  const SimpleSessionCard({
    required this.session,
    required this.onTap,
    required this.onDelete,
    required this.onRename,
    this.onExport,
    super.key,
  });

  final ChatSession session;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final VoidCallback onRename;

  /// 长按菜单中的"导出此会话"回调。
  /// 为 null 时不显示导出菜单项。
  final VoidCallback? onExport;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Padding(
      padding: const EdgeInsets.only(bottom: LmSpacing.sMd),
      child: Container(
        decoration: BoxDecoration(
          color: colors.surfaceVariant,
          borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
        ),
        child: InkWell(
          onTap: onTap,
          onLongPress: () => _showContextMenu(context),
          borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
          child: Padding(
            padding: const EdgeInsets.all(LmSpacing.sLg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        session.title,
                        style: LmUiTextStyles.body.copyWith(
                          fontWeight: FontWeight.w600,
                          color: colors.ink,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (session.isStarred) ...[
                      const SizedBox(width: LmSpacing.s2xs),
                      Icon(
                        Icons.star,
                        size: 14,
                        color: colors.primary,
                      ),
                    ],
                  ],
                ),
                if (session.lastMessagePreview != null &&
                    session.lastMessagePreview!.isNotEmpty) ...[
                  const SizedBox(height: LmSpacing.s2xs),
                  Text(
                    session.lastMessagePreview!,
                    style: LmUiTextStyles.caption.copyWith(
                      color: colors.muted,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                const SizedBox(height: LmSpacing.sSm),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _formatDateTime(context, session.lastActiveAt),
                        style: LmUiTextStyles.caption.copyWith(
                          color: colors.faint,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (session.messageCount > 0)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: LmSpacing.sSm,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: colors.surface,
                          borderRadius: BorderRadius.circular(
                            context.lmUi.radius(LmCorner.full),
                          ),
                        ),
                        child: Text(
                          '${session.messageCount}',
                          style: LmUiTextStyles.overline.copyWith(
                            color: colors.muted,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showContextMenu(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;

    showLmSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: Text(
                t.chat.rename,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () {
                Navigator.pop(context);
                onRename();
              },
            ),
            if (onExport != null)
              ListTile(
                leading: const Icon(Icons.upload_file_outlined),
                title: Text(
                  t.settings.data.sessionExport.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () {
                  Navigator.pop(context);
                  onExport!();
                },
              ),
            ListTile(
              leading: Icon(
                Icons.delete_outline,
                color: colors.error,
              ),
              title: Text(
                t.chat.deleteSession,
                style: TextStyle(color: colors.error),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () {
                Navigator.pop(context);
                onDelete();
              },
            ),
          ],
        ),
      ),
    );
  }

  String _formatDateTime(BuildContext context, DateTime dateTime) {
    final t = Translations.of(context);
    final now = DateTime.now();
    final difference = now.difference(dateTime);

    if (difference.inMinutes < 1) {
      return t.chat.time.justNow;
    } else if (difference.inMinutes < 60) {
      return t.chat.time.minutesAgo(n: difference.inMinutes);
    } else if (difference.inHours < 24) {
      return t.chat.time.hoursAgo(n: difference.inHours);
    } else if (difference.inDays < 7) {
      return t.chat.time.daysAgo(n: difference.inDays);
    } else {
      return t.chat.time.dateShort(
        month: dateTime.month,
        day: dateTime.day,
      );
    }
  }
}
