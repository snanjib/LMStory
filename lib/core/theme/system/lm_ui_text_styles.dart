import 'package:flutter/material.dart';

/// Simple mode typography tokens.
///
/// Family: Inter — the gold standard for product UI.
/// Familiar, legible, extensive weight range. Not exciting; that's the point.
/// Simple mode is a tool, not a spectacle.
///
/// Fixed scale (not fluid). Product UI needs consistency at every viewport.
class LmUiTextStyles {
  LmUiTextStyles._();

  static const String fontFamily = 'Inter';

  // ── Display / Headline ─────────────────────────────────────────────

  static const TextStyle display = TextStyle(
    fontSize: 28,
    fontWeight: FontWeight.w700,
    height: 1.3,
    letterSpacing: -0.02,
  );

  static const TextStyle title1 = TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.w700,
    height: 1.35,
    letterSpacing: -0.015,
  );

  static const TextStyle title2 = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.w600,
    height: 1.4,
    letterSpacing: -0.01,
  );

  static const TextStyle title3 = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w500,
    height: 1.45,
  );

  // ── Body ───────────────────────────────────────────────────────────

  static const TextStyle body = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w400,
    height: 1.6,
  );

  static const TextStyle bodySm = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w400,
    height: 1.55,
  );

  // ── Caption / Overline ─────────────────────────────────────────────

  static const TextStyle caption = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w500,
    height: 1.5,
    letterSpacing: 0.02,
  );

  static const TextStyle overline = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w600,
    height: 1.4,
    letterSpacing: 0.06,
  );
}
