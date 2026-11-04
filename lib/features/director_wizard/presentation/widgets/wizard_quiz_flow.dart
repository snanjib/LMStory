import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_button_metrics.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/director_wizard/presentation/controllers/director_wizard_controller.dart';
import 'package:lmstory/features/director_wizard/presentation/widgets/wizard_option_row.dart';

/// 问卷流组件（2026-10-19 方案 C：摘要行 + 逐题弹层）。
///
/// 页面只保留每题一张摘要卡（题目 + 当前答案 + 拼入原文一行预览），
/// 选项与自定义输入全部收进单题弹层——整行选项、选中即解释、
/// 「将写入提示词」原文盒都发生在弹层内，答完经「下一题」链式推进，
/// 不再是一整页表单。题目本身以描述符（spec）形式在页面侧声明，
/// 新增/调整题目只需增改 spec + i18n + 状态字段（模块化扩展点）。

/// 问卷题目选项（id / 标签 / 未选中时常显的说明行）。
class WizardQuizOption {
  const WizardQuizOption({required this.id, required this.label, this.desc});

  final String id;
  final String label;
  final String? desc;
}

/// 单题摘要卡：题目 + 当前答案（未选显占位）+ 拼入原文预览行 + chevron。
///
/// 点按由页面接线打开该题弹层；已答卡答案行用 primary 强调、
/// 未答用 muted——一眼可见进度，不读原文也知道答到哪了。
class WizardQuizSectionCard extends StatelessWidget {
  const WizardQuizSectionCard({
    required this.colors,
    required this.question,
    required this.answer,
    required this.unansweredLabel,
    this.previewLine,
    this.onTap,
    super.key,
  });

  final LmPalette colors;

  /// 题目标题（如「想在一个什么样的世界里玩？」）
  final String question;

  /// 当前答案标签（null = 未选）
  final String? answer;

  /// 未选占位文案
  final String unansweredLabel;

  /// 拼入原文预览行（已选块或「用户补充：」原文；null 不渲染）
  final String? previewLine;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final answered = answer != null && answer!.isNotEmpty;
    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
        border: Border.all(
          color: answered ? colors.primary : colors.divider,
          width: answered ? 1.5 : 1,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(
            context.lmUi.radius(LmCorner.lg),
          ),
          child: Padding(
            padding: const EdgeInsets.all(SimpleSpacing.sMd),
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: LmButtonMetrics.minInteractiveHeight,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          question,
                          style: SimpleTextStyles.bodySm.copyWith(
                            color: colors.muted,
                          ),
                        ),
                        const SizedBox(height: SimpleSpacing.s2xs),
                        Text(
                          answered ? answer! : unansweredLabel,
                          style: SimpleTextStyles.body.copyWith(
                            fontWeight: FontWeight.w600,
                            color: answered ? colors.ink : colors.faint,
                          ),
                        ),
                        if (previewLine != null && previewLine!.isNotEmpty) ...[
                          const SizedBox(height: SimpleSpacing.s2xs),
                          Text(
                            previewLine!,
                            style: SimpleTextStyles.caption.copyWith(
                              color: colors.faint,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ],
                    ),
                  ),
                  Icon(
                    Icons.chevron_right,
                    color: answered ? colors.primary : colors.muted,
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

/// 「将写入提示词」原文引用盒（弹层内选中项下方）。
///
/// 白话解释管「什么意思」，此盒管「实际落笔是什么」——选中即可斟酌。
class WizardPromptPreviewBox extends StatelessWidget {
  const WizardPromptPreviewBox({
    required this.colors,
    required this.label,
    required this.text,
    super.key,
  });

  final LmPalette colors;
  final String label;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(
        top: SimpleSpacing.sXs,
        left: SimpleSpacing.sMd,
      ),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(SimpleSpacing.sSm),
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
          border: Border(left: BorderSide(color: colors.primary, width: 3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: SimpleTextStyles.caption.copyWith(color: colors.faint),
            ),
            const SizedBox(height: SimpleSpacing.s2xs),
            Text(
              text,
              style: SimpleTextStyles.caption.copyWith(color: colors.ink),
            ),
          ],
        ),
      ),
    );
  }
}

/// 单题弹层内容：整行选项（选中即解释 + 原文盒）+ 可选自定义输入
/// （实时「用户补充」预览）+ 底部主按钮（下一题 / 完成答题）。
///
/// 状态经 [directorWizardProvider] watch 驱动：选项回调改 StateNotifier，
/// 本组件随 provider 重建——弹层内点选即刻看到解释与拼入原文；
/// 再点选中项=取消选择（「不选就交给 AI」语义保留）。
/// 自定义输入的 TextEditingController 由页面持有（跨弹层开关保值）。
class WizardQuizSheet extends ConsumerWidget {
  const WizardQuizSheet({
    required this.title,
    required this.options,
    required this.selectedIdOf,
    required this.onSelected,
    this.explanationOf,
    this.promptPreviewOf,
    this.previewLabel,
    this.customFieldLabel,
    this.customController,
    this.customTextOf,
    this.onCustomChanged,
    this.customPreviewPrefix,
    this.actionLabel,
    this.onAction,
    super.key,
  });

  /// 题目标题
  final String title;

  /// 选项集
  final List<WizardQuizOption> options;

  /// 当前选中 id（null/'' = 未选）
  final String? Function(DirectorWizardState) selectedIdOf;

  /// 点选选项（null = 取消选择）
  final ValueChanged<String?> onSelected;

  /// 选中项白话解释
  final String? Function(String id, String label)? explanationOf;

  /// 选中项拼入原文（null/空 = 无块不显，如人称「留空」）
  final String? Function(String id)? promptPreviewOf;

  /// 原文盒标签（「将写入提示词」）
  final String? previewLabel;

  /// 自定义输入（null = 该题不支持自己说）
  final String? customFieldLabel;
  final TextEditingController? customController;
  final String Function(DirectorWizardState)? customTextOf;
  final ValueChanged<String>? onCustomChanged;

  /// 自定义拼入行前缀（「用户补充：」）
  final String? customPreviewPrefix;

  /// 底部主按钮文案（下一题/完成答题）
  final String? actionLabel;

  /// 主按钮回调（弹层关闭由页面负责——链式打开下一题或结束）
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.lm.palette;
    final wizard = ref.watch(directorWizardProvider);
    final selectedId = selectedIdOf(wizard) ?? '';
    final customText = (customTextOf?.call(wizard) ?? '').trim();

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.all(SimpleSpacing.sMd),
              child: Text(
                title,
                style: SimpleTextStyles.title3.copyWith(
                  color: colors.ink,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(
                  horizontal: SimpleSpacing.sMd,
                ),
                children: [
                  for (var i = 0; i < options.length; i++) ...[
                    if (i > 0) const SizedBox(height: SimpleSpacing.sSm),
                    WizardOptionRow(
                      title: options[i].label,
                      description: options[i].desc,
                      selected: selectedId == options[i].id,
                      explanation:
                          explanationOf?.call(options[i].id, options[i].label),
                      onTap: () => onSelected(
                        selectedId == options[i].id ? null : options[i].id,
                      ),
                    ),
                    if (selectedId == options[i].id &&
                        (promptPreviewOf?.call(options[i].id) ?? '').isNotEmpty)
                      WizardPromptPreviewBox(
                        colors: colors,
                        label: previewLabel ?? '',
                        text: promptPreviewOf!.call(options[i].id)!,
                      ),
                  ],
                  if (customFieldLabel != null && customController != null) ...[
                    const SizedBox(height: SimpleSpacing.sSm),
                    Text(
                      customFieldLabel!,
                      style: SimpleTextStyles.bodySm.copyWith(
                        color: colors.muted,
                      ),
                    ),
                    const SizedBox(height: SimpleSpacing.sXs),
                    TextField(
                      controller: customController,
                      onChanged: onCustomChanged,
                      minLines: 1,
                      maxLines: 3,
                      style: SimpleTextStyles.body.copyWith(color: colors.ink),
                      decoration: InputDecoration(
                        isDense: true,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(
                            context.lmUi.radius(LmCorner.sm),
                          ),
                          borderSide: BorderSide(color: colors.divider),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(
                            context.lmUi.radius(LmCorner.sm),
                          ),
                          borderSide: BorderSide(color: colors.divider),
                        ),
                      ),
                    ),
                    if (customText.isNotEmpty && customPreviewPrefix != null)
                      WizardPromptPreviewBox(
                        colors: colors,
                        label: previewLabel ?? '',
                        text: '$customPreviewPrefix$customText',
                      ),
                  ],
                  const SizedBox(height: SimpleSpacing.sSm),
                ],
              ),
            ),
            if (actionLabel != null)
              Padding(
                padding: const EdgeInsets.all(SimpleSpacing.sMd),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: onAction,
                    child: Text(actionLabel!),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
