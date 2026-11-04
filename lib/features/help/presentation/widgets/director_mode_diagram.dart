import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 导演模式一轮工作循环示意图（2026-08-19 新增）。
///
/// 用于「导演模式是什么」wiki 页顶部主视觉。
///
/// 设计：纵向循环流——你推进 → 总编辑幕后工作 → 正文成果 → 世界沉淀，
/// 末尾用回环箭头示意「下一轮继承已形成的世界」。
class DirectorModeDiagram extends StatelessWidget {
  const DirectorModeDiagram({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context).help.directorMode;

    return Container(
      padding: const EdgeInsets.all(SimpleSpacing.sMd),
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
      ),
      child: Column(
        children: [
          _LoopNode(
            icon: Icons.record_voice_over_outlined,
            label: t.loopYouLabel,
            desc: t.loopYouDesc,
            accent: colors.primary,
          ),
          const _LoopArrow(),
          _LoopNode(
            icon: Icons.theater_comedy_outlined,
            label: t.loopBackstageLabel,
            desc: t.loopBackstageDesc,
            accent: colors.warning,
          ),
          const _LoopArrow(),
          _LoopNode(
            icon: Icons.menu_book_outlined,
            label: t.loopOutputLabel,
            desc: t.loopOutputDesc,
            accent: colors.accent,
          ),
          const _LoopArrow(),
          _LoopNode(
            icon: Icons.public_outlined,
            label: t.loopWorldLabel,
            desc: t.loopWorldDesc,
            accent: colors.success,
          ),
        ],
      ),
    );
  }
}

class _LoopNode extends StatelessWidget {
  const _LoopNode({
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

class _LoopArrow extends StatelessWidget {
  const _LoopArrow();

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: SimpleSpacing.s2xs),
      child: Icon(Icons.south, size: 16, color: colors.muted),
    );
  }
}
