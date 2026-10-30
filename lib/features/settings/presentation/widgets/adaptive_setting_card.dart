import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/shared/components/navigation_card_content.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';

/// Theme-neutral setting card. The active structure owns its visual form.
class AdaptiveSettingCard extends StatelessWidget {
  const AdaptiveSettingCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.inline = false,
    super.key,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool inline;

  @override
  Widget build(BuildContext context) => inline
      ? Semantics(
          button: true,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(
                context.lmUi.radius(LmCorner.lg),
              ),
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
        )
      : context.lmUi.settingCard(
          context,
          icon: icon,
          title: title,
          subtitle: subtitle,
          onTap: onTap,
          featured: true,
        );
}
