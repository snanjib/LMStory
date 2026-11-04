import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 资源种子流程示意图（2026-08-19 新增）。
///
/// 用于「角色卡与世界书（资源库）」wiki 页顶部主视觉。
///
/// 设计：纵向四步——导入 → 应用 → 只读种子生效 → 与新事实共同生长，
/// 末步用双行（种子常青 + 新芽）示意两层并存。
class ResourceSeedDiagram extends StatelessWidget {
  const ResourceSeedDiagram({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context).help.resourceLibrary;

    return Container(
      padding: const EdgeInsets.all(SimpleSpacing.sMd),
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
      ),
      child: Column(
        children: [
          _SeedNode(
            icon: Icons.download_outlined,
            label: t.seed1Label,
            desc: t.seed1Desc,
            accent: colors.primary,
          ),
          const _SeedArrow(),
          _SeedNode(
            icon: Icons.checklist,
            label: t.seed2Label,
            desc: t.seed2Desc,
            accent: colors.accent,
          ),
          const _SeedArrow(),
          _SeedNode(
            icon: Icons.lock_outline,
            label: t.seed3Label,
            desc: t.seed3Desc,
            accent: colors.warning,
          ),
          const _SeedArrow(),
          _SeedNode(
            icon: Icons.psychology_outlined,
            label: t.seed4Label,
            desc: t.seed4Desc,
            accent: colors.success,
          ),
        ],
      ),
    );
  }
}

class _SeedNode extends StatelessWidget {
  const _SeedNode({
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

class _SeedArrow extends StatelessWidget {
  const _SeedArrow();

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: SimpleSpacing.s2xs),
      child: Icon(Icons.south, size: 16, color: colors.muted),
    );
  }
}
