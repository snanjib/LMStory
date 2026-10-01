import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/system/lm_narrative_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 中级模式确认弹窗（简化 Fork：删除整轮确认）
///
/// 视觉规范（DOC-06B §6.4 + §3.3）：
/// - 背景：surfaceElevated（主题 dialogTheme 已配）
/// - 标题：title 字体 + ink 色（主题已配）
/// - 正文：bodyUi 字体 + muted 色（主题已配）
/// - 取消按钮：TextButton + muted 文字（不与主按钮竞争视觉）
/// - 确认按钮：ElevatedButton + error 底 + bg 深色文字
///   （error vs bg ≈ 5.9:1 ✅，传递危险操作语义）
///
/// impeccable product register：用标准 AlertDialog，不重新发明 affordance；
/// 危险操作通过 error 色按钮强化，无装饰性图标。
class IntermediateConfirmDialog {
  IntermediateConfirmDialog._();

  /// 显示确认弹窗，返回 true=确认 / false=取消（含 dismiss）
  static Future<bool> show({
    required BuildContext context,
    required String title,
    required String content,
    required String confirmLabel,
  }) async {
    final result = await showLmDialog<bool>(
      context: context,
      builder: (context) => _IntermediateConfirmDialog(
        title: title,
        content: content,
        confirmLabel: confirmLabel,
      ),
    );
    return result ?? false;
  }
}

class _IntermediateConfirmDialog extends StatelessWidget {
  const _IntermediateConfirmDialog({
    required this.title,
    required this.content,
    required this.confirmLabel,
  });

  final String title;
  final String content;
  final String confirmLabel;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    return AlertDialog(
      title: Text(
        title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      content: Text(
        content,
        maxLines: 5,
        overflow: TextOverflow.ellipsis,
      ),
      actions: [
        // 取消：muted 文字（不与主按钮竞争；偏离 textButtonTheme 的 primary 色）
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          style: TextButton.styleFrom(foregroundColor: colors.muted),
          child: Text(
            t.common.cancel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        // 确认：error 底 + bg 深色文字（危险操作，对比度 ≈ 5.9:1 ✅）
        ElevatedButton(
          onPressed: () => Navigator.of(context).pop(true),
          style: ElevatedButton.styleFrom(
            backgroundColor: colors.error,
            foregroundColor: colors.bg,
            disabledBackgroundColor: colors.error.withValues(alpha: 0.38),
            disabledForegroundColor: colors.bg.withValues(alpha: 0.38),
            shape: RoundedRectangleBorder(
              borderRadius:
                  BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
            ),
            minimumSize: const Size(0, 44),
            textStyle: LmNarrativeTextStyles.label,
          ),
          child: Text(
            confirmLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
