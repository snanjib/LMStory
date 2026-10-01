import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/system/lm_radius.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/system/structures/classic/conversation/simple_setting_card.dart';
import 'package:lmstory/core/theme/system/structures/classic/narrative/intermediate_setting_card.dart';

/// Preserves the established classic surfaces while giving them the same
/// interface as every other structure.
class ClassicComponents implements LmComponentKit {
  const ClassicComponents();

  @override
  double radius(LmCorner corner) => switch (corner) {
        LmCorner.xs => LmRadius.rXs,
        LmCorner.sm => LmRadius.rSm,
        LmCorner.md => LmRadius.rMd,
        LmCorner.lg => LmRadius.rLg,
        LmCorner.xl => LmRadius.rXl,
        LmCorner.full => LmRadius.rFull,
      };

  @override
  bool get ownsSheetSurface => false;

  @override
  Widget venue(BuildContext context, Widget child) => child;

  @override
  Color scaffoldBackground(BuildContext context, Color fallback) => fallback;

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
    final colors = context.lm.palette;
    return Material(
      color: selected ? colors.primaryDim : colors.surfaceVariant,
      borderRadius: BorderRadius.circular(LmRadius.rLg),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(LmRadius.rLg),
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
  }) =>
      narrative
          ? ClassicNarrativeSettingCard(
              icon: icon,
              title: title,
              subtitle: subtitle,
              onTap: onTap,
              enabled: enabled,
            )
          : ClassicSettingCard(
              icon: icon,
              title: title,
              subtitle: subtitle,
              onTap: onTap,
            );

  @override
  Widget entryCard(
    BuildContext context, {
    required Widget child,
    required VoidCallback onTap,
    required Color fallbackColor,
    bool horizontal = false,
  }) =>
      Material(
        color: fallbackColor,
        borderRadius: BorderRadius.circular(LmRadius.rLg),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(LmRadius.rLg),
          child: Padding(
            padding: const EdgeInsets.all(LmSpacing.sMd),
            child: child,
          ),
        ),
      );

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
    final colors = context.lm.palette;
    return Container(
      margin: const EdgeInsets.symmetric(
        horizontal: LmSpacing.sSm,
        vertical: 1,
      ),
      decoration: BoxDecoration(
        color: selected
            ? colors.primaryDim
            : hovered
                ? colors.surfaceVariant
                : Colors.transparent,
        borderRadius: BorderRadius.circular(LmRadius.rSm),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(LmRadius.rSm),
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
    final colors = context.lm.palette;
    final radius = BorderRadius.circular(LmRadius.rMd);
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
          color: selected ? colors.primaryDim : Colors.transparent,
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
    final colors = context.lm.palette;
    if (narrative) {
      return Container(
        padding: const EdgeInsets.symmetric(
          horizontal: LmSpacing.sLg,
          vertical: LmSpacing.sMd,
        ),
        decoration: BoxDecoration(
          color: isUser ? colors.primaryDim : colors.surface,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(LmRadius.rMd),
            topRight: const Radius.circular(LmRadius.rMd),
            bottomLeft:
                isUser ? const Radius.circular(LmRadius.rMd) : Radius.zero,
            bottomRight:
                isUser ? Radius.zero : const Radius.circular(LmRadius.rMd),
          ),
        ),
        child: child,
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: standardLayout
            ? Colors.transparent
            : isUser
                ? colors.primary
                : colors.surfaceVariant,
        borderRadius: standardLayout
            ? BorderRadius.circular(LmRadius.rLg)
            : BorderRadius.only(
                topLeft: const Radius.circular(LmRadius.rLg),
                topRight: const Radius.circular(LmRadius.rLg),
                bottomLeft: Radius.circular(
                  isUser ? LmRadius.rLg : LmRadius.rXs,
                ),
                bottomRight: Radius.circular(
                  isUser ? LmRadius.rXs : LmRadius.rLg,
                ),
              ),
        border: summary
            ? Border(left: BorderSide(color: colors.accent, width: 3))
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
    final colors = context.lm.palette;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: narrative ? colors.bg : colors.surfaceElevated,
        border: Border(top: BorderSide(color: colors.divider)),
      ),
      child: child,
    );
  }

  @override
  Color? overlayBarrierColor(BuildContext context) => null;

  @override
  Color sheetFaceColor(BuildContext context, Color fallback) => fallback;

  @override
  ShapeBorder? sheetShape(BuildContext context, ShapeBorder? fallback) =>
      fallback;

  @override
  Clip? sheetClipBehavior(BuildContext context, Clip? fallback) => fallback;

  @override
  Color settingCardFaceColor(BuildContext context, Color fallback) => fallback;

  @override
  Widget sheetSurface(
    BuildContext context,
    Widget child, {
    bool showHandle = true,
  }) =>
      child;
}
