import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 浮动导航示意图（2026-07-27 新增）。
///
/// 用于「消息导航」wiki 页顶部主视觉。
///
/// 设计：
/// - 左侧：4 个浮动按钮（跳顶/上一条用户消息/下一条用户消息/跳底）
/// - 右侧：自动隐藏时序（滚动 → 停止 → 2 秒后隐藏）
///
/// 视觉传达：4 种导航功能 + 自动隐藏机制
class FloatingNavDiagram extends StatelessWidget {
  const FloatingNavDiagram({super.key});

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
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 左侧：4 个浮动按钮纵向排列
          Expanded(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t.help.messageNav.diagramButtonsTitle,
                  style: SimpleTextStyles.bodySm.copyWith(
                    color: colors.muted,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: SimpleSpacing.sSm),
                _NavButton(
                  icon: Icons.keyboard_double_arrow_up,
                  label: t.help.messageNav.btnJumpTop,
                  desc: t.help.messageNav.btnJumpTopDesc,
                ),
                _NavButton(
                  icon: Icons.keyboard_arrow_up,
                  label: t.help.messageNav.btnPrevUser,
                  desc: t.help.messageNav.btnPrevUserDesc,
                ),
                _NavButton(
                  icon: Icons.keyboard_arrow_down,
                  label: t.help.messageNav.btnNextUser,
                  desc: t.help.messageNav.btnNextUserDesc,
                ),
                _NavButton(
                  icon: Icons.keyboard_double_arrow_down,
                  label: t.help.messageNav.btnJumpBottom,
                  desc: t.help.messageNav.btnJumpBottomDesc,
                ),
              ],
            ),
          ),
          const SizedBox(width: SimpleSpacing.sMd),

          // 右侧：自动隐藏时序
          Expanded(
            flex: 3,
            child: Container(
              padding: const EdgeInsets.all(SimpleSpacing.sSm),
              decoration: BoxDecoration(
                color: colors.surface,
                borderRadius:
                    BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t.help.messageNav.diagramHideTitle,
                    style: SimpleTextStyles.bodySm.copyWith(
                      color: colors.muted,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: SimpleSpacing.sXs),
                  _TimelineRow(
                    icon: Icons.swap_vert_outlined,
                    label: t.help.messageNav.timeline1,
                  ),
                  _TimelineConnector(),
                  _TimelineRow(
                    icon: Icons.pause_outlined,
                    label: t.help.messageNav.timeline2,
                  ),
                  _TimelineConnector(),
                  _TimelineRow(
                    icon: Icons.timer_outlined,
                    label: t.help.messageNav.timeline3,
                    highlight: true,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NavButton extends StatelessWidget {
  const _NavButton({
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
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: colors.surface,
              shape: BoxShape.circle,
              border: Border.all(color: colors.primary, width: 1.5),
            ),
            child: Icon(icon, color: colors.primary, size: 16),
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
                    fontSize: 10,
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

class _TimelineRow extends StatelessWidget {
  const _TimelineRow({
    required this.icon,
    required this.label,
    this.highlight = false,
  });

  final IconData icon;
  final String label;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Row(
      children: [
        Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            color: highlight ? colors.primary : colors.primaryDim,
            shape: BoxShape.circle,
          ),
          child: Icon(
            icon,
            color: highlight ? colors.surface : colors.primary,
            size: 12,
          ),
        ),
        const SizedBox(width: SimpleSpacing.s2xs),
        Expanded(
          child: Text(
            label,
            style: SimpleTextStyles.caption.copyWith(
              color: highlight ? colors.ink : colors.muted,
              fontWeight: highlight ? FontWeight.w600 : FontWeight.w400,
              fontSize: 10,
              height: 1.3,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

class _TimelineConnector extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Padding(
      padding: const EdgeInsets.only(left: 9),
      child: Container(
        width: 2,
        height: 12,
        color: colors.faint,
      ),
    );
  }
}
