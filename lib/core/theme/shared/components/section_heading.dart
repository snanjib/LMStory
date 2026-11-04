import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/system/lm_narrative_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/system/lm_ui_text_styles.dart';

/// A readable section marker that wraps with the user's text size.
class SectionHeading extends StatelessWidget {
  const SectionHeading({
    required this.title,
    this.subtitle,
    super.key,
  });

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final description = subtitle;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Text(
            title,
            style: LmNarrativeTextStyles.narrativeDisplay.copyWith(
              color: colors.ink,
              fontSize: 22,
              height: 1.35,
            ),
          ),
        ),
        if (description != null && description.isNotEmpty) ...[
          const SizedBox(height: LmSpacing.sXs),
          Text(
            description,
            style: LmUiTextStyles.bodySm.copyWith(color: colors.muted),
          ),
        ],
      ],
    );
  }
}
