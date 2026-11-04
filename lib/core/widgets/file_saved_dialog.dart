import 'dart:io';

import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/i18n/strings.g.dart';
import 'package:url_launcher/url_launcher.dart';

/// 导出成功确认对话框
///
/// 桌面端导出/日志保存走系统保存对话框落盘后，明示保存位置并提供
/// 「打开所在文件夹」，替代此前静默写入临时目录且无任何反馈的流程。
Future<void> showFileSavedDialog(BuildContext context, String savedPath) {
  final t = Translations.of(context);
  return showLmDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(
        t.common.fileSaved.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(t.common.fileSaved.savedTo, style: SimpleTextStyles.bodySm),
          const SizedBox(height: 4),
          SelectableText(savedPath, style: SimpleTextStyles.bodySm),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => _openContainingFolder(savedPath),
          child: Text(t.common.fileSaved.openFolder),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text(t.common.close),
        ),
      ],
    ),
  );
}

Future<void> _openContainingFolder(String savedPath) async {
  final separator = Platform.isWindows ? r'\' : '/';
  final index = savedPath.lastIndexOf(separator);
  if (index <= 0) return;
  try {
    await launchUrl(Uri.file(savedPath.substring(0, index)));
  } on Exception {
    // 平台无可接管目录浏览的程序时放弃唤起；路径在对话框中仍可复制
  }
}
