import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/system/lm_narrative_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';

/// A task heading whose controls remain reachable beside long titles.
class PanelHeading extends StatelessWidget {
  const PanelHeading({
    required this.title,
    this.subtitle,
    this.leading,
    this.actions = const [],
    super.key,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final heading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          header: true,
          child: Text(
            title,
            style: (Theme.of(context).dialogTheme.titleTextStyle ??
                    LmNarrativeTextStyles.narrativeDisplay)
                .copyWith(color: colors.ink, fontSize: 24, height: 1.3),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (subtitle case final subtitle?) ...[
          const SizedBox(height: LmSpacing.sXs),
          Text(
            subtitle,
            style: LmNarrativeTextStyles.label.copyWith(color: colors.muted),
          ),
        ],
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final stackedActions = actions.length > 1 &&
            (constraints.maxWidth < 420 ||
                MediaQuery.textScalerOf(context).scale(1) > 1.3);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (leading case final leading?) ...[
                  leading,
                  const SizedBox(width: LmSpacing.sSm),
                ],
                Expanded(child: heading),
                if (!stackedActions && actions.isNotEmpty) ...[
                  const SizedBox(width: LmSpacing.sSm),
                  ...actions,
                ],
              ],
            ),
            if (stackedActions) ...[
              const SizedBox(height: LmSpacing.sXs),
              Wrap(alignment: WrapAlignment.end, children: actions),
            ],
          ],
        );
      },
    );
  }
}
