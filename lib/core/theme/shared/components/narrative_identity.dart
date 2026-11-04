import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/system/lm_layout.dart';
import 'package:lmstory/core/theme/system/lm_narrative_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';

/// A name supplies the visual identity when no portrait is stored.
class NarrativeIdentity extends StatelessWidget {
  const NarrativeIdentity({
    required this.name,
    required this.label,
    this.details,
    super.key,
  });

  final String name;
  final String label;
  final Widget? details;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final trimmed = name.trim();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: LmSpacing.sLg),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (trimmed.isNotEmpty) ...[
            ExcludeSemantics(
              child: Container(
                width: 88,
                height: 112,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: colors.primaryDim,
                  borderRadius: BorderRadius.circular(
                    context.lmUi.radius(LmCorner.sm),
                  ),
                ),
                child: Text(
                  trimmed.characters.first,
                  textScaler: TextScaler.noScaling,
                  style: LmNarrativeTextStyles.narrativeHeadline.copyWith(
                    fontSize: 64,
                    color: colors.primary,
                  ),
                ),
              ),
            ),
            const SizedBox(width: LmSpacing.sLg),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: LmNarrativeTextStyles.caption.copyWith(
                    color: colors.muted,
                  ),
                ),
                if (trimmed.isNotEmpty) ...[
                  const SizedBox(height: LmSpacing.sXs),
                  Text(
                    name,
                    style: LmNarrativeTextStyles.narrativeHeadline.copyWith(
                      color: colors.ink,
                    ),
                  ),
                ],
                if (details != null) ...[
                  const SizedBox(height: LmSpacing.sSm),
                  details!,
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Scrolls away with the opening; never occupies the streaming reading area.
class StoryOpening extends StatelessWidget {
  const StoryOpening({
    required this.title,
    required this.modeLabel,
    this.narrativeTime,
    super.key,
  });

  final String title;
  final String modeLabel;
  final String? narrativeTime;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: LmLayout.readingWidthOf(context)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                modeLabel,
                style: LmNarrativeTextStyles.caption.copyWith(
                  color: colors.primary,
                  letterSpacing: 1.5,
                ),
              ),
              const SizedBox(height: LmSpacing.sMd),
              Text(
                title,
                style: LmNarrativeTextStyles.narrativeHeadline.copyWith(
                  fontSize: 40,
                  color: colors.ink,
                ),
              ),
              if (narrativeTime case final time?
                  when time.trim().isNotEmpty) ...[
                const SizedBox(height: LmSpacing.sMd),
                Text(
                  time,
                  style: LmNarrativeTextStyles.caption.copyWith(
                    color: colors.muted,
                  ),
                ),
              ],
              const SizedBox(height: LmSpacing.sLg),
              Divider(height: 1, color: colors.divider),
            ],
          ),
        ),
      ),
    );
  }
}
