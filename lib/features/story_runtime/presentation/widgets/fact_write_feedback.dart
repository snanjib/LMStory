import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// Displays a one-off fact write warning for the current session.
class FactWriteFeedback {
  final _notices = <_FactWriteNotice>{};

  void show(BuildContext context, int count) {
    final messenger = ScaffoldMessenger.of(context);
    final text = Translations.of(context).common.errors.factWriteWarning(
          count: count,
        );
    final notice = _FactWriteNotice(messenger);
    final feature = messenger.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: ValueListenableBuilder(
          valueListenable: notice,
          builder: (context, showText, child) =>
              showText ? Text(text) : const SizedBox.shrink(),
        ),
        duration: const Duration(seconds: 3),
        onVisible: notice.onVisible,
      ),
    );
    _notices.add(notice);
    unawaited(
      feature.closed.then((_) {
        _notices.remove(notice);
        notice.dispose();
      }),
    );
  }

  void dismissOnSessionExit() {
    for (final notice in _notices) {
      notice.dismiss();
    }
    _notices.clear();
  }
}

/// A queued warning may reach the head after its session has been left.
/// Hide its text and remove only this warning once it is visible.
class _FactWriteNotice extends ValueNotifier<bool> {
  _FactWriteNotice(this.messenger) : super(true);

  final ScaffoldMessengerState messenger;
  bool _visible = false;
  bool _closed = false;

  void onVisible() {
    _visible = true;
    if (!value) _remove();
  }

  void dismiss() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_closed) return;
      value = false;
      if (_visible) _remove();
    });
  }

  void _remove() {
    if (!_closed && messenger.mounted) messenger.removeCurrentSnackBar();
  }

  @override
  void dispose() {
    _closed = true;
    super.dispose();
  }
}
