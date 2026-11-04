import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/shared/components/lm_arrival.dart';
import 'package:lmstory/core/theme/shared/components/section_heading.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';

/// One surface per navigation group, keeping destinations in reading order.
class SettingsNavigationGroup extends StatelessWidget {
  const SettingsNavigationGroup({
    required this.title,
    required this.children,
    super.key,
  });

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => LmArrival(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionHeading(title: title),
            const SizedBox(height: LmSpacing.sMd),
            context.lmUi.card(
              context,
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  for (var index = 0; index < children.length; index++) ...[
                    if (index > 0)
                      Divider(
                        height: 1,
                        indent: LmSpacing.sLg,
                        endIndent: LmSpacing.sLg,
                        color: context.lm.palette.divider,
                      ),
                    children[index],
                  ],
                ],
              ),
            ),
          ],
        ),
      );
}
