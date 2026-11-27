import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/system/lm_narrative_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 中级模式编辑弹窗（支持"保存"和"保存并发送"两种模式）
///
/// 视觉规范（DOC-06B §6 + §3.3）：
/// - 背景：surfaceElevated（主题 dialogTheme 已配）
/// - 标题：title 字体 + ink 色（主题已配）
/// - 输入框：surfaceVariant 填充 + rMd 圆角 + focused 时 primary 1.5px 边框
///   （主题 inputDecorationTheme 已配）
/// - 占位符：muted 色（4.5:1 ✅，B-10）
/// - 取消按钮：TextButton + muted 文字
/// - 保存按钮：allowResend=false 时用 ElevatedButton（主要操作）；
///   allowResend=true 时用 TextButton（次要操作，主要操作是"保存并发送"）
/// - 保存并发送按钮：ElevatedButton + primary 底 + bg 深色文字（主题已配）
///
/// 模式说明：
/// - allowResend=true（用户消息）：显示"保存"+"保存并发送"两个按钮
/// - allowResend=false（助手消息）：只显示"保存"按钮
///
/// impeccable product register：用标准 AlertDialog + TextField，不重新发明
/// affordance；dirty 检测 + PopScope 防误退，与 Simple 模式体验一致。
class IntermediateEditDialog extends StatefulWidget {
  const IntermediateEditDialog({
    required this.initialContent,
    this.allowResend = true,
    this.saveBeforeClosing,
    this.saveErrorMessage,
    super.key,
  });

  /// 待编辑的原始内容
  final String initialContent;

  /// 是否允许"保存并发送"（用户消息=true，助手消息=false）
  final bool allowResend;
  final Future<bool> Function(String content)? saveBeforeClosing;
  final String? saveErrorMessage;

  @override
  State<IntermediateEditDialog> createState() => _IntermediateEditDialogState();

  /// 显示编辑弹窗，返回编辑结果（null 表示用户取消）
  ///
  /// - [allowResend]=true：显示"保存"+"保存并发送"
  /// - [allowResend]=false：只显示"保存"
  static Future<({String content, bool resend})?> show(
    BuildContext context, {
    required String initialContent,
    bool allowResend = true,
    Future<bool> Function(String content)? saveBeforeClosing,
    String? saveErrorMessage,
  }) {
    return showLmDialog<({String content, bool resend})>(
      context: context,
      builder: (context) => IntermediateEditDialog(
        initialContent: initialContent,
        allowResend: allowResend,
        saveBeforeClosing: saveBeforeClosing,
        saveErrorMessage: saveErrorMessage,
      ),
    );
  }
}

class _IntermediateEditDialogState extends State<IntermediateEditDialog> {
  late final TextEditingController _controller;
  late final String _originalContent;
  bool _isDirty = false;
  bool _saving = false;
  bool _saveFailed = false;

  @override
  void initState() {
    super.initState();
    _originalContent = widget.initialContent;
    _controller = TextEditingController(text: widget.initialContent);
    _controller.addListener(_onTextChanged);
  }

  void _onTextChanged() {
    final dirty = _controller.text != _originalContent;
    if (dirty != _isDirty || _saveFailed) {
      setState(() {
        _isDirty = dirty;
        _saveFailed = false;
      });
    }
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_onTextChanged)
      ..dispose();
    super.dispose();
  }

  /// dirty 时确认丢弃变更（防误退）
  Future<bool> _confirmDiscard() async {
    if (!_isDirty) return true;
    final t = Translations.of(context);
    return await showLmDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(
              t.common.confirm,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            content: Text(
              t.chat.unsavedChanges,
              maxLines: 5,
              overflow: TextOverflow.ellipsis,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(
                  t.common.cancel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: Text(
                  t.common.confirm,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ) ??
        false;
  }

  /// 内容是否有效（已修改且非空）
  bool get _canSave =>
      !_saving && _isDirty && _controller.text.trim().isNotEmpty;

  /// 返回编辑结果（绕过 PopScope dirty 检查）
  Future<void> _popWithResult(bool resend) async {
    if (!_canSave) return;
    final content = _controller.text;
    final save = widget.saveBeforeClosing;
    if (save != null) {
      setState(() {
        _saving = true;
        _saveFailed = false;
      });
      bool saved;
      try {
        saved = await save(content);
      } catch (_) {
        saved = false;
      }
      if (!mounted) return;
      if (!saved) {
        setState(() {
          _saving = false;
          _saveFailed = true;
        });
        return;
      }
    }
    if (mounted) Navigator.of(context).pop((content: content, resend: resend));
  }

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;
    final allowResend = widget.allowResend;

    return PopScope(
      canPop: !_isDirty && !_saving,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop || _saving) return;
        final shouldPop = await _confirmDiscard();
        if (shouldPop && context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: AlertDialog(
        title: Text(
          t.intermediate.chat.messageActions.editTitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: TextField(
            controller: _controller,
            maxLines: null,
            autofocus: true,
            readOnly: _saving,
            decoration: _saveFailed
                ? InputDecoration(errorText: widget.saveErrorMessage)
                : const InputDecoration(),
            style: LmNarrativeTextStyles.input.copyWith(color: colors.ink),
            // decoration 省略：主题 inputDecorationTheme 自动应用
            // （surfaceVariant 填充 + rMd 圆角 + focused 时 primary 1.5px 边框）
          ),
        ),
        actions: [
          // 取消：muted 文字（与 ConfirmDialog 一致）
          // 用 maybePop 而非 pop：maybePop 尊重 PopScope.canPop，
          // dirty 时 canPop=false -> 触发 onPopInvokedWithResult 弹丢弃确认
          TextButton(
            onPressed: _saving ? null : () => Navigator.of(context).maybePop(),
            style: TextButton.styleFrom(foregroundColor: colors.muted),
            child: Text(
              t.common.cancel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // 保存：仅更新消息文本，不重新生成
          // allowResend=false 时作为主要操作用 ElevatedButton；
          // allowResend=true 时作为次要操作用 TextButton
          if (allowResend)
            TextButton(
              onPressed: _canSave ? () => _popWithResult(false) : null,
              child: Text(
                t.intermediate.chat.messageActions.save,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            )
          else
            ElevatedButton(
              onPressed: _canSave ? () => _popWithResult(false) : null,
              child: Text(
                t.intermediate.chat.messageActions.save,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          // 保存并发送：仅 allowResend=true 时显示（主要操作，primary 底）
          if (allowResend)
            ElevatedButton(
              onPressed: _canSave ? () => _popWithResult(true) : null,
              child: Text(
                t.intermediate.chat.messageActions.saveAndResend,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
  }
}
