import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/system/lm_ui_text_styles.dart';

/// Simple mode setting card — Container + InkWell (no Card widget).
///
/// Displays an icon (with surface background), title, subtitle, and a
/// trailing chevron. Used on the Settings page for navigation entries.
class SimpleSettingCard extends StatelessWidget {
  const SimpleSettingCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => context.lmUi.settingCard(
        context,
        icon: icon,
        title: title,
        subtitle: subtitle,
        onTap: onTap,
      );
}

/// The classic implementation kept intact for visual parity.
class ClassicSettingCard extends StatelessWidget {
  const ClassicSettingCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Container(
      decoration: BoxDecoration(
        // 琉璃下统一到 surfaceVariant 槽（与 IntermediateSettingCard 同材质，
        // 消除一白一透的割裂）；经典保持原槽位零变化。
        color: context.lmSettingCardFace(colors.surfaceVariant),
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
      ),
      child: Material(
        color: Colors.transparent,
        //  语义修复：可点整卡无交互角色时读屏器当静态文本。
        // 补 button 角色；标题/副标题仍由子树合并进同一节点。
        child: Semantics(
          button: true,
          child: InkWell(
            onTap: onTap,
            borderRadius:
                BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
            child: Padding(
              padding: const EdgeInsets.all(LmSpacing.sLg),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: colors.surface,
                      borderRadius: BorderRadius.circular(
                        context.lmUi.radius(LmCorner.md),
                      ),
                    ),
                    child: Icon(
                      icon,
                      color: colors.primary,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: LmSpacing.sMd),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: LmUiTextStyles.body.copyWith(
                            color: colors.ink,
                            fontWeight: FontWeight.w500,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          style: LmUiTextStyles.caption.copyWith(
                            color: colors.muted,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    Icons.chevron_right,
                    color: colors.faint,
                    size: 20,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
