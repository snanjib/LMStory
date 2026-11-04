import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 术语表示意图（2026-07-27 新增）。
///
/// 用于「术语表」wiki 页顶部主视觉。
///
/// 设计：
/// - 3 组术语分类卡片纵向排列
/// - 每组含数量 + 描述 + 示例术语
class GlossaryDiagram extends StatelessWidget {
  const GlossaryDiagram({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    return Container(
      padding: const EdgeInsets.all(SimpleSpacing.sMd),
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _GroupCard(
            icon: Icons.cloud_outlined,
            title: t.help.glossary.diagramApiTitle,
            count: t.help.glossary.apiCount,
            countDesc: t.help.glossary.apiCountDesc,
            examples: t.help.glossary.apiExamples,
            color: colors.primary,
          ),
          const SizedBox(height: SimpleSpacing.sSm),
          _GroupCard(
            icon: Icons.psychology_outlined,
            title: t.help.glossary.diagramMemoryTitle,
            count: t.help.glossary.memoryCount,
            countDesc: t.help.glossary.memoryCountDesc,
            examples: t.help.glossary.memoryExamples,
            color: colors.accent,
          ),
          const SizedBox(height: SimpleSpacing.sSm),
          _GroupCard(
            icon: Icons.apps_outlined,
            title: t.help.glossary.diagramProjectTitle,
            count: t.help.glossary.projectCount,
            countDesc: t.help.glossary.projectCountDesc,
            examples: t.help.glossary.projectExamples,
            color: colors.success,
          ),
        ],
      ),
    );
  }
}

class _GroupCard extends StatelessWidget {
  const _GroupCard({
    required this.icon,
    required this.title,
    required this.count,
    required this.countDesc,
    required this.examples,
    required this.color,
  });

  final IconData icon;
  final String title;
  final String count;
  final String countDesc;
  final String examples;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Container(
      padding: const EdgeInsets.all(SimpleSpacing.sSm),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
        border: Border.all(color: colors.divider),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius:
                  BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: SimpleSpacing.sSm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: SimpleTextStyles.bodySm.copyWith(
                    color: colors.ink,
                    fontWeight: FontWeight.w700,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  '$count · $countDesc',
                  style: SimpleTextStyles.caption.copyWith(
                    color: color,
                    fontWeight: FontWeight.w600,
                    fontSize: 11,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: SimpleSpacing.s2xs,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: colors.surfaceVariant,
                    borderRadius:
                        BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
                  ),
                  child: Text(
                    examples,
                    style: SimpleTextStyles.caption.copyWith(
                      color: colors.muted,
                      fontSize: 10,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
