import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/system/lm_palette.dart';

/// Keep secondary text readable on both the page and its reading surface.
Color directorReadableColor(LmPalette palette, [Color? preferred]) {
  final original = preferred ?? palette.muted;
  bool readable(Color color) => [palette.bg, palette.surface].every((bg) {
        final a = color.computeLuminance();
        final b = bg.computeLuminance();
        final ratio = a > b ? (a + .05) / (b + .05) : (b + .05) / (a + .05);
        return ratio >= 4.5;
      });
  for (var step = 0; step <= 20; step++) {
    final color = Color.lerp(original, palette.ink, step / 20)!;
    if (readable(color)) return color;
  }
  return palette.ink;
}
