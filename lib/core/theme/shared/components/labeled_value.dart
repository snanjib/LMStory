import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/system/lm_narrative_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';

/// Readable metadata without losing long values to a one-line truncation.
class LabeledValue extends StatelessWidget {
  const LabeledValue({
    required this.label,
    required this.value,
    this.valueColor,
    this.prominent = false,
    super.key,
  });

  final String label;
  final String value;
  final Color? valueColor;
  final bool prominent;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final labelText = Text(
      label,
      style: LmNarrativeTextStyles.label.copyWith(color: colors.muted),
    );
    final valueStyle = (prominent
            ? LmNarrativeTextStyles.narrativeDisplay.copyWith(fontSize: 32)
            : LmNarrativeTextStyles.label)
        .copyWith(
      color: valueColor ?? colors.ink,
    );
    return MergeSemantics(
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (prominent ||
              constraints.maxWidth < 360 ||
              MediaQuery.textScalerOf(context).scale(1) > 1.3) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                labelText,
                const SizedBox(height: LmSpacing.s2xs),
                Text(value, style: valueStyle),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: labelText),
              const SizedBox(width: LmSpacing.sMd),
              Expanded(
                child: Text(
                  value,
                  style: valueStyle,
                  textAlign: TextAlign.end,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
