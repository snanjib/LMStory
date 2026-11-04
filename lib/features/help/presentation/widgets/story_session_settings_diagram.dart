import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 故事模式会话设置示意图（2026-07-27 新增，2026-08-01 更新为 9 区段）。
///
/// 用于「故事会话设置」wiki 页顶部主视觉。
///
/// 设计：
/// - 上段：4 步骤模型（generating/extracting/reviewing/summarizing）独立配置
/// - 下段：会话设置 Sheet 的 9 个区段（记忆管理置顶）
///
/// 视觉传达：分步骤模型独立配置 + 完整设置区段
/// 对齐：intermediate_session_settings_sheet.dart 实际代码
class StorySessionSettingsDiagram extends StatelessWidget {
  const StorySessionSettingsDiagram({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 上段：4 步骤模型独立配置
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
                t.help.storySessionSettings.diagramPhasesTitle,
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
                  _PhaseBadge(
                    icon: Icons.edit_outlined,
                    label: t.help.storySessionSettings.phaseGenerating,
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    color: colors.faint,
                    size: 16,
                  ),
                  _PhaseBadge(
                    icon: Icons.search_outlined,
                    label: t.help.storySessionSettings.phaseExtracting,
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    color: colors.faint,
                    size: 16,
                  ),
                  _PhaseBadge(
                    icon: Icons.auto_fix_high_outlined,
                    label: t.help.storySessionSettings.phaseReviewing,
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    color: colors.faint,
                    size: 16,
                  ),
                  _PhaseBadge(
                    icon: Icons.summarize_outlined,
                    label: t.help.storySessionSettings.phaseSummarizing,
                  ),
                ],
              ),
              const SizedBox(height: SimpleSpacing.sSm),
              Text(
                t.help.storySessionSettings.diagramPhasesDesc,
                style: SimpleTextStyles.caption.copyWith(
                  color: colors.faint,
                  fontSize: 11,
                  height: 1.5,
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        const SizedBox(height: SimpleSpacing.sMd),

        // 下段：9 个设置区段（按 UI 实际顺序）
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
                t.help.storySessionSettings.diagramSectionsTitle,
                style: SimpleTextStyles.bodySm.copyWith(
                  color: colors.muted,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: SimpleSpacing.sSm),
              _SectionItem(
                icon: Icons.memory_outlined,
                label: t.help.storySessionSettings.sectionMemory,
                desc: t.help.storySessionSettings.sectionMemoryDesc,
              ),
              _SectionItem(
                icon: Icons.layers_outlined,
                label: t.help.storySessionSettings.sectionPhaseModels,
                desc: t.help.storySessionSettings.sectionPhaseModelsDesc,
              ),
              _SectionItem(
                icon: Icons.description_outlined,
                label: t.help.storySessionSettings.sectionPrompt,
                desc: t.help.storySessionSettings.sectionPromptDesc,
              ),
              _SectionItem(
                icon: Icons.tune_outlined,
                label: t.help.storySessionSettings.sectionGen,
                desc: t.help.storySessionSettings.sectionGenDesc,
              ),
              _SectionItem(
                icon: Icons.view_module_outlined,
                label: t.help.storySessionSettings.sectionContext,
                desc: t.help.storySessionSettings.sectionContextDesc,
              ),
              _SectionItem(
                icon: Icons.balance_outlined,
                label: t.help.storySessionSettings.sectionContextBudget,
                desc: t.help.storySessionSettings.sectionContextBudgetDesc,
              ),
              _SectionItem(
                icon: Icons.build_circle_outlined,
                label: t.help.storySessionSettings.sectionToolCalling,
                desc: t.help.storySessionSettings.sectionToolCallingDesc,
              ),
              _SectionItem(
                icon: Icons.fact_check_outlined,
                label: t.help.storySessionSettings.sectionReview,
                desc: t.help.storySessionSettings.sectionReviewDesc,
              ),
              _SectionItem(
                icon: Icons.auto_awesome_outlined,
                label: t.help.storySessionSettings.sectionSuggestReply,
                desc: t.help.storySessionSettings.sectionSuggestReplyDesc,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PhaseBadge extends StatelessWidget {
  const _PhaseBadge({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Column(
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: colors.primaryDim,
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: colors.primary, size: 16),
        ),
        const SizedBox(height: SimpleSpacing.s2xs),
        Text(
          label,
          style: SimpleTextStyles.caption.copyWith(
            color: colors.ink,
            fontSize: 10,
            fontWeight: FontWeight.w600,
          ),
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

class _SectionItem extends StatelessWidget {
  const _SectionItem({
    required this.icon,
    required this.label,
    required this.desc,
  });

  final IconData icon;
  final String label;
  final String desc;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: SimpleSpacing.s2xs),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: colors.primaryDim,
              borderRadius:
                  BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
            ),
            child: Icon(icon, color: colors.primary, size: 16),
          ),
          const SizedBox(width: SimpleSpacing.sSm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: SimpleTextStyles.bodySm.copyWith(
                    color: colors.ink,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  desc,
                  style: SimpleTextStyles.caption.copyWith(
                    color: colors.muted,
                    fontSize: 11,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
