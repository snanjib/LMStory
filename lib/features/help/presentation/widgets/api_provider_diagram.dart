import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// API 供应商管理示意图（2026-07-27 新增）。
///
/// 用于「API 供应商管理」wiki 页顶部主视觉。
///
/// 设计：
/// - 上段：7 个内置模板 + 1 个自定义（grid 3 列）
/// - 下段：自定义 2 步流程（选模板 → 命名创建）
class ApiProviderDiagram extends StatelessWidget {
  const ApiProviderDiagram({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 上段：7 个内置模板 + 自定义
        Container(
          padding: const EdgeInsets.all(SimpleSpacing.sMd),
          decoration: BoxDecoration(
            color: colors.surfaceVariant,
            borderRadius:
                BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                t.help.apiProvider.diagramBuiltinTitle,
                style: SimpleTextStyles.bodySm.copyWith(
                  color: colors.muted,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: SimpleSpacing.sSm),
              Wrap(
                spacing: SimpleSpacing.sXs,
                runSpacing: SimpleSpacing.sXs,
                children: [
                  _TemplateChip(label: t.help.apiProvider.builtinOpenAI),
                  _TemplateChip(label: t.help.apiProvider.builtinDeepSeek),
                  _TemplateChip(label: t.help.apiProvider.builtinOpenRouter),
                  _TemplateChip(label: t.help.apiProvider.builtinClaude),
                  _TemplateChip(label: t.help.apiProvider.builtinGemini),
                  _TemplateChip(label: t.help.apiProvider.builtinNvidia),
                  _TemplateChip(label: t.help.apiProvider.builtinAgnes),
                  _TemplateChip(
                    label: t.help.apiProvider.builtinCustom,
                    highlight: true,
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: SimpleSpacing.sMd),

        // 下段：自定义 2 步流程
        Container(
          padding: const EdgeInsets.all(SimpleSpacing.sMd),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius:
                BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
            border: Border.all(color: colors.divider),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                t.help.apiProvider.diagramCustomTitle,
                style: SimpleTextStyles.bodySm.copyWith(
                  color: colors.muted,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: SimpleSpacing.sSm),
              Row(
                children: [
                  Expanded(
                    child: _FlowStep(
                      label: t.help.apiProvider.customStep1,
                      desc: t.help.apiProvider.customStep1Desc,
                      highlight: true,
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    color: colors.faint,
                    size: 18,
                  ),
                  Expanded(
                    child: _FlowStep(
                      label: t.help.apiProvider.customStep2,
                      desc: t.help.apiProvider.customStep2Desc,
                      highlight: false,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TemplateChip extends StatelessWidget {
  const _TemplateChip({required this.label, this.highlight = false});

  final String label;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SimpleSpacing.sSm,
        vertical: SimpleSpacing.s2xs,
      ),
      decoration: BoxDecoration(
        color: highlight ? colors.primaryDim : colors.surface,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.full)),
        border: Border.all(color: highlight ? colors.primary : colors.divider),
      ),
      child: Text(
        label,
        style: SimpleTextStyles.caption.copyWith(
          color: highlight ? colors.primary : colors.muted,
          fontWeight: highlight ? FontWeight.w600 : FontWeight.w400,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

class _FlowStep extends StatelessWidget {
  const _FlowStep({
    required this.label,
    required this.desc,
    required this.highlight,
  });

  final String label;
  final String desc;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Container(
      padding: const EdgeInsets.all(SimpleSpacing.sSm),
      decoration: BoxDecoration(
        color: highlight ? colors.primaryDim : colors.surfaceVariant,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: SimpleTextStyles.bodySm.copyWith(
              color: highlight ? colors.primary : colors.ink,
              fontWeight: FontWeight.w600,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: SimpleSpacing.s2xs),
          Text(
            desc,
            style: SimpleTextStyles.caption.copyWith(
              color: colors.muted,
              fontSize: 11,
              height: 1.4,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
