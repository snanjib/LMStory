import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/theme/system/lm_radius.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/utils/file_share.dart'
    if (dart.library.html) 'package:lmstory/core/utils/file_share_web.dart';
import 'package:lmstory/core/widgets/file_saved_dialog.dart';
import 'package:lmstory/features/settings/domain/entities/data_management_models.dart';
import 'package:lmstory/features/settings/domain/services/data_management_service.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 导出单个会话的完整流程
///
/// 弹出格式选择 BottomSheet（JSON / Markdown / TXT），
/// 调用 [DataManagementService] 生成内容，通过 [shareTextAsFile] 分享。
/// - 原生平台：写入临时文件 → 系统分享面板
/// - Web 平台：浏览器直接下载
///
/// 在会话页顶部菜单中复用（SimpleSessionCard 长按菜单入口已随该死组件
/// 一并移除）。
Future<void> exportSession(
  BuildContext context,
  WidgetRef ref,
  String sessionId, {
  String? sessionTitle,
}) async {
  final format = await SessionExportFormatSheet.show(context);
  if (format == null || !context.mounted) return;

  final service = ref.read(dataManagementServiceProvider);
  final t = Translations.of(context);

  // 阶段 1：弹出加载对话框 + 构建内容
  final navigator = Navigator.of(context, rootNavigator: true);
  unawaited(
    showLmDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => Dialog(
        child: Padding(
          padding: const EdgeInsets.all(SimpleSpacing.sLg),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(width: SimpleSpacing.sMd),
              Flexible(
                child: Text(
                  t.settings.data.sessionExport.preparing,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  String content;
  String extension;
  try {
    final (builtContent, builtExt) = await _buildContent(
      service,
      sessionId,
      format,
    );
    content = builtContent;
    extension = builtExt;
  } catch (e) {
    navigator.pop();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            e.toString(),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
    }
    return;
  }
  navigator.pop(); // 关闭加载对话框

  // 阶段 2：分享/下载
  if (!context.mounted) return;
  final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
  // 快赢#6：文件名带会话标题，多文件导出可辨识
  final safeTitle =
      (sessionTitle ?? '').replaceAll(RegExp(r'[\/:*?"<>|]'), '').trim();
  final fileName = safeTitle.isEmpty
      ? 'session_$timestamp.$extension'
      : '${safeTitle}_$timestamp.$extension';
  try {
    // 桌面端返回保存路径（弹成功确认框明示位置）；
    // null = 移动端分享面板已调起，保留面板选择保存位置的提示
    final savedPath = await shareTextAsFile(
      content: content,
      fileName: fileName,
      sharePositionOrigin: shareOriginFrom(context),
    );
    if (!context.mounted) return;
    if (savedPath != null) {
      await showFileSavedDialog(context, savedPath);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            '${t.settings.data.sessionExport.success}\n'
            '${t.settings.data.sessionExport.successHint}',
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
          ),
          duration: const Duration(seconds: 5),
        ),
      );
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            e.toString(),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
    }
  }
}

Future<(String, String)> _buildContent(
  DataManagementService service,
  String sessionId,
  SessionExportFormat format,
) async {
  switch (format) {
    case SessionExportFormat.json:
      return (await service.exportSessionAsJson(sessionId), 'json');
    case SessionExportFormat.markdown:
      return (await service.exportSessionAsMarkdown(sessionId), 'md');
    case SessionExportFormat.text:
      return (await service.exportSessionAsText(sessionId), 'txt');
  }
}

/// 单会话导出格式选择 BottomSheet
///
/// 返回用户选择的 [SessionExportFormat]；取消返回 null。
class SessionExportFormatSheet extends StatelessWidget {
  const SessionExportFormatSheet({super.key});

  static Future<SessionExportFormat?> show(BuildContext context) {
    return showLmSheet<SessionExportFormat>(
      context: context,
      isScrollControlled: true,
      // 内容自绘把手；shape 仅经典组合消费（琉璃形状由工厂锁定）。
      glassHandle: false,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(LmRadius.rXl),
        ),
      ),
      builder: (_) => const SessionExportFormatSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          SimpleSpacing.sLg,
          SimpleSpacing.sMd,
          SimpleSpacing.sLg,
          SimpleSpacing.sLg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: colors.divider,
                  borderRadius:
                      BorderRadius.circular(context.lmUi.radius(LmCorner.full)),
                ),
              ),
            ),
            const SizedBox(height: SimpleSpacing.sMd),
            Text(
              t.settings.data.sessionExport.title,
              style: SimpleTextStyles.title2.copyWith(
                color: colors.ink,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: SimpleSpacing.sMd),
            _FormatTile(
              icon: Icons.code,
              label: t.settings.data.sessionExport.formatJson,
              onTap: () => Navigator.of(context).pop(SessionExportFormat.json),
            ),
            _FormatTile(
              icon: Icons.description_outlined,
              label: t.settings.data.sessionExport.formatMarkdown,
              onTap: () =>
                  Navigator.of(context).pop(SessionExportFormat.markdown),
            ),
            _FormatTile(
              icon: Icons.text_snippet_outlined,
              label: t.settings.data.sessionExport.formatText,
              onTap: () => Navigator.of(context).pop(SessionExportFormat.text),
            ),
            const SizedBox(height: SimpleSpacing.sSm),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              style: TextButton.styleFrom(
                foregroundColor: colors.muted,
                minimumSize: const Size.fromHeight(44),
              ),
              child: Text(
                t.common.cancel,
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

class _FormatTile extends StatelessWidget {
  const _FormatTile({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: SimpleSpacing.sMd),
        child: Row(
          children: [
            Icon(icon, size: 20, color: colors.primary),
            const SizedBox(width: SimpleSpacing.sMd),
            Expanded(
              child: Text(
                label,
                style: SimpleTextStyles.body.copyWith(color: colors.ink),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Icon(Icons.chevron_right, size: 18, color: colors.faint),
          ],
        ),
      ),
    );
  }
}
