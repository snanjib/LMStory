import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 外观与主题示意图（2026-07-27 新增）。
///
/// 用于「外观与主题」wiki 页顶部主视觉。
///
/// 设计：
/// - 上段：3 种主题模式（深色 / 浅色 / 跟随系统）
/// - 下段：字体大小 10 档（12 px 紧凑 → 15 px 默认 → 22 px 大字）
class AppearanceDiagram extends StatelessWidget {
  const AppearanceDiagram({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 上段：3 种主题模式
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
              Text(
                t.help.appearance.diagramThemeTitle,
                style: SimpleTextStyles.bodySm.copyWith(
                  color: colors.muted,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: SimpleSpacing.sSm),
              Row(
                children: [
                  Expanded(
                    child: _ThemeCard(
                      icon: Icons.dark_mode_outlined,
                      label: t.help.appearance.themeDark,
                      desc: t.help.appearance.themeDarkDesc,
                      highlight: false,
                    ),
                  ),
                  const SizedBox(width: SimpleSpacing.sXs),
                  Expanded(
                    child: _ThemeCard(
                      icon: Icons.light_mode_outlined,
                      label: t.help.appearance.themeLight,
                      desc: t.help.appearance.themeLightDesc,
                      highlight: false,
                    ),
                  ),
                  const SizedBox(width: SimpleSpacing.sXs),
                  Expanded(
                    child: _ThemeCard(
                      icon: Icons.brightness_auto_outlined,
                      label: t.help.appearance.themeSystem,
                      desc: t.help.appearance.themeSystemDesc,
                      highlight: true,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: SimpleSpacing.sMd),

        // 下段：字体大小 10 档
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
                t.help.appearance.diagramFontTitle,
                style: SimpleTextStyles.bodySm.copyWith(
                  color: colors.muted,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: SimpleSpacing.sSm),
              Row(
                children: [
                  _FontEnd(
                    label: t.help.appearance.fontMin,
                    desc: t.help.appearance.fontMinDesc,
                  ),
                  Expanded(
                    child: Container(
                      height: 2,
                      decoration: BoxDecoration(
                        color: colors.divider,
                        borderRadius: BorderRadius.circular(
                          context.lmUi.radius(LmCorner.full),
                        ),
                      ),
                      child: Row(
                        children: [
                          // 10 档刻度示意
                          for (int i = 0; i < 10; i++)
                            Expanded(
                              child: Container(
                                margin:
                                    const EdgeInsets.symmetric(horizontal: 1),
                                height: 6,
                                width: 2,
                                color: i == 3 ? colors.primary : colors.faint,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  _FontEnd(
                    label: t.help.appearance.fontMax,
                    desc: t.help.appearance.fontMaxDesc,
                  ),
                ],
              ),
              const SizedBox(height: SimpleSpacing.sXs),
              Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: SimpleSpacing.sSm,
                    vertical: SimpleSpacing.s2xs,
                  ),
                  decoration: BoxDecoration(
                    color: colors.primaryDim,
                    borderRadius: BorderRadius.circular(
                      context.lmUi.radius(LmCorner.full),
                    ),
                  ),
                  child: Text(
                    '${t.help.appearance.fontDefault} · ${t.help.appearance.fontDefaultDesc}',
                    style: SimpleTextStyles.caption.copyWith(
                      color: colors.primary,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ThemeCard extends StatelessWidget {
  const _ThemeCard({
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

    return Container(
      padding: const EdgeInsets.all(SimpleSpacing.sSm),
      decoration: BoxDecoration(
        color: highlight ? colors.primaryDim : colors.surface,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
        border: Border.all(color: highlight ? colors.primary : colors.divider),
      ),
      child: Column(
        children: [
          Icon(
            icon,
            color: highlight ? colors.primary : colors.muted,
            size: 20,
          ),
          const SizedBox(height: SimpleSpacing.s2xs),
          Text(
            label,
            style: SimpleTextStyles.caption.copyWith(
              color: highlight ? colors.primary : colors.ink,
              fontWeight: FontWeight.w600,
            ),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: SimpleSpacing.s2xs),
          Text(
            desc,
            style: SimpleTextStyles.caption.copyWith(
              color: colors.muted,
              fontSize: 10,
              height: 1.3,
            ),
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class _FontEnd extends StatelessWidget {
  const _FontEnd({required this.label, required this.desc});

  final String label;
  final String desc;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Column(
      children: [
        Text(
          label,
          style: SimpleTextStyles.caption.copyWith(
            color: colors.muted,
            fontWeight: FontWeight.w600,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        Text(
          desc,
          style: SimpleTextStyles.caption.copyWith(
            color: colors.faint,
            fontSize: 10,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}
