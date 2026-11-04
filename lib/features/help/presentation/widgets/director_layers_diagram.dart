import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 台前/幕后过程分层示意图（2026-08-19 新增）。
///
/// 用于「看懂过程：台前与幕后」wiki 页顶部主视觉。
///
/// 设计：上半是「台前」——正文气泡 + 一行过程行；下半是「幕后」——
/// 一叠步骤卡（默认折叠，示意展开后的样子）。
class DirectorLayersDiagram extends StatelessWidget {
  const DirectorLayersDiagram({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context).help.directorProcess;
    final ta = Translations.of(context).advanced;

    return Container(
      padding: const EdgeInsets.all(SimpleSpacing.sMd),
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 台前
          Row(
            children: [
              Icon(Icons.visibility_outlined, size: 16, color: colors.accent),
              const SizedBox(width: SimpleSpacing.sXs),
              Text(
                t.stageLabel,
                style: SimpleTextStyles.bodySm.copyWith(
                  color: colors.accent,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: SimpleSpacing.sXs),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(SimpleSpacing.sSm),
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius:
                  BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t.stageDesc,
                  style: SimpleTextStyles.caption.copyWith(
                    color: colors.ink,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: SimpleSpacing.sSm),
          // 幕后
          Row(
            children: [
              Icon(
                Icons.visibility_off_outlined,
                size: 16,
                color: colors.warning,
              ),
              const SizedBox(width: SimpleSpacing.sXs),
              Text(
                t.backstageLabel,
                style: SimpleTextStyles.bodySm.copyWith(
                  color: colors.warning,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: SimpleSpacing.sXs),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(SimpleSpacing.sSm),
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius:
                  BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
              border: Border.all(
                color: colors.warning.withValues(alpha: 0.4),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t.backstageDesc,
                  style: SimpleTextStyles.caption.copyWith(
                    color: colors.muted,
                  ),
                ),
                const SizedBox(height: SimpleSpacing.s2xs),
                _StepChip(text: '1 · ${ta.stage.searchStory}'),
                const SizedBox(height: SimpleSpacing.s2xs),
                _StepChip(text: '2 · ${ta.stage.queryFacts}'),
                const SizedBox(height: SimpleSpacing.s2xs),
                _StepChip(text: '3 · ${ta.stage.finishRound}'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StepChip extends StatelessWidget {
  const _StepChip({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SimpleSpacing.sSm,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
      ),
      child: Text(
        text,
        style: SimpleTextStyles.caption.copyWith(color: colors.muted),
      ),
    );
  }
}
