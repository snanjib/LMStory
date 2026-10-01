import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 上下文压缩流程示意图（2026-07-27 新增）。
///
/// 用于「上下文管理与压缩」wiki 页顶部主视觉。
///
/// 设计：
/// - 上段：自动压缩触发条件（token 阈值公式）
/// - 下段：压缩流程（4 节点：发送前预检 → 命中阈值 → 流式生成摘要 → 上下文替换）
///
/// 视觉传达：阈值触发 + 流式压缩过程
class CompactionFlowDiagram extends StatelessWidget {
  const CompactionFlowDiagram({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 上段：自动压缩触发条件
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
              Row(
                children: [
                  Icon(Icons.flag_outlined, color: colors.warning, size: 16),
                  const SizedBox(width: SimpleSpacing.s2xs),
                  Flexible(
                    child: Text(
                      t.help.compactionFlow.diagramTriggerTitle,
                      style: SimpleTextStyles.bodySm.copyWith(
                        color: colors.ink,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: SimpleSpacing.s2xs),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: SimpleSpacing.sSm,
                  vertical: SimpleSpacing.s2xs,
                ),
                decoration: BoxDecoration(
                  color: colors.surface,
                  borderRadius:
                      BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
                ),
                child: Text(
                  t.help.compactionFlow.diagramThresholdFormula,
                  style: SimpleTextStyles.caption.copyWith(
                    color: colors.muted,
                    fontSize: 11,
                    height: 1.6,
                  ),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: SimpleSpacing.sMd),

        // 下段：压缩流程 4 节点
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
                t.help.compactionFlow.diagramFlowTitle,
                style: SimpleTextStyles.bodySm.copyWith(
                  color: colors.muted,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: SimpleSpacing.sSm),
              _FlowStep(
                icon: Icons.send_outlined,
                label: t.help.compactionFlow.flow1Label,
                desc: t.help.compactionFlow.flow1Desc,
                highlight: false,
              ),
              _DashedLine(color: colors.faint),
              _FlowStep(
                icon: Icons.check_circle_outline,
                label: t.help.compactionFlow.flow2Label,
                desc: t.help.compactionFlow.flow2Desc,
                highlight: true,
              ),
              _DashedLine(color: colors.faint),
              _FlowStep(
                icon: Icons.auto_awesome_outlined,
                label: t.help.compactionFlow.flow3Label,
                desc: t.help.compactionFlow.flow3Desc,
                highlight: false,
              ),
              _DashedLine(color: colors.faint),
              _FlowStep(
                icon: Icons.layers_outlined,
                label: t.help.compactionFlow.flow4Label,
                desc: t.help.compactionFlow.flow4Desc,
                highlight: false,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _FlowStep extends StatelessWidget {
  const _FlowStep({
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

    return Row(
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: highlight ? colors.primary : colors.primaryDim,
            shape: BoxShape.circle,
          ),
          child: Icon(
            icon,
            color: highlight ? colors.surface : colors.primary,
            size: 18,
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
                  height: 1.4,
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

class _DashedLine extends StatelessWidget {
  const _DashedLine({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 17),
      child: SizedBox(
        width: 2,
        height: 16,
        child: CustomPaint(painter: _DashedLinePainter(color: color)),
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

    const dashHeight = 3.0;
    const dashSpace = 2.0;
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
