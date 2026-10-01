import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/system/lm_button_metrics.dart';
import 'package:lmstory/core/theme/system/lm_narrative_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_page_transitions.dart';
import 'package:lmstory/core/theme/system/lm_structure.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/system/lm_ui_text_styles.dart';
import 'package:lmstory/core/theme/system/structures/wonder/wonder_components.dart';

/// A reading-first gallery adapted to LMStory's own content and controls.
class WonderStructure implements LmStructure {
  const WonderStructure();

  @override
  String get id => 'wonder';

  @override
  LmComponentKit buildComponents() => const WonderComponents();

  @override
  ThemeData assemble(LmPalette palette, Brightness brightness) {
    final light = brightness == Brightness.light;
    final scheme = light
        ? ColorScheme.light(
            primary: palette.primary,
            onPrimary: palette.onPrimary,
            secondary: palette.accent,
            onSecondary: palette.ink,
            error: palette.error,
            surface: palette.surface,
            onSurface: palette.ink,
          )
        : ColorScheme.dark(
            primary: palette.primary,
            onPrimary: palette.onPrimary,
            secondary: palette.accent,
            onSecondary: palette.ink,
            error: palette.error,
            surface: palette.surface,
            onSurface: palette.ink,
          );
    const cardShape = RoundedRectangleBorder(
      borderRadius: WonderComponents.cardRadius,
    );
    const rowShape = RoundedRectangleBorder(
      borderRadius: WonderComponents.rowRadius,
    );
    const pillShape = StadiumBorder();
    return ThemeData(
      brightness: brightness,
      colorScheme: scheme,
      fontFamily: LmUiTextStyles.fontFamily,
      splashFactory: NoSplash.splashFactory,
      scaffoldBackgroundColor: palette.bg,
      pageTransitionsTheme: lmPageTransitionsTheme(palette),
      textTheme: const TextTheme(
        headlineLarge: LmNarrativeTextStyles.narrativeDisplay,
        titleLarge: LmNarrativeTextStyles.narrativeDisplay,
        titleMedium: LmNarrativeTextStyles.title,
        titleSmall: LmUiTextStyles.title3,
        bodyLarge: LmUiTextStyles.body,
        bodyMedium: LmUiTextStyles.bodySm,
        bodySmall: LmUiTextStyles.caption,
        labelLarge: LmUiTextStyles.bodySm,
        labelSmall: LmUiTextStyles.overline,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: palette.ink,
        elevation: 0,
        titleTextStyle: LmNarrativeTextStyles.narrativeDisplay.copyWith(
          color: palette.ink,
          fontSize: 22,
        ),
      ),
      cardTheme: CardThemeData(
        color: palette.surface,
        elevation: 0,
        shape: cardShape,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: palette.primary,
          foregroundColor: palette.onPrimary,
          disabledBackgroundColor: palette.surfaceVariant,
          disabledForegroundColor: palette.faint,
          minimumSize: LmButtonMetrics.minimumSize,
          padding: LmButtonMetrics.solidPadding,
          shape: pillShape,
          textStyle: LmButtonMetrics.label(LmUiTextStyles.bodySm),
        ).copyWith(elevation: LmButtonMetrics.flatElevationProperty),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: palette.primary,
          foregroundColor: palette.onPrimary,
          minimumSize: LmButtonMetrics.minimumSize,
          padding: LmButtonMetrics.solidPadding,
          shape: pillShape,
          textStyle: LmButtonMetrics.label(LmUiTextStyles.bodySm),
        ).copyWith(elevation: LmButtonMetrics.flatElevationProperty),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: palette.ink,
          side: BorderSide(color: palette.dividerStrong),
          minimumSize: LmButtonMetrics.minimumSize,
          padding: LmButtonMetrics.solidPadding,
          shape: pillShape,
          textStyle: LmButtonMetrics.label(LmUiTextStyles.bodySm),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: palette.primary,
          minimumSize: LmButtonMetrics.minimumSize,
          padding: LmButtonMetrics.textPadding,
          textStyle: LmButtonMetrics.label(LmUiTextStyles.bodySm),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: palette.surfaceVariant,
        border: const OutlineInputBorder(
          borderRadius: WonderComponents.rowRadius,
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: WonderComponents.rowRadius,
          borderSide: BorderSide(color: palette.accent, width: 2),
        ),
        hintStyle: LmUiTextStyles.body.copyWith(color: palette.faint),
      ),
      dialogTheme: DialogThemeData(
        constraints: const BoxConstraints(
          minWidth: 280,
          maxWidth: LmLayout.dialogMaxWidth,
        ),
        backgroundColor: palette.surfaceElevated,
        barrierColor: palette.scrim,
        elevation: 0,
        shape: cardShape,
        titleTextStyle: LmNarrativeTextStyles.narrativeDisplay.copyWith(
          color: palette.ink,
        ),
        contentTextStyle: LmUiTextStyles.body.copyWith(color: palette.muted),
      ),
      drawerTheme: DrawerThemeData(
        backgroundColor: palette.surface,
        scrimColor: palette.scrim,
        elevation: 0,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        constraints: const BoxConstraints(maxWidth: LmLayout.sheetMaxWidth),
        backgroundColor: palette.surfaceElevated,
        elevation: 0,
        shape: cardShape,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: palette.surfaceElevated,
        contentTextStyle: LmUiTextStyles.bodySm.copyWith(color: palette.ink),
        elevation: 0,
        shape: rowShape,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: palette.surfaceVariant,
        selectedColor: palette.primaryDim,
        labelStyle: LmUiTextStyles.caption.copyWith(color: palette.ink),
        side: BorderSide.none,
        shape: pillShape,
      ),
      dividerTheme: DividerThemeData(color: palette.divider, thickness: 1),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: palette.surface,
        indicatorColor: palette.primaryDim,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        height: 64,
      ),
      extensions: [
        LmTokens(
          structureId: id,
          paletteId: '',
          palette: palette,
          material: scheme,
        ),
      ],
    );
  }
}
