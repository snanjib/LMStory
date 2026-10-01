import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';

/// Theme-neutral setting card. The active structure owns its visual form.
class AdaptiveSettingCard extends StatelessWidget {
  const AdaptiveSettingCard({
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
        featured: true,
      );
}
