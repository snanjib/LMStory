import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 推荐回复工具栏示意图。
///
/// 用于推荐回复与输入助手 wiki 子页顶部，作为主视觉。
///
/// 设计：
/// - 顶部：3 个按钮（引号/括号/推荐）左对齐排列
/// - 中部：一条虚线分隔
/// - 底部：输入框轮廓 + 发送按钮
///
/// 视觉传达：工具栏紧贴输入框上方，3 按钮左对齐，随时可用
class StorySuggestReplyDiagram extends StatelessWidget {
  const StorySuggestReplyDiagram({super.key});

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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── 工具栏标题 ──
          Text(
            t.help.storySuggestReply.diagramToolbarTitle,
            style: SimpleTextStyles.caption.copyWith(
              color: colors.muted,
              fontWeight: FontWeight.w600,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: SimpleSpacing.sSm),

          // ── 3 个按钮（左对齐）──
          Row(
            children: [
              _ToolbarButton(
                icon: Icons.format_quote_outlined,
                label: t.help.storySuggestReply.btnQuote,
              ),
              const SizedBox(width: SimpleSpacing.sSm),
              _ToolbarButton(
                icon: Icons.rounded_corner,
                label: t.help.storySuggestReply.btnParen,
              ),
              const SizedBox(width: SimpleSpacing.sSm),
              _ToolbarButton(
                icon: Icons.auto_awesome_outlined,
                label: t.help.storySuggestReply.btnSuggest,
                highlighted: true,
              ),
            ],
          ),

          const SizedBox(height: SimpleSpacing.sMd),

          // ── 虚线分隔 ──
          _DashedLine(width: double.infinity, color: colors.faint),

          const SizedBox(height: SimpleSpacing.sMd),

          // ── 输入框轮廓 + 发送按钮 ──
          Row(
            children: [
              Expanded(
                child: Container(
                  height: 36,
                  padding: const EdgeInsets.symmetric(
                    horizontal: SimpleSpacing.sMd,
                  ),
                  alignment: Alignment.centerLeft,
                  decoration: BoxDecoration(
                    color: colors.surface,
                    borderRadius:
                        BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
                    border: Border.all(color: colors.faint),
                  ),
                  child: Text(
                    t.help.storySuggestReply.diagramToolbarTitle,
                    style: SimpleTextStyles.caption.copyWith(
                      color: colors.faint,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              const SizedBox(width: SimpleSpacing.sSm),
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: colors.primary,
                  borderRadius:
                      BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
                ),
                child: Icon(
                  Icons.send_rounded,
                  color: colors.surface,
                  size: 18,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 工具栏按钮节点：图标 + 标签。
class _ToolbarButton extends StatelessWidget {
  const _ToolbarButton({
    required this.icon,
    required this.label,
    this.highlighted = false,
  });

  final IconData icon;
  final String label;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SimpleSpacing.sSm,
        vertical: SimpleSpacing.sXs,
      ),
      decoration: BoxDecoration(
        color: highlighted ? colors.primaryDim : colors.surface,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.full)),
        border: Border.all(
          color: highlighted ? colors.primary : colors.faint,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 16,
            color: highlighted ? colors.primary : colors.muted,
          ),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              style: SimpleTextStyles.caption.copyWith(
                color: highlighted ? colors.primary : colors.ink,
                fontWeight: FontWeight.w500,
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

/// 横向虚线分隔器。
class _DashedLine extends StatelessWidget {
  const _DashedLine({required this.width, required this.color});

  final double width;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 1,
      width: width,
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
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;

    const dashWidth = 4.0;
    const dashSpace = 3.0;
    double startX = 0;
    while (startX < size.width) {
      canvas.drawLine(
        Offset(startX, 0),
        Offset(startX + dashWidth, 0),
        paint,
      );
      startX += dashWidth + dashSpace;
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
