import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/system/structures/brutal/brutal_factories.dart';
import 'package:lmstory/core/theme/system/structures/brutal/brutal_materials.dart';
import 'package:lmstory/core/theme/system/structures/brutal/brutal_radii.dart';
import 'package:lmstory/core/theme/system/structures/brutal/brutal_text_styles.dart';

class BrutalComponents implements LmComponentKit {
  const BrutalComponents();

  @override
  double radius(LmCorner corner) => 0;

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
  }) =>
      BrutalCard(
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
    final palette = context.lm.palette;
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: BrutalCard(
        onTap: enabled ? onTap : null,
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: palette.primaryDim,
                borderRadius: BorderRadius.circular(BrutalRadii.cornerNone),
              ),
              child: Icon(icon, color: palette.primary, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: BrutalTextStyles.body.copyWith(color: palette.ink),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    subtitle,
                    style: BrutalTextStyles.caption.copyWith(
                      color: palette.muted,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 20, color: palette.faint),
          ],
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
    const radius = BorderRadius.zero;
    return Material(
      color: fallbackColor,
      shape: RoundedRectangleBorder(
        side: BorderSide(
          color: BrutalMaterials.frameOf(palette),
          width: BrutalRadii.frameCard,
        ),
      ),
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
      BrutalTextStyles.body.copyWith(
        color: context.lm.palette.ink,
        fontWeight: FontWeight.w700,
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
      margin: const EdgeInsets.symmetric(
        horizontal: LmSpacing.sSm,
        vertical: 1,
      ),
      decoration: BoxDecoration(
        color: selected
            ? palette.primaryDim
            : hovered
                ? palette.surfaceVariant
                : Colors.transparent,
        borderRadius: BorderRadius.zero,
        border: selected
            ? Border.all(
                color: BrutalMaterials.frameOf(palette),
                width: BrutalRadii.frameInline,
              )
            : null,
      ),
      child: InkWell(
        onTap: onTap,
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
          color: selected ? palette.primaryDim : Colors.transparent,
          border: Border.all(
            color: selected
                ? BrutalMaterials.frameOf(palette)
                : Colors.transparent,
            width: BrutalRadii.frameInline,
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
        border: standardLayout
            ? null
            : Border.all(
                color: BrutalMaterials.frameOf(palette),
                width: BrutalRadii.frameInline,
              ),
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
    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.surfaceElevated,
        border: Border(
          top: BorderSide(
            color: BrutalMaterials.frameOf(palette),
            width: BrutalRadii.frameCard,
          ),
        ),
      ),
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
  Color settingCardFaceColor(BuildContext context, Color fallback) => fallback;

  @override
  Widget sheetSurface(
    BuildContext context,
    Widget child, {
    bool showHandle = true,
  }) =>
      child;
}
