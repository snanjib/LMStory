import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/shared/components/brand_logo.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 首页布局示意图（2026-07-27 新增）。
///
/// 用于「界面总览」wiki 页顶部，作为主视觉。
///
/// 设计：
/// - 竖向 5 个区域块，模拟首页从上到下的布局结构
/// - 每个区域用 Container 模拟"区块"：左侧图标 + 右侧标签和描述
/// - 区域间用细虚线分隔（模拟布局分隔线，非连接线）
/// - 第 3 区域（双卡入口）特殊处理：横向 2 个小卡片，强调模式切换功能
/// - API Key 提示区域用虚线边框，表示"条件显示"
///
/// 视觉传达：首页 = 标题 + API Key 提示（可选）+ 双卡入口 + 最近会话 + 设置
class HomeLayoutDiagram extends StatelessWidget {
  const HomeLayoutDiagram({super.key});

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
          // 区域 1：顶部标题
          _LayoutBlock(
            icon: Icons.auto_stories_outlined,
            leading: const BrandLogo(size: 20),
            label: t.help.homeOverview.diagramHeaderLabel,
            desc: t.help.homeOverview.diagramHeaderDesc,
            iconBg: colors.primaryDim,
            iconColor: colors.primary,
          ),
          _SectionDivider(color: colors.faint),

          // 区域 2：API Key 提示（条件显示，用虚线边框）
          _ConditionalBlock(
            icon: Icons.key_outlined,
            label: t.help.homeOverview.diagramApiKeyLabel,
            desc: t.help.homeOverview.diagramApiKeyDesc,
            borderColor: colors.warning,
          ),
          _SectionDivider(color: colors.faint),

          // 区域 3：双卡入口（模式切换，横向 2 个小卡片）
          _EntryCardsBlock(t: t),
          _SectionDivider(color: colors.faint),

          // 区域 4：最近会话
          _LayoutBlock(
            icon: Icons.history_outlined,
            label: t.help.homeOverview.diagramRecentLabel,
            desc: t.help.homeOverview.diagramRecentDesc,
            iconBg: colors.surfaceElevated,
            iconColor: colors.muted,
          ),
          _SectionDivider(color: colors.faint),

          // 区域 5：设置入口
          _LayoutBlock(
            icon: Icons.settings_outlined,
            label: t.help.homeOverview.diagramSettingsLabel,
            desc: t.help.homeOverview.diagramSettingsDesc,
            iconBg: colors.surfaceElevated,
            iconColor: colors.muted,
          ),
        ],
      ),
    );
  }
}

/// 布局区块：图标 + 标签 + 描述（横向排列）。
class _LayoutBlock extends StatelessWidget {
  const _LayoutBlock({
    required this.label,
    required this.desc,
    required this.iconBg,
    required this.iconColor,
    this.icon,
    this.leading,
  }) : assert(
          icon != null || leading != null,
          'Either icon or leading must be provided.',
        );

  final IconData? icon;
  final Widget? leading;
  final String label;
  final String desc;
  final Color iconBg;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: SimpleSpacing.s2xs),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: iconBg,
              borderRadius:
                  BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
            ),
            child: leading ?? Icon(icon, color: iconColor, size: 20),
          ),
          const SizedBox(width: SimpleSpacing.sSm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: SimpleTextStyles.body.copyWith(
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

/// 条件显示区块：虚线边框表示"可选/条件渲染"。
class _ConditionalBlock extends StatelessWidget {
  const _ConditionalBlock({
    required this.icon,
    required this.label,
    required this.desc,
    required this.borderColor,
  });

  final IconData icon;
  final String label;
  final String desc;
  final Color borderColor;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: SimpleSpacing.s2xs),
      padding: const EdgeInsets.all(SimpleSpacing.sSm),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
        border: Border.all(
          color: borderColor.withValues(alpha: 0.5),
          width: 1.5,
          strokeAlign: BorderSide.strokeAlignOutside,
        ),
      ),
      child: Row(
        children: [
          Icon(icon, color: borderColor, size: 20),
          const SizedBox(width: SimpleSpacing.sSm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: SimpleTextStyles.body.copyWith(
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

/// 双卡入口区块：横向 2 个小卡片，强调模式切换。
class _EntryCardsBlock extends StatelessWidget {
  const _EntryCardsBlock({required this.t});

  final Translations t;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: SimpleSpacing.s2xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            t.help.homeOverview.diagramEntryLabel,
            style: SimpleTextStyles.body.copyWith(
              color: colors.ink,
              fontWeight: FontWeight.w600,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            t.help.homeOverview.diagramEntryDesc,
            style: SimpleTextStyles.caption.copyWith(color: colors.muted),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: SimpleSpacing.sSm),
          Row(
            children: [
              Expanded(
                child: _MiniCard(
                  icon: Icons.add_circle_outline,
                  label: t.help.homeOverview.diagramEntryChatLabel,
                  iconBg: colors.primaryDim,
                  iconColor: colors.primary,
                ),
              ),
              const SizedBox(width: SimpleSpacing.sSm),
              Expanded(
                child: _MiniCard(
                  icon: Icons.auto_stories_outlined,
                  label: t.help.homeOverview.diagramEntryStoryLabel,
                  iconBg: colors.accentDim,
                  iconColor: colors.accent,
                ),
              ),
              const SizedBox(width: SimpleSpacing.sSm),
              Expanded(
                child: _MiniCard(
                  icon: Icons.theater_comedy_outlined,
                  label: t.help.homeOverview.diagramEntryDirectorLabel,
                  iconBg: colors.warning.withValues(alpha: 0.12),
                  iconColor: colors.warning,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 入口卡片的小卡片（新对话/新建故事/新导演）。
class _MiniCard extends StatelessWidget {
  const _MiniCard({
    required this.icon,
    required this.label,
    required this.iconBg,
    required this.iconColor,
  });

  final IconData icon;
  final String label;
  final Color iconBg;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SimpleSpacing.sSm,
        vertical: SimpleSpacing.sXs,
      ),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: iconColor, size: 16),
          const SizedBox(width: SimpleSpacing.s2xs),
          Flexible(
            child: Text(
              label,
              style: SimpleTextStyles.caption.copyWith(
                color: colors.ink,
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

/// 章节分隔虚线（细虚线，模拟布局分隔线）。
class _SectionDivider extends StatelessWidget {
  const _SectionDivider({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: SimpleSpacing.s2xs),
      child: SizedBox(
        height: 1,
        child: CustomPaint(
          painter: _DashedLinePainter(color: color),
          child: const SizedBox.expand(),
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
