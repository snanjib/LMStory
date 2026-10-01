import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/system/structures/classic/classic_components.dart';

enum LmCorner { xs, sm, md, lg, xl, full }

/// The visual seam used by presentation code. A structure supplies every
/// surface; callers never select a structure by id.
abstract interface class LmComponentKit {
  bool get ownsSheetSurface;

  double radius(LmCorner corner);

  Widget venue(BuildContext context, Widget child);

  Color scaffoldBackground(BuildContext context, Color fallback);

  Color sidebarSurfaceColor(BuildContext context);

  Widget card(
    BuildContext context, {
    required Widget child,
    EdgeInsetsGeometry padding = const EdgeInsets.all(16),
    VoidCallback? onTap,
    bool selected = false,
  });

  Widget settingCard(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    bool featured = false,
    bool narrative = false,
    bool enabled = true,
  });

  Widget entryCard(
    BuildContext context, {
    required Widget child,
    required VoidCallback onTap,
    required Color fallbackColor,
    bool horizontal = false,
  });

  TextStyle entryTitleStyle(BuildContext context, TextStyle fallback);

  Widget sessionRow(
    BuildContext context, {
    required Widget child,
    required VoidCallback onTap,
    required bool selected,
    required bool hovered,
  });

  Widget selectionRow(
    BuildContext context, {
    required Widget child,
    required VoidCallback? onTap,
    required bool selected,
  });

  Widget messageBubble(
    BuildContext context, {
    required Widget child,
    required bool isUser,
    required bool standardLayout,
    bool summary = false,
    bool narrative = false,
  });

  Widget inputArea(
    BuildContext context,
    Widget child, {
    bool narrative = false,
  });

  Color? overlayBarrierColor(BuildContext context);

  Color sheetFaceColor(BuildContext context, Color fallback);

  ShapeBorder? sheetShape(BuildContext context, ShapeBorder? fallback);

  Clip? sheetClipBehavior(BuildContext context, Clip? fallback);

  Color settingCardFaceColor(BuildContext context, Color fallback);

  Widget sheetSurface(
    BuildContext context,
    Widget child, {
    bool showHandle = true,
  });
}

class LmComponents extends ThemeExtension<LmComponents> {
  const LmComponents(this.kit);

  final LmComponentKit kit;

  @override
  LmComponents copyWith({LmComponentKit? kit}) => LmComponents(kit ?? this.kit);

  @override
  LmComponents lerp(covariant LmComponents? other, double t) =>
      t < 0.5 || other == null ? this : other;
}

extension LmComponentContext on BuildContext {
  LmComponentKit get lmUi {
    final theme = Theme.of(this);
    final kit = theme.extension<LmComponents>()?.kit;
    if (kit == null) {
      // Embedded widgets and legacy test hosts can supply plain ThemeData.
      // A catalog theme with tokens must always carry a matching kit.
      if (theme.extension<LmTokens>() == null) {
        return const ClassicComponents();
      }
      throw StateError('LmComponentKit is missing from the active theme');
    }
    return kit;
  }
}

/// Route and scaffold surfaces are selected by the active implementation.
extension LmVenueContext on BuildContext {
  Widget lmVenue(Widget child) => lmUi.venue(this, child);

  Color scaffoldBgOf(Color fallback) => lmUi.scaffoldBackground(this, fallback);
}
