import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 监督模式审批流示意图（2026-08-19 新增）。
///
/// 用于「监督模式：请示与审批」wiki 页顶部主视觉。
///
/// 设计：导演要写入 → 确认卡弹出 → 允许（写入生效）/ 拒绝（跳过）双分支。
class DirectorWatchDiagram extends StatelessWidget {
  const DirectorWatchDiagram({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context).help.directorWatch;

    return Container(
      padding: const EdgeInsets.all(SimpleSpacing.sMd),
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
      ),
      child: Column(
        children: [
          _WatchNode(
            icon: Icons.edit_note_outlined,
            label: t.diagramRequestLabel,
            desc: t.diagramRequestDesc,
            accent: colors.warning,
          ),
          const _WatchArrow(),
          _WatchNode(
            icon: Icons.rule_outlined,
            label: t.diagramCardLabel,
            desc: t.diagramCardDesc,
            accent: colors.primary,
          ),
          const _WatchArrow(),
          Row(
            children: [
              Expanded(
                child: _WatchNode(
                  icon: Icons.check_circle_outline,
                  label: t.diagramAllowLabel,
                  desc: t.diagramAllowDesc,
                  accent: colors.success,
                ),
              ),
              const SizedBox(width: SimpleSpacing.sSm),
              Expanded(
                child: _WatchNode(
                  icon: Icons.cancel_outlined,
                  label: t.diagramDenyLabel,
                  desc: t.diagramDenyDesc,
                  accent: colors.error,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _WatchNode extends StatelessWidget {
  const _WatchNode({
    required this.icon,
    required this.label,
    required this.desc,
    required this.accent,
  });

  final IconData icon;
  final String label;
  final String desc;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: SimpleSpacing.sMd,
        vertical: SimpleSpacing.sSm,
      ),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
        border: Border.all(color: accent.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: accent),
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
                ),
                Text(
                  desc,
                  style: SimpleTextStyles.caption.copyWith(
                    color: colors.muted,
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

class _WatchArrow extends StatelessWidget {
  const _WatchArrow();

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: SimpleSpacing.s2xs),
      child: Icon(Icons.south, size: 16, color: colors.muted),
    );
  }
}
