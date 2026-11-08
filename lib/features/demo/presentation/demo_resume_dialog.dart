import 'package:flutter/material.dart';
import 'package:lmstory/features/demo/domain/demo_pack.dart';
import 'package:lmstory/i18n/strings.g.dart';

enum DemoResumeChoice { cont, restart, abandon }

enum DemoIncompatibleChoice { restart, abandon, cancel }

/// 启动恢复询问弹窗（检测到未完成演示）
Future<DemoResumeChoice?> showDemoResumeDialog(BuildContext context) async {
  final t = Translations.of(context);
  return showDialog<DemoResumeChoice>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: Text(t.demo.resume.title),
      content: Text(t.demo.resume.message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(DemoResumeChoice.abandon),
          child: Text(t.demo.resume.abandon),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(DemoResumeChoice.restart),
          child: Text(t.demo.resume.restart),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(DemoResumeChoice.cont),
          child: Text(t.demo.resume.continueDemo),
        ),
      ],
    ),
  );
}

/// 演示进度不兼容提示弹窗（如版本或画像不一致无法恢复）
Future<DemoIncompatibleChoice?> showDemoIncompatibleDialog(
  BuildContext context, {
  Object? error,
}) async {
  final t = Translations.of(context);
  final reason = error is DemoPackUnavailableException ? error.message : null;
  return showDialog<DemoIncompatibleChoice>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: Text(t.demo.incompatible.title),
      content: Text(
        reason != null && reason.isNotEmpty
            ? t.demo.incompatible.messageWithReason(reason: reason)
            : t.demo.incompatible.message,
      ),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.of(context).pop(DemoIncompatibleChoice.cancel),
          child: Text(t.demo.incompatible.cancel),
        ),
        TextButton(
          onPressed: () =>
              Navigator.of(context).pop(DemoIncompatibleChoice.abandon),
          child: Text(t.demo.resume.abandon),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(context).pop(DemoIncompatibleChoice.restart),
          child: Text(t.demo.resume.restart),
        ),
      ],
    ),
  );
}
