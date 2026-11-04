import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/system/structures/glass/glass_factories.dart';
import 'package:lmstory/core/theme/system/structures/glass/glass_materials.dart';

/// Floating-panel venue served by every structure today (mobile drawer).
///
/// The panel carries its own backdrop: it floats above scrim and page
/// instead of the shell venue, where the shared backdrop alone would read
/// as dead grey. The composition is the venue gradient plus the  float
/// shadow — no blur, so the  whitelist stays untouched. This is the
/// current product decision, not a per-structure differentiation:
/// structures override the kit panelVenue to diverge, at which
/// point this helper serves whoever keeps the shared look.
Widget structurePanelVenue(BuildContext context, Widget child) => DecoratedBox(
      decoration: BoxDecoration(
        boxShadow: GlassMaterials.floatShadow(Theme.of(context).brightness),
      ),
      child: GlassBackdrop(child: child),
    );
