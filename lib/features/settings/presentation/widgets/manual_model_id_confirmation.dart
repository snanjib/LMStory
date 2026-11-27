import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/i18n/strings.g.dart';

// Limit the check to common keyboard substitutions. Providers can define IDs
// with other Unicode characters, and even a look-alike can be intentional.
final _lookAlikeCharacter = RegExp(
  r'[\uFF01-\uFF5E\u2010-\u2015\u2212\uFE63\u2018-\u201F'
  r'\u00AD\u00A0\u200B-\u200D\u2060\u3000\uFEFF]',
);

/// Allow a manually entered ID as-is only after confirming a look-alike.
/// IDs selected from a provider's model list do not need this check.
Future<bool> confirmManualModelId(BuildContext context, String id) async {
  final character = _lookAlikeCharacter.stringMatch(id);
  if (character == null) return true;

  final codePoint =
      character.runes.single.toRadixString(16).toUpperCase().padLeft(4, '0');
  final labels = Translations.of(context).settings.provider;
  final confirmed = await showLmDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      scrollable: true,
      title: Text(labels.modelIdCheckTitle),
      content: Text(labels.modelIdCheckMessage(codePoint: 'U+$codePoint')),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(labels.modelIdKeep),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(labels.modelIdEdit),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
