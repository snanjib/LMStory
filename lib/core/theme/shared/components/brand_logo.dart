import 'package:flutter/material.dart';

/// The adopted LMStory v1 logo, with an automatic light/dark artwork variant.
///
/// The source SVGs are kept in [assets/branding/] for design handoff. Flutter
/// uses the generated PNGs here so the app does not need an SVG runtime
/// dependency just to render its own mark.
class BrandLogo extends StatelessWidget {
  const BrandLogo({
    super.key,
    this.size = 48,
    this.semanticLabel = 'LMStory',
  });

  final double size;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final asset = isDark
        ? 'assets/branding/lmstory_logo_v1_dark.png'
        : 'assets/branding/lmstory_logo_v1.png';

    return Image.asset(
      asset,
      width: size,
      height: size,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.high,
      semanticLabel: semanticLabel,
    );
  }
}
