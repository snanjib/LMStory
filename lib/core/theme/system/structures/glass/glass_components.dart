import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/api/lm_motion_profile.dart';
import 'package:lmstory/core/theme/shared/components/composer_surface.dart';
import 'package:lmstory/core/theme/shared/components/navigation_card_content.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/system/structures/classic/classic_components.dart';
import 'package:lmstory/core/theme/system/structures/classic/conversation/simple_setting_card.dart';
import 'package:lmstory/core/theme/system/structures/classic/narrative/intermediate_setting_card.dart';
import 'package:lmstory/core/theme/system/structures/glass/glass_factories.dart';
import 'package:lmstory/core/theme/system/structures/glass/glass_materials.dart';
import 'package:lmstory/core/theme/system/structures/glass/glass_radii.dart';

/// Extends [ClassicComponents] so undifferentiated surfaces keep the
/// established look; overrides carry the glass differentiation.
class GlassComponents extends ClassicComponents {
  const GlassComponents();

  @override
  LmMotionProfile get motionProfile => const LmMotionProfile(
        enterOffset: Offset(0, 8),
        hoverOffset: Offset(0, -2),
      );

  @override
  double radius(LmCorner corner) => switch (corner) {
        LmCorner.xs => 4,
        LmCorner.sm => 8,
        LmCorner.md => 12,
        LmCorner.lg => 16,
        LmCorner.xl => 20,
        LmCorner.full => 9999,
      };

  @override
  bool get ownsSheetSurface => true;

  @override
  Widget venue(BuildContext context, Widget child) =>
      GlassBackdrop(child: child);

  @override
  Color scaffoldBackground(BuildContext context, Color fallback) =>
      GlassVenueScope.maybeOf(context) == null ? fallback : Colors.transparent;

  @override
  Color sidebarSurfaceColor(BuildContext context) =>
      GlassMaterials.fill6(context.lm.palette.bg);

  @override
  Widget card(
    BuildContext context, {
    required Widget child,
    EdgeInsetsGeometry padding = const EdgeInsets.all(LmSpacing.sLg),
    VoidCallback? onTap,
    bool selected = false,
  }) =>
      GlassCard(
        padding: padding,
        onTap: onTap,
        selected: selected,
        child: child,
      );

  @override
  Widget settingCard(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    bool featured = false,
    bool narrative = false,
    bool enabled = true,
  }) {
    if (narrative) {
      return ClassicNarrativeSettingCard(
        icon: icon,
        title: title,
        subtitle: subtitle,
        onTap: onTap,
        enabled: enabled,
      );
    }
    if (!featured) {
      return ClassicSettingCard(
        icon: icon,
        title: title,
        subtitle: subtitle,
        onTap: onTap,
        enabled: enabled,
      );
    }
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: Semantics(
        button: true,
        enabled: enabled,
        child: GlassCard(
          onTap: enabled ? onTap : null,
          child: NavigationCardContent(
            icon: icon,
            title: title,
            subtitle: subtitle,
          ),
        ),
      ),
    );
  }

  @override
  Widget entryCard(
    BuildContext context, {
    required Widget child,
    required VoidCallback onTap,
    required Color fallbackColor,
    bool horizontal = false,
  }) {
    final color = GlassMaterials.fill6(context.lm.palette.bg);
    final radius = BorderRadius.circular(GlassRadii.card);
    return Material(
      color: color,
      borderRadius: radius,
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        child: Padding(
          padding: const EdgeInsets.all(LmSpacing.sMd),
          child: child,
        ),
      ),
    );
  }

  @override
  TextStyle entryTitleStyle(BuildContext context, TextStyle fallback) =>
      fallback;

  @override
  Widget sessionRow(
    BuildContext context, {
    required Widget child,
    required VoidCallback onTap,
    required bool selected,
    required bool hovered,
  }) {
    final bg = context.lm.palette.bg;
    final radius = BorderRadius.circular(8);
    return Container(
      margin: const EdgeInsets.symmetric(
        horizontal: LmSpacing.sSm,
        vertical: 1,
      ),
      decoration: BoxDecoration(
        color: selected
            ? GlassMaterials.fill16(bg)
            : hovered
                ? GlassMaterials.fill6(bg)
                : Colors.transparent,
        borderRadius: radius,
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: LmSpacing.sMd,
            vertical: LmSpacing.sSm,
          ),
          child: child,
        ),
      ),
    );
  }

  @override
  Widget selectionRow(
    BuildContext context, {
    required Widget child,
    required VoidCallback? onTap,
    required bool selected,
  }) {
    final bg = context.lm.palette.bg;
    final radius = BorderRadius.circular(GlassRadii.card);
    return InkWell(
      onTap: onTap,
      borderRadius: radius,
      child: Container(
        margin: const EdgeInsets.symmetric(
          horizontal: LmSpacing.sSm,
          vertical: LmSpacing.s3xs,
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: LmSpacing.sSm,
          vertical: LmSpacing.sMd - LmSpacing.s3xs,
        ),
        decoration: BoxDecoration(
          color: selected ? GlassMaterials.fill16(bg) : Colors.transparent,
          borderRadius: radius,
        ),
        child: child,
      ),
    );
  }

  @override
  Widget messageBubble(
    BuildContext context, {
    required Widget child,
    required bool isUser,
    required bool standardLayout,
    bool summary = false,
    bool narrative = false,
  }) {
    final palette = context.lm.palette;
    if (narrative) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: isUser ? palette.primaryDim : Colors.transparent,
          borderRadius: BorderRadius.circular(GlassRadii.card),
        ),
        child: child,
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: narrative
            ? isUser
                ? palette.primaryDim
                : palette.surface
            : standardLayout
                ? Colors.transparent
                : isUser
                    ? palette.primary
                    : GlassMaterials.fill6(palette.bg),
        borderRadius: BorderRadius.circular(GlassRadii.card),
        border: summary
            ? Border(left: BorderSide(color: palette.accent, width: 3))
            : null,
      ),
      child: child,
    );
  }

  @override
  Widget inputArea(
    BuildContext context,
    Widget child, {
    bool narrative = false,
  }) {
    final palette = context.lm.palette;
    return ComposerSurface(
      color: palette.surfaceElevated,
      borderColor: palette.dividerStrong,
      child: child,
    );
  }

  @override
  Color? overlayBarrierColor(BuildContext context) =>
      context.lm.palette.scrim.withValues(alpha: 0.5);

  @override
  Color sheetFaceColor(BuildContext context, Color fallback) =>
      Colors.transparent;

  @override
  ShapeBorder? sheetShape(BuildContext context, ShapeBorder? fallback) =>
      Theme.of(context).bottomSheetTheme.shape;

  @override
  Clip? sheetClipBehavior(BuildContext context, Clip? fallback) =>
      Clip.antiAlias;

  @override
  Color settingCardFaceColor(BuildContext context, Color fallback) =>
      context.lm.palette.surfaceVariant;

  @override
  Widget sheetSurface(
    BuildContext context,
    Widget child, {
    bool showHandle = true,
  }) =>
      GlassBottomSheet(showHandle: showHandle, child: child);
}
