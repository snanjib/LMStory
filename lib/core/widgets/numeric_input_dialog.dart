import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 弹出数字输入对话框，用于滑块数值的精确输入。
///
/// 统一替代此前在 chat/intermediate 两处各手写的 `_showNumericInputDialog`。
/// 输入经 [FilteringTextInputFormatter] 限制为数字与小数点；校验失败以 SnackBar
/// 提示，合法时回调 [onConfirmed]（已确保落在 [min]~[max] 之间）。
///
/// controller 由对话框自身的 State 持有并在 dispose 释放——
/// 此前每次弹窗泄漏一个 TextEditingController（7 个调用点同病）。
/// 不能在 showDialog Future 完成时释放：退出动画期间 TextField 仍在使用它。
Future<void> showNumericInputDialog({
  required BuildContext context,
  required String title,
  required double currentValue,
  required double min,
  required double max,
  required ValueChanged<double> onConfirmed,
  int decimals = 2,
}) {
  return showLmDialog<void>(
    context: context,
    builder: (ctx) => _NumericInputDialog(
      title: title,
      currentValue: currentValue,
      min: min,
      max: max,
      decimals: decimals,
      onConfirmed: onConfirmed,
    ),
  );
}

class _NumericInputDialog extends StatefulWidget {
  const _NumericInputDialog({
    required this.title,
    required this.currentValue,
    required this.min,
    required this.max,
    required this.decimals,
    required this.onConfirmed,
  });

  final String title;
  final double currentValue;
  final double min;
  final double max;
  final int decimals;
  final ValueChanged<double> onConfirmed;

  @override
  State<_NumericInputDialog> createState() => _NumericInputDialogState();
}

class _NumericInputDialogState extends State<_NumericInputDialog> {
  late final TextEditingController _controller;
  late final ScaffoldMessengerState _messenger;
  late final Translations _t;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: widget.currentValue.toStringAsFixed(widget.decimals),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _messenger = ScaffoldMessenger.of(context);
    _t = Translations.of(context);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _confirm() {
    final parsed = double.tryParse(_controller.text);
    if (parsed == null) {
      _messenger.showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(_t.common.numericInput.invalid),
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }
    if (parsed < widget.min || parsed > widget.max) {
      _messenger.showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(_t.common.numericInput.outOfRange),
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }
    Navigator.pop(context);
    widget.onConfirmed(parsed);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        widget.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      content: TextField(
        controller: _controller,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [
          FilteringTextInputFormatter.allow(RegExp('[0-9.]')),
        ],
        decoration: InputDecoration(
          hintText: _t.common.numericInput.hint(
            min: widget.min.toStringAsFixed(1),
            max: widget.max.toStringAsFixed(1),
          ),
        ),
        autofocus: true,
        onSubmitted: (_) => _confirm(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(_t.common.cancel),
        ),
        TextButton(
          onPressed: _confirm,
          child: Text(_t.common.confirm),
        ),
      ],
    );
  }
}
