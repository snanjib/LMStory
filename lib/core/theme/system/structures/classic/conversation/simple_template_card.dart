import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/system/lm_ui_text_styles.dart';
import 'package:lmstory/features/templates/domain/entities/template.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// Simple mode template card — Container (no Card widget).
///
/// Displays template name, optional built-in badge, and content preview.
class SimpleTemplateCard extends StatelessWidget {
  const SimpleTemplateCard({
    required this.template,
    super.key,
  });

  final Template template;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    return Container(
      margin: const EdgeInsets.only(bottom: LmSpacing.sSm),
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(LmSpacing.sMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    template.name,
                    style: LmUiTextStyles.body.copyWith(
                      fontWeight: FontWeight.w500,
                      color: colors.ink,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (template.isBuiltIn)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: LmSpacing.sXs,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: colors.divider,
                      borderRadius: BorderRadius.circular(
                        context.lmUi.radius(LmCorner.xs),
                      ),
                    ),
                    child: Text(
                      t.settings.provider.builtIn,
                      style: LmUiTextStyles.overline.copyWith(
                        color: colors.accent,
                        fontSize: 11,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: LmSpacing.s2xs),
            Text(
              template.content,
              style: LmUiTextStyles.caption.copyWith(
                color: colors.muted,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
