import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 首次启动流程示意图（2026-07-27 新增）。
///
/// 用于「第一次打开 App」wiki 页顶部，作为主视觉。
///
/// 设计：
/// - 竖向 3 节点流程图（启动 App → 新手引导 → 主界面）
/// - 节点 2（新手引导）高亮：primary 色背景 + 大图标
/// - 节点 1/3 弱化：primaryDim 背景 + primary 色图标
/// - 节点间用虚线连接（参考 FlowOverviewDiagram 风格）
/// - 拒绝嵌套卡片，节点直接呼吸
///
/// 视觉传达：首次启动 → 必经 6 步引导 → 进入主界面
class FirstLaunchFlowDiagram extends StatelessWidget {
  const FirstLaunchFlowDiagram({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 节点 1：启动 App
        _FlowNode(
          icon: Icons.power_settings_new_rounded,
          label: t.help.firstLaunch.diagramStartLabel,
          desc: t.help.firstLaunch.diagramStartDesc,
          highlight: false,
        ),
        // 虚线连接
        _DashedLine(color: colors.faint, height: 24),
        // 节点 2：新手引导（高亮，因为这是重点）
        _FlowNode(
          icon: Icons.school_outlined,
          label: t.help.firstLaunch.diagramGuideLabel,
          desc: t.help.firstLaunch.diagramGuideDesc,
          highlight: true,
          badge: '6',
        ),
        // 虚线连接
        _DashedLine(color: colors.faint, height: 24),
        // 节点 3：主界面
        _FlowNode(
          icon: Icons.home_outlined,
          label: t.help.firstLaunch.diagramHomeLabel,
          desc: t.help.firstLaunch.diagramHomeDesc,
          highlight: false,
        ),
      ],
    );
  }
}

/// 流程节点：圆形图标 + 标签 + 描述。
///
/// [highlight] 为 true 时用 primary 色背景（强调），否则用 primaryDim。
/// [badge] 不为 null 时在图标右上角显示数字徽章（用于「6 步」标识）。
class _FlowNode extends StatelessWidget {
  const _FlowNode({
    required this.icon,
    required this.label,
    required this.desc,
    required this.highlight,
    this.badge,
  });

  final IconData icon;
  final String label;
  final String desc;
  final bool highlight;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Row(
      children: [
        Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: highlight ? colors.primary : colors.primaryDim,
                borderRadius:
                    BorderRadius.circular(context.lmUi.radius(LmCorner.full)),
              ),
              child: Icon(
                icon,
                color: highlight ? colors.surface : colors.primary,
                size: 24,
              ),
            ),
            if (badge != null)
              Positioned(
                right: -4,
                top: -4,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: SimpleSpacing.s2xs,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: colors.accent,
                    borderRadius: BorderRadius.circular(
                      context.lmUi.radius(LmCorner.full),
                    ),
                  ),
                  child: Text(
                    badge!,
                    style: SimpleTextStyles.caption.copyWith(
                      color: colors.surface,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(width: SimpleSpacing.sMd),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: SimpleTextStyles.title2.copyWith(
                  color: colors.ink,
                  fontWeight: highlight ? FontWeight.w700 : FontWeight.w600,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                desc,
                style: SimpleTextStyles.bodySm.copyWith(color: colors.muted),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 竖向虚线连接器（与 FlowOverviewDiagram 共用风格）。
class _DashedLine extends StatelessWidget {
  const _DashedLine({required this.color, required this.height});

  final Color color;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 23), // 对齐节点中心（48/2 - 1）
      child: SizedBox(
        width: 2,
        height: height,
        child: CustomPaint(
          painter: _DashedLinePainter(color: color),
        ),
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
