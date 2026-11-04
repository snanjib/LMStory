import 'package:flutter/material.dart';
import 'package:lmstory/core/config/intermediate_prompts.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_spacing.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 故事模式设置 — 系统提示词编辑区块（夜航主题）。
///
/// 从 IntermediateSettingsPage 抽出。
/// 状态由父页面持有（TextField controller + dirty check + PopScope 依赖），
/// 本组件仅负责渲染与回调透传。
class IntermediateSystemPromptSection extends StatelessWidget {
  const IntermediateSystemPromptSection({
    required this.controller,
    required this.loadedValue,
    required this.isLoading,
    required this.isSaving,
    required this.onSave,
    required this.onReset,
    super.key,
  });

  final TextEditingController controller;
  final String loadedValue;
  final bool isLoading;
  final bool isSaving;
  final VoidCallback onSave;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          t.settings.intermediate.systemPrompt,
          style: IntermediateTextStyles.title.copyWith(color: colors.ink),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: IntermediateSpacing.s2xs),
        Text(
          t.settings.intermediate.systemPromptDesc,
          style: IntermediateTextStyles.caption.copyWith(color: colors.muted),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: IntermediateSpacing.sMd),
        Container(
          padding: const EdgeInsets.all(IntermediateSpacing.sLg),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius:
                BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: controller,
                enabled: !isLoading,
                // maxLines: null + minLines: 6：文本框根据内容自适应高度，
                // 最小 6 行避免"太扁"，内容增多时自动变高（无内部滚动）。
                maxLines: null,
                minLines: 6,
                style:
                    IntermediateTextStyles.bodyUi.copyWith(color: colors.ink),
                decoration: InputDecoration(
                  // 2026-07-19 修复：用户未自定义时（loadedValue 为空），
                  // hintText 预览 kDefaultRolePrompt 前 60 字，让用户看到
                  // 实际生效的内置默认值，而不是只显示静态提示文案。
                  hintText: isLoading
                      ? t.settings.intermediate.loading
                      : (loadedValue.isEmpty
                          ? t.settings.intermediate.systemPromptDefaultPreview(
                              preview: kDefaultRolePrompt.length > 60
                                  ? kDefaultRolePrompt.substring(0, 60)
                                  : kDefaultRolePrompt,
                            )
                          : t.settings.intermediate.systemPromptHint),
                  hintStyle: IntermediateTextStyles.input
                      .copyWith(color: colors.muted),
                  filled: true,
                  fillColor: colors.surfaceVariant,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(
                      context.lmUi.radius(LmCorner.md),
                    ),
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(
                      context.lmUi.radius(LmCorner.md),
                    ),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(
                      context.lmUi.radius(LmCorner.md),
                    ),
                    borderSide: BorderSide(
                      color: colors.primary,
                      width: 1.5,
                    ),
                  ),
                  contentPadding: const EdgeInsets.all(
                    IntermediateSpacing.sMd,
                  ),
                ),
              ),
              const SizedBox(height: IntermediateSpacing.sMd),
              // 字数 + 按钮行：在 ValueListenableBuilder 内实时计算 isDirty，
              // 避免父 State 未重建时 isDirty 状态过期
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: controller,
                builder: (context, value, _) {
                  final dirty = value.text != loadedValue;
                  return Row(
                    children: [
                      Flexible(
                        child: Text(
                          t.settings.intermediate.charCount(
                            count: value.text.length,
                          ),
                          style: IntermediateTextStyles.caption
                              .copyWith(color: colors.faint),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: isSaving ? null : onReset,
                        child: Text(
                          t.settings.intermediate.reset,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: IntermediateSpacing.sSm),
                      ElevatedButton(
                        onPressed: (isSaving || !dirty) ? null : onSave,
                        child: isSaving
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : Text(
                                t.settings.intermediate.save,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}
