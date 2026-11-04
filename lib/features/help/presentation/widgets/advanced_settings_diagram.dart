import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 高级设置示意图（2026-07-27 新增）。
///
/// 用于「高级设置」wiki 页顶部主视觉。
///
/// 设计：
/// - 上段：3 个高级区块（思考预算 / 超时 / 标题模型）
/// - 下段：5 档思考预算（未配置 / 禁用 / 低 / 中 / 高）
class AdvancedSettingsDiagram extends StatelessWidget {
  const AdvancedSettingsDiagram({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 上段：3 个高级区块
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
                t.help.advancedSettings.diagramBlocksTitle,
                style: SimpleTextStyles.bodySm.copyWith(
                  color: colors.muted,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: SimpleSpacing.sSm),
              Row(
                children: [
                  Expanded(
                    child: _BlockCard(
                      icon: Icons.psychology_outlined,
                      label: t.help.advancedSettings.blockReasoning,
                      desc: t.help.advancedSettings.blockReasoningDesc,
                      highlight: true,
                    ),
                  ),
                  const SizedBox(width: SimpleSpacing.sXs),
                  Expanded(
                    child: _BlockCard(
                      icon: Icons.timer_outlined,
                      label: t.help.advancedSettings.blockTimeout,
                      desc: t.help.advancedSettings.blockTimeoutDesc,
                      highlight: false,
                    ),
                  ),
                  const SizedBox(width: SimpleSpacing.sXs),
                  Expanded(
                    child: _BlockCard(
                      icon: Icons.title_outlined,
                      label: t.help.advancedSettings.blockTitleModel,
                      desc: t.help.advancedSettings.blockTitleModelDesc,
                      highlight: false,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: SimpleSpacing.sMd),

        // 下段：5 档思考预算
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
                t.help.advancedSettings.diagramReasoningTitle,
                style: SimpleTextStyles.bodySm.copyWith(
                  color: colors.muted,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: SimpleSpacing.sSm),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _ReasoningBadge(
                    label: t.help.advancedSettings.reasoningNone,
                    desc: t.help.advancedSettings.reasoningNoneDesc,
                    highlight: true,
                  ),
                  _ReasoningBadge(
                    label: t.help.advancedSettings.reasoningDisabled,
                    desc: t.help.advancedSettings.reasoningDisabledDesc,
                    highlight: false,
                  ),
                  _ReasoningBadge(
                    label: t.help.advancedSettings.reasoningLow,
                    desc: t.help.advancedSettings.reasoningLowDesc,
                    highlight: false,
                  ),
                  _ReasoningBadge(
                    label: t.help.advancedSettings.reasoningMedium,
                    desc: t.help.advancedSettings.reasoningMediumDesc,
                    highlight: false,
                  ),
                  _ReasoningBadge(
                    label: t.help.advancedSettings.reasoningHigh,
                    desc: t.help.advancedSettings.reasoningHighDesc,
                    highlight: false,
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

class _BlockCard extends StatelessWidget {
  const _BlockCard({
    required this.icon,
    required this.label,
    required this.desc,
    required this.highlight,
  });

  final IconData icon;
  final String label;
  final String desc;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Container(
      padding: const EdgeInsets.all(SimpleSpacing.sSm),
      decoration: BoxDecoration(
        color: highlight ? colors.primaryDim : colors.surface,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
        border: Border.all(color: highlight ? colors.primary : colors.divider),
      ),
      child: Column(
        children: [
          Icon(
            icon,
            color: highlight ? colors.primary : colors.muted,
            size: 20,
          ),
          const SizedBox(height: SimpleSpacing.s2xs),
          Text(
            label,
            style: SimpleTextStyles.caption.copyWith(
              color: highlight ? colors.primary : colors.ink,
              fontWeight: FontWeight.w600,
            ),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: SimpleSpacing.s2xs),
          Text(
            desc,
            style: SimpleTextStyles.caption.copyWith(
              color: colors.muted,
              fontSize: 10,
              height: 1.3,
            ),
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class _ReasoningBadge extends StatelessWidget {
  const _ReasoningBadge({
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

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: SimpleSpacing.sSm,
            vertical: SimpleSpacing.s2xs,
          ),
          decoration: BoxDecoration(
            color: highlight ? colors.primary : colors.surfaceVariant,
            borderRadius:
                BorderRadius.circular(context.lmUi.radius(LmCorner.full)),
            border:
                Border.all(color: highlight ? colors.primary : colors.divider),
          ),
          child: Text(
            label,
            style: SimpleTextStyles.caption.copyWith(
              color: highlight ? colors.surface : colors.ink,
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(height: SimpleSpacing.s2xs),
        Text(
          desc,
          style: SimpleTextStyles.caption.copyWith(
            color: colors.muted,
            fontSize: 9,
            height: 1.3,
          ),
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}
