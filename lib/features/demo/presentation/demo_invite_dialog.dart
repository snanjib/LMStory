import 'package:flutter/material.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 首次启动演示邀请弹窗（接受/拒绝双按钮，不可点外关闭）
Future<bool> showDemoInviteDialog(BuildContext context) async {
  final t = Translations.of(context);
  final accepted = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: Text(t.demo.invite.title),
      content: Text('${t.demo.invite.message}\n\n${t.demo.invite.sampleTag}'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(t.demo.invite.decline),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(t.demo.invite.accept),
        ),
      ],
    ),
  );
  return accepted ?? false;
}
