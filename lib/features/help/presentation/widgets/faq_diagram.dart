import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 故障排除 FAQ 示意图（2026-07-27 新增）。
///
/// 用于「故障排除 FAQ」wiki 页顶部主视觉。
///
/// 设计：
/// - 3 个错误码体系卡片纵向排列，按模式区分色彩
/// - 每个卡片含错误码范围 + 数量 + 处理策略
class FaqDiagram extends StatelessWidget {
  const FaqDiagram({super.key});

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
          _ErrorCodeCard(
            title: t.help.faq.diagramSimpleTitle,
            count: t.help.faq.simpleCount,
            countDesc: t.help.faq.simpleCountDesc,
            strategy: t.help.faq.simpleStrategy,
            strategyDesc: t.help.faq.simpleStrategyDesc,
            color: colors.primary,
          ),
          const SizedBox(height: SimpleSpacing.sSm),
          _ErrorCodeCard(
            title: t.help.faq.diagramIntermediateTitle,
            count: t.help.faq.intermediateCount,
            countDesc: t.help.faq.intermediateCountDesc,
            strategy: t.help.faq.intermediateStrategy,
            strategyDesc: t.help.faq.intermediateStrategyDesc,
            color: colors.accent,
          ),
          const SizedBox(height: SimpleSpacing.sSm),
          _ErrorCodeCard(
            title: t.help.faq.diagramCommonTitle,
            count: t.help.faq.commonCount,
            countDesc: t.help.faq.commonCountDesc,
            strategy: t.help.faq.commonStrategy,
            strategyDesc: t.help.faq.commonStrategyDesc,
            color: colors.muted,
          ),
        ],
      ),
    );
  }
}

class _ErrorCodeCard extends StatelessWidget {
  const _ErrorCodeCard({
    required this.title,
    required this.count,
    required this.countDesc,
    required this.strategy,
    required this.strategyDesc,
    required this.color,
  });

  final String title;
  final String count;
  final String countDesc;
  final String strategy;
  final String strategyDesc;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Container(
      padding: const EdgeInsets.all(SimpleSpacing.sSm),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 48,
            decoration: BoxDecoration(
              color: color,
              borderRadius:
                  BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
            ),
          ),
          const SizedBox(width: SimpleSpacing.sSm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: SimpleTextStyles.bodySm.copyWith(
                    color: color,
                    fontWeight: FontWeight.w700,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                RichText(
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  text: TextSpan(
                    style: SimpleTextStyles.caption.copyWith(
                      color: colors.muted,
                      fontSize: 11,
                      height: 1.4,
                    ),
                    children: [
                      TextSpan(
                        text: '$count · $countDesc\n',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      TextSpan(text: '$strategy · $strategyDesc'),
                    ],
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
