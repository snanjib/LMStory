import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/api/lm_motion_profile.dart';
import 'package:lmstory/core/theme/shared/components/composer_surface.dart';
import 'package:lmstory/core/theme/shared/components/navigation_card_content.dart';
import 'package:lmstory/core/theme/system/lm_narrative_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/system/structures/classic/classic_components.dart';

/// A quiet narrative gallery: the writing remains the brightest exhibit.
///
/// Extends [ClassicComponents] so undifferentiated surfaces keep the
/// established look; overrides carry the wonder differentiation.
class WonderComponents extends ClassicComponents {
  const WonderComponents();

  @override
  LmMotionProfile get motionProfile => const LmMotionProfile(
        enterOffset: Offset(0, 10),
        hoverOffset: Offset(0, -2),
      );

  @override
  double radius(LmCorner corner) => switch (corner) {
        LmCorner.xs => 4,
        LmCorner.sm => 8,
        LmCorner.md => 12,
        LmCorner.lg => 24,
        LmCorner.xl => 32,
        LmCorner.full => 9999,
      };

  @override
  bool get ownsSheetSurface => false;

  static const cardRadius = BorderRadius.all(Radius.circular(32));
  static const rowRadius = BorderRadius.all(Radius.circular(8));
  static const archRadius = BorderRadius.only(
    topLeft: Radius.circular(32),
    topRight: Radius.circular(32),
    bottomLeft: Radius.circular(8),
    bottomRight: Radius.circular(8),
  );

  @override
  Widget venue(BuildContext context, Widget child) =>
      WonderBackdrop(child: child);

  @override
  Color scaffoldBackground(BuildContext context, Color fallback) =>
      WonderVenueScope.maybeOf(context) == null ? fallback : Colors.transparent;

  @override
  Color sidebarSurfaceColor(BuildContext context) => context.lm.palette.surface;

  @override
  Widget card(
    BuildContext context, {
    required Widget child,
    EdgeInsetsGeometry padding = const EdgeInsets.all(LmSpacing.sLg),
    VoidCallback? onTap,
    bool selected = false,
  }) {
    final palette = context.lm.palette;
    return Material(
      color: selected ? palette.surfaceElevated : palette.surface,
      borderRadius: cardRadius,
      child: InkWell(
        onTap: onTap,
        borderRadius: cardRadius,
        child: Padding(padding: padding, child: child),
      ),
    );
  }

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
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: Semantics(
        button: true,
        enabled: enabled,
        child: card(
          context,
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
    final palette = context.lm.palette;
    if (!horizontal) {
      final shape = RoundedRectangleBorder(
        borderRadius: cardRadius,
        side: BorderSide(color: palette.dividerStrong),
      );
      return Material(
        color: palette.surface,
        shape: shape,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          customBorder: shape,
          child: Padding(
            padding: const EdgeInsets.all(LmSpacing.sMd),
            child: child,
          ),
        ),
      );
    }
    return Material(
      color: palette.surface,
      borderRadius: archRadius,
      child: InkWell(
        onTap: onTap,
        borderRadius: archRadius,
        child: Padding(
          padding: const EdgeInsets.all(LmSpacing.sMd),
          child: child,
        ),
      ),
    );
  }

  @override
  TextStyle entryTitleStyle(BuildContext context, TextStyle fallback) =>
      LmNarrativeTextStyles.narrativeDisplay.copyWith(
        color: context.lm.palette.ink,
        fontSize: 22,
      );

  @override
  Widget sessionRow(
    BuildContext context, {
    required Widget child,
    required VoidCallback onTap,
    required bool selected,
    required bool hovered,
  }) {
    final palette = context.lm.palette;
    return Container(
      margin:
          const EdgeInsets.symmetric(horizontal: LmSpacing.sSm, vertical: 1),
      decoration: BoxDecoration(
        color: selected
            ? palette.surfaceElevated
            : hovered
                ? palette.surfaceVariant
                : Colors.transparent,
        borderRadius: rowRadius,
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: rowRadius,
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
    final palette = context.lm.palette;
    return InkWell(
      onTap: onTap,
      borderRadius: rowRadius,
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
          color: selected ? palette.surfaceElevated : Colors.transparent,
          borderRadius: rowRadius,
          border: Border(
            left: BorderSide(
              color: selected ? palette.accent : Colors.transparent,
              width: 3,
            ),
          ),
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
          borderRadius: cardRadius,
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
                    : palette.surface,
        borderRadius: archRadius,
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
      color: palette.surface,
      borderColor: palette.dividerStrong,
      child: child,
    );
  }

  @override
  Color? overlayBarrierColor(BuildContext context) => context.lm.palette.scrim;

  @override
  Color sheetFaceColor(BuildContext context, Color fallback) => fallback;

  @override
  ShapeBorder? sheetShape(BuildContext context, ShapeBorder? fallback) =>
      Theme.of(context).bottomSheetTheme.shape;

  @override
  Clip? sheetClipBehavior(BuildContext context, Clip? fallback) =>
      Clip.antiAlias;

  @override
  Color settingCardFaceColor(BuildContext context, Color fallback) =>
      context.lm.palette.surface;

  @override
  Widget sheetSurface(
    BuildContext context,
    Widget child, {
    bool showHandle = true,
  }) =>
      child;
}

class WonderVenueScope extends InheritedWidget {
  const WonderVenueScope({required super.child, super.key});

  static WonderVenueScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<WonderVenueScope>();

  @override
  bool updateShouldNotify(WonderVenueScope oldWidget) => false;
}

class WonderBackdrop extends StatelessWidget {
  const WonderBackdrop({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final palette = context.lm.palette;
    return WonderVenueScope(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [palette.bgGlow, palette.bg, palette.bg],
            stops: const [0, 0.42, 1],
          ),
        ),
        child: child,
      ),
    );
  }
}
