import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 故事模式提示词自定义示意图（2026-07-27 新增）。
///
/// 用于「故事模式提示词自定义」wiki 页顶部主视觉。
///
/// 设计：
/// - 上段：10 段提示词列表
/// - 下段：编辑器 3 个区块（编辑区 / 使用场景 / 默认值预览）
class StoryPromptCustomDiagram extends StatelessWidget {
  const StoryPromptCustomDiagram({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 上段：10 段提示词列表
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
                t.help.storyPromptCustom.diagramListTitle,
                style: SimpleTextStyles.bodySm.copyWith(
                  color: colors.muted,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: SimpleSpacing.sSm),
              Wrap(
                spacing: SimpleSpacing.sXs,
                runSpacing: SimpleSpacing.sXs,
                children: [
                  _SegmentChip(label: t.help.storyPromptCustom.segDefaultRole),
                  _SegmentChip(label: t.help.storyPromptCustom.segGenerate),
                  _SegmentChip(label: t.help.storyPromptCustom.segExtractKw),
                  _SegmentChip(label: t.help.storyPromptCustom.segReview),
                  _SegmentChip(
                    label: t.help.storyPromptCustom.segExtractSummary,
                  ),
                  _SegmentChip(label: t.help.storyPromptCustom.segMacroSummary),
                  _SegmentChip(
                    label: t.help.storyPromptCustom.segGenerateInject,
                  ),
                  _SegmentChip(
                    label: t.help.storyPromptCustom.segMemoriesInject,
                  ),
                  _SegmentChip(label: t.help.storyPromptCustom.segExtractFacts),
                  _SegmentChip(label: t.help.storyPromptCustom.segFactInject),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: SimpleSpacing.sMd),

        // 下段：编辑器 3 个区块
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
                t.help.storyPromptCustom.diagramEditorTitle,
                style: SimpleTextStyles.bodySm.copyWith(
                  color: colors.muted,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: SimpleSpacing.sSm),
              _EditorBlock(
                icon: Icons.edit_outlined,
                label: t.help.storyPromptCustom.editorField,
                desc: t.help.storyPromptCustom.editorFieldDesc,
              ),
              _EditorBlock(
                icon: Icons.lightbulb_outline,
                label: t.help.storyPromptCustom.editorScene,
                desc: t.help.storyPromptCustom.editorSceneDesc,
              ),
              _EditorBlock(
                icon: Icons.history_outlined,
                label: t.help.storyPromptCustom.editorDefault,
                desc: t.help.storyPromptCustom.editorDefaultDesc,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SegmentChip extends StatelessWidget {
  const _SegmentChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SimpleSpacing.sSm,
        vertical: SimpleSpacing.s2xs,
      ),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.full)),
        border: Border.all(color: colors.divider),
      ),
      child: Text(
        label,
        style: SimpleTextStyles.caption.copyWith(
          color: colors.ink,
          fontWeight: FontWeight.w500,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

class _EditorBlock extends StatelessWidget {
  const _EditorBlock({
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
          Icon(icon, color: colors.primary, size: 16),
          const SizedBox(width: SimpleSpacing.sXs),
          Flexible(
            child: Text(
              label,
              style: SimpleTextStyles.bodySm.copyWith(
                color: colors.ink,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: SimpleSpacing.sXs),
          Expanded(
            child: Text(
              desc,
              style: SimpleTextStyles.caption.copyWith(
                color: colors.muted,
                fontSize: 11,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
