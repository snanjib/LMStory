import 'package:flutter/material.dart';
import 'package:lmstory/i18n/strings.g.dart';

enum DemoExitChoice { keep, abandon, stay }

/// 退出体验确认（遮罩常驻退出入口）
Future<DemoExitChoice> showDemoExitDialog(BuildContext context) async {
  final t = Translations.of(context);
  final choice = await showDialog<DemoExitChoice>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(t.demo.exit.title),
      content: Text(t.demo.exit.message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(DemoExitChoice.stay),
          child: Text(t.demo.exit.stay),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(DemoExitChoice.abandon),
          child: Text(t.demo.exit.abandon),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(DemoExitChoice.keep),
          child: Text(t.demo.exit.keep),
        ),
      ],
    ),
  );
  return choice ?? DemoExitChoice.stay;
}

/// 放弃演示数据的二次确认
Future<bool> confirmDemoAbandon(BuildContext context) async {
  final t = Translations.of(context);
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(t.demo.exit.abandonConfirmTitle),
      content: Text(t.demo.exit.abandonConfirmMessage),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(t.demo.exit.abandonConfirm),
        ),
      ],
    ),
  );
  return ok ?? false;
}

/// 交接失败重试弹窗
Future<void> showDemoHandoverFailedDialog(
  BuildContext context,
  Future<void> Function() onRetry,
) async {
  final t = Translations.of(context);
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(t.demo.handover.failedTitle),
      content: Text(t.demo.handover.failedMessage),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.demo.handover.later),
        ),
        FilledButton(
          onPressed: () {
            Navigator.of(context).pop();
            onRetry();
          },
          child: Text(t.demo.handover.retry),
        ),
      ],
    ),
  );
}
