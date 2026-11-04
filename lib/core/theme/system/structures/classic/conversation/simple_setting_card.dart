import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/shared/components/navigation_card_content.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';

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

/// Classic surface with shared destination typography.
class ClassicSettingCard extends StatelessWidget {
  const ClassicSettingCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.enabled = true,
    super.key,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final borderRadius = BorderRadius.circular(
      context.lmUi.radius(LmCorner.lg),
    );
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: Container(
        decoration: BoxDecoration(
          color: context.lmSettingCardFace(colors.surfaceVariant),
          borderRadius: borderRadius,
        ),
        child: Material(
          color: Colors.transparent,
          child: Semantics(
            button: true,
            enabled: enabled,
            child: InkWell(
              onTap: enabled ? onTap : null,
              borderRadius: borderRadius,
              child: Padding(
                padding: const EdgeInsets.all(LmSpacing.sLg),
                child: NavigationCardContent(
                  icon: icon,
                  title: title,
                  subtitle: subtitle,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
