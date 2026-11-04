import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 宏摘要与微摘要关系示意图。
///
/// 用于宏摘要机制页顶部，作为主视觉。
///
/// 设计：
/// - 左侧：3 个微摘要节点（小圆 24×24 + 标签）按竖向排列
/// - 中间：3 条虚线汇聚到右侧宏摘要节点（大圆 48×48）
/// - 右侧：宏摘要节点 + 标签
/// - 拒绝嵌套卡片，节点直接呼吸
///
/// 视觉传达：多轮微摘要 → 聚合成 1 条宏摘要
class MacroSummaryOverviewDiagram extends StatelessWidget {
  const MacroSummaryOverviewDiagram({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    return Container(
      padding: const EdgeInsets.all(SimpleSpacing.sLg),
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
      ),
      child: Row(
        children: [
          // 左侧：3 个微摘要节点
          Expanded(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (int i = 0; i < 3; i++) ...[
                  _MicroNode(
                    label: '${t.help.macroWiki.diagramMicroLabel} ${i + 1}',
                    desc: t.help.macroWiki.diagramMicroDesc,
                  ),
                  if (i < 2)
                    const Padding(
                      padding: EdgeInsets.only(left: 11), // 对齐圆心
                      child: _DashedLine(height: 16),
                    ),
                ],
              ],
            ),
          ),

          // 中间：聚合箭头
          Expanded(
            child: Column(
              children: [
                Icon(
                  Icons.arrow_forward_rounded,
                  color: colors.primary,
                  size: 22,
                ),
                const SizedBox(height: SimpleSpacing.s2xs),
                Text(
                  t.help.macroWiki.diagramAggregateLabel,
                  style: SimpleTextStyles.caption.copyWith(
                    color: colors.primary,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),

          // 右侧：宏摘要节点
          Expanded(
            flex: 2,
            child: Column(
              children: [
                _MacroNode(
                  label: t.help.macroWiki.diagramMacroLabel,
                  desc: t.help.macroWiki.diagramMacroDesc,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 微摘要节点：小圆 + 标签 + 描述。
class _MicroNode extends StatelessWidget {
  const _MicroNode({required this.label, required this.desc});

  final String label;
  final String desc;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Row(
      children: [
        Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            color: colors.primaryDim,
            borderRadius:
                BorderRadius.circular(context.lmUi.radius(LmCorner.full)),
          ),
          child: Icon(
            Icons.circle,
            color: colors.primary,
            size: 10,
          ),
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
                  fontWeight: FontWeight.w500,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                desc,
                style: SimpleTextStyles.caption.copyWith(
                  color: colors.muted,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 宏摘要节点：大圆 + 标签 + 描述。
class _MacroNode extends StatelessWidget {
  const _MacroNode({required this.label, required this.desc});

  final String label;
  final String desc;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Column(
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: colors.primary,
            borderRadius:
                BorderRadius.circular(context.lmUi.radius(LmCorner.full)),
          ),
          child: Icon(
            Icons.library_add_check_outlined,
            color: colors.surface,
            size: 24,
          ),
        ),
        const SizedBox(height: SimpleSpacing.sXs),
        Text(
          label,
          style: SimpleTextStyles.bodySm.copyWith(
            color: colors.ink,
            fontWeight: FontWeight.w700,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        Text(
          desc,
          style: SimpleTextStyles.caption.copyWith(color: colors.muted),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

/// 竖向虚线连接器。
class _DashedLine extends StatelessWidget {
  const _DashedLine({required this.height});

  final double height;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return SizedBox(
      width: 2,
      height: height,
      child: CustomPaint(
        painter: _DashedLinePainter(color: colors.faint),
      ),
    );
  }
}

class _DashedLinePainter extends CustomPainter {
  _DashedLinePainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    const dashHeight = 4.0;
    const dashSpace = 3.0;
    double startY = 0;
    while (startY < size.height) {
      canvas.drawLine(
        Offset(0, startY),
        Offset(0, startY + dashHeight),
        paint,
      );
      startY += dashHeight + dashSpace;
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
