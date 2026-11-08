import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 功能索引表示意图（2026-07-27 新增）。
///
/// 用于「功能索引表」wiki 页顶部主视觉。
///
/// 设计：
/// - 5 大模块卡片纵向排列，按版本归属着色
/// - 每个卡片含模块名 + 功能数量 + 描述
class FeatureIndexDiagram extends StatelessWidget {
  const FeatureIndexDiagram({super.key});

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
          _ModuleCard(
            title: t.help.featureIndex.diagramSimpleTitle,
            count: t.help.featureIndex.simpleCount,
            countDesc: t.help.featureIndex.simpleCountDesc,
            color: colors.primary,
          ),
          const SizedBox(height: SimpleSpacing.sXs),
          _ModuleCard(
            title: t.help.featureIndex.diagramIntermediateTitle,
            count: t.help.featureIndex.intermediateCount,
            countDesc: t.help.featureIndex.intermediateCountDesc,
            color: colors.accent,
          ),
          const SizedBox(height: SimpleSpacing.sXs),
          _ModuleCard(
            title: t.help.featureIndex.diagramDirectorTitle,
            count: t.help.featureIndex.directorCount,
            countDesc: t.help.featureIndex.directorCountDesc,
            color: colors.warning,
          ),
          const SizedBox(height: SimpleSpacing.sXs),
          _ModuleCard(
            title: t.help.featureIndex.diagramSettingsTitle,
            count: t.help.featureIndex.settingsCount,
            countDesc: t.help.featureIndex.settingsCountDesc,
            color: colors.success,
          ),
          const SizedBox(height: SimpleSpacing.sXs),
          _ModuleCard(
            title: t.help.featureIndex.diagramDataTitle,
            count: t.help.featureIndex.dataCount,
            countDesc: t.help.featureIndex.dataCountDesc,
            color: colors.warning,
          ),
          const SizedBox(height: SimpleSpacing.sXs),
          _ModuleCard(
            title: t.help.featureIndex.diagramHelpTitle,
            count: t.help.featureIndex.helpCount,
            countDesc: t.help.featureIndex.helpCountDesc,
            color: colors.muted,
          ),
          const SizedBox(height: SimpleSpacing.sXs),
          _ModuleCard(
            title: t.help.featureIndex.diagramDemoTitle,
            count: t.help.featureIndex.demoCount,
            countDesc: t.help.featureIndex.demoCountDesc,
            color: colors.primary,
          ),
        ],
      ),
    );
  }
}

class _ModuleCard extends StatelessWidget {
  const _ModuleCard({
    required this.title,
    required this.count,
    required this.countDesc,
    required this.color,
  });

  final String title;
  final String count;
  final String countDesc;
  final Color color;

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
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
        border: Border.all(color: colors.divider),
      ),
      child: Row(
        children: [
          Container(
            width: 6,
            height: 28,
            decoration: BoxDecoration(
              color: color,
              borderRadius:
                  BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
            ),
          ),
          const SizedBox(width: SimpleSpacing.sSm),
          Expanded(
            child: Text(
              title,
              style: SimpleTextStyles.bodySm.copyWith(
                color: colors.ink,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: SimpleSpacing.s2xs,
              vertical: 2,
            ),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius:
                  BorderRadius.circular(context.lmUi.radius(LmCorner.full)),
            ),
            child: Text(
              count,
              style: SimpleTextStyles.caption.copyWith(
                color: color,
                fontWeight: FontWeight.w700,
                fontSize: 10,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: SimpleSpacing.sSm),
          Flexible(
            child: Text(
              countDesc,
              style: SimpleTextStyles.caption.copyWith(
                color: colors.muted,
                fontSize: 10,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
