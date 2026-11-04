import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/shared/components/panel_heading.dart';
import 'package:lmstory/core/theme/system/lm_layout.dart';
import 'package:lmstory/core/theme/system/lm_narrative_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 消息编辑结果
///
/// [saveAndResend] 为 true 时表示"保存并重发"（创建新 Fork 分支），
/// 为 false 时表示"仅保存"（原地更新内容）。
class MessageEditResult {
  const MessageEditResult({
    required this.messageId,
    required this.content,
    required this.saveAndResend,
  });

  final String messageId;
  final String content;
  final bool saveAndResend;
}

/// 消息编辑弹窗（对标 ChatBox MessageEdit）
///
/// 提供两个保存按钮：
/// - **保存**：原地更新消息内容，不创建新分支
/// - **保存并重发**：更新内容后以该消息为 Fork 点创建新分支并重新生成助手回复
class MessageEditDialog extends StatefulWidget {
  const MessageEditDialog({
    required this.messageId,
    required this.initialContent,
    super.key,
  });

  /// 待编辑的消息 ID
  final String messageId;

  /// 初始消息内容
  final String initialContent;

  @override
  State<MessageEditDialog> createState() => _MessageEditDialogState();

  /// 显示编辑弹窗，返回编辑结果（null 表示用户取消）
  static Future<MessageEditResult?> show(
    BuildContext context, {
    required String messageId,
    required String initialContent,
  }) {
    return showLmDialog<MessageEditResult>(
      context: context,
      builder: (context) => MessageEditDialog(
        messageId: messageId,
        initialContent: initialContent,
      ),
    );
  }
}

class _MessageEditDialogState extends State<MessageEditDialog> {
  late final TextEditingController _controller;
  late final String _originalContent;
  bool _isDirty = false;

  @override
  void initState() {
    super.initState();
    _originalContent = widget.initialContent;
    _controller = TextEditingController(text: widget.initialContent);
    _controller.addListener(_onTextChanged);
  }

  void _onTextChanged() {
    final dirty = _controller.text != _originalContent;
    if (dirty != _isDirty) {
      setState(() => _isDirty = dirty);
    }
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_onTextChanged)
      ..dispose();
    super.dispose();
  }

  Future<bool> _confirmDiscard() async {
    if (!_isDirty) return true;
    final t = Translations.of(context);
    return await showLmDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(t.common.confirm),
            content: Text(
              t.chat.unsavedChanges,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(t.common.cancel),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: Text(t.common.confirm),
              ),
            ],
          ),
        ) ??
        false;
  }

  MessageEditResult _buildResult(bool saveAndResend) {
    return MessageEditResult(
      messageId: widget.messageId,
      content: _controller.text,
      saveAndResend: saveAndResend,
    );
  }

  /// 内容是否有效（非空且已修改）
  bool get _canSave => _isDirty && _controller.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;

    return PopScope(
      canPop: !_isDirty,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final shouldPop = await _confirmDiscard();
        if (shouldPop && context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Dialog(
        insetPadding: const EdgeInsets.symmetric(
          horizontal: LmSpacing.sLg,
          vertical: LmSpacing.sLg,
        ),
        child: SizedBox(
          width: LmLayout.dialogMaxWidth,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxHeight: LmLayout.messageEditorMaxHeight,
            ),
            child: Padding(
              padding: const EdgeInsets.all(LmSpacing.sLg),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  PanelHeading(title: t.chat.editMessage),
                  const SizedBox(height: LmSpacing.sMd),
                  Flexible(
                    child: TextField(
                      controller: _controller,
                      minLines: 5,
                      maxLines: 16,
                      autofocus: true,
                      style: LmNarrativeTextStyles.narrativeBody.copyWith(
                        color: colors.ink,
                      ),
                      decoration: InputDecoration(
                        filled: true,
                        fillColor: colors.surfaceVariant,
                        border: const OutlineInputBorder(),
                        focusedBorder: OutlineInputBorder(
                          borderSide: BorderSide(color: colors.primary),
                        ),
                        contentPadding: const EdgeInsets.all(LmSpacing.sMd),
                      ),
                    ),
                  ),
                  const SizedBox(height: LmSpacing.sMd),
                  Wrap(
                    alignment: WrapAlignment.end,
                    spacing: LmSpacing.sXs,
                    runSpacing: LmSpacing.sXs,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: Text(t.common.cancel),
                      ),
                      TextButton(
                        onPressed: _canSave
                            ? () =>
                                Navigator.of(context).pop(_buildResult(false))
                            : null,
                        child: Text(t.common.save),
                      ),
                      FilledButton(
                        onPressed: _canSave
                            ? () =>
                                Navigator.of(context).pop(_buildResult(true))
                            : null,
                        child: Text(
                          t.chat.saveAndResend,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
