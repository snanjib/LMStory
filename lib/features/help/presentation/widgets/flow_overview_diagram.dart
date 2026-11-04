import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 主流程图：6 节点竖向，每节点「图标 + 步骤名 + 1行动作」。
///
/// 用于四步流程页顶部，作为整个流程的主视觉。
///
/// v0.2.2节点顺序调整：提取 → 检索 → 生成 → 审查（可选）→ 摘要 → 入库
/// - extracting 前置到 generating 之前（原生成→提取→检索 改为 提取→检索→生成）
/// - reviewing 标注为可选（默认关闭，开启审查后执行）
///
/// 设计：
/// - 节点用 56×56 圆形图标（primaryDim 背景 + primary 色图标）
/// - 节点间用 24px 高的虚线连接（faint 色）
/// - 当前节点高亮，未来节点弱化（此处都为当前节点，统一色彩）
/// - 拒绝嵌套卡片，让节点直接呼吸
class FlowOverviewDiagram extends StatelessWidget {
  const FlowOverviewDiagram({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    final overview = t.help.flow.overview;

    final nodes = [
      _FlowNodeData(
        icon: Icons.search_outlined,
        name: overview.node1Name,
        action: overview.node1Action,
      ),
      _FlowNodeData(
        icon: Icons.library_books_outlined,
        name: overview.node2Name,
        action: overview.node2Action,
      ),
      _FlowNodeData(
        icon: Icons.edit_outlined,
        name: overview.node3Name,
        action: overview.node3Action,
      ),
      _FlowNodeData(
        icon: Icons.chat_bubble_outline,
        name: overview.node4Name,
        action: overview.node4Action,
      ),
      _FlowNodeData(
        icon: Icons.summarize_outlined,
        name: overview.node5Name,
        action: overview.node5Action,
      ),
      _FlowNodeData(
        icon: Icons.library_add_check_outlined,
        name: overview.node6Name,
        action: overview.node6Action,
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (int i = 0; i < nodes.length; i++) ...[
          _FlowNode(data: nodes[i]),
          if (i < nodes.length - 1)
            Padding(
              padding: const EdgeInsets.symmetric(
                vertical: SimpleSpacing.s2xs,
                horizontal: SimpleSpacing.sLg + 28, // 对齐节点中心
              ),
              child: _DashedLine(
                color: colors.faint,
                height: 24,
              ),
            ),
        ],
      ],
    );
  }
}

class _FlowNodeData {
  const _FlowNodeData({
    required this.icon,
    required this.name,
    required this.action,
  });

  final IconData icon;
  final String name;
  final String action;
}

class _FlowNode extends StatelessWidget {
  const _FlowNode({required this.data});

  final _FlowNodeData data;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Row(
      children: [
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: colors.primaryDim,
            borderRadius:
                BorderRadius.circular(context.lmUi.radius(LmCorner.full)),
          ),
          child: Icon(data.icon, color: colors.primary, size: 28),
        ),
        const SizedBox(width: SimpleSpacing.sMd),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                data.name,
                style: SimpleTextStyles.title2.copyWith(
                  color: colors.ink,
                  fontWeight: FontWeight.w700,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                data.action,
                style: SimpleTextStyles.bodySm.copyWith(color: colors.muted),
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

/// 竖向虚线连接器（不用实线，让流程不那么死板）。
class _DashedLine extends StatelessWidget {
  const _DashedLine({required this.color, required this.height});

  final Color color;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 2,
      height: height,
      child: CustomPaint(
        painter: _DashedLinePainter(color: color),
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
