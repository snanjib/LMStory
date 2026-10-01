import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/system/lm_structure.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/system/palettes/bordeaux/bordeaux_palette.dart';
import 'package:lmstory/core/theme/system/palettes/classic/classic_palette.dart';
import 'package:lmstory/core/theme/system/structures/brutal/brutal_structure.dart';
import 'package:lmstory/core/theme/system/structures/classic/classic_structure.dart';
import 'package:lmstory/core/theme/system/structures/glass/glass_structure.dart';
import 'package:lmstory/core/theme/system/structures/wonder/wonder_structure.dart';

class LmCatalogEntry<T> {
  const LmCatalogEntry({
    required this.id,
    required this.nameKey,
    required this.create,
  });
  final String id;
  final String nameKey;
  final T Function() create;
}

@immutable
class LmAppearance {
  const LmAppearance({
    this.structureId = 'classic',
    this.paletteId = 'classic',
  });
  final String structureId;
  final String paletteId;
  LmAppearance copyWith({String? structureId, String? paletteId}) =>
      LmAppearance(
        structureId: structureId ?? this.structureId,
        paletteId: paletteId ?? this.paletteId,
      );
  @override
  bool operator ==(Object other) =>
      other is LmAppearance &&
      structureId == other.structureId &&
      paletteId == other.paletteId;
  @override
  int get hashCode => Object.hash(structureId, paletteId);
}

/// The sole package registration point.
abstract final class ThemeCatalog {
  static const defaults = LmAppearance();
  static const structures = [
    LmCatalogEntry<LmStructure>(
      id: 'classic',
      nameKey: 'appearance.structures.classic',
      create: ClassicStructure.new,
    ),
    LmCatalogEntry<LmStructure>(
      id: 'glass',
      nameKey: 'appearance.structures.glass',
      create: GlassStructure.new,
    ),
    LmCatalogEntry<LmStructure>(
      id: 'brutal',
      nameKey: 'appearance.structures.brutal',
      create: BrutalStructure.new,
    ),
    LmCatalogEntry<LmStructure>(
      id: 'wonder',
      nameKey: 'appearance.structures.wonder',
      create: WonderStructure.new,
    ),
  ];
  static const palettes = [
    LmCatalogEntry<LmPaletteFamily>(
      id: 'classic',
      nameKey: 'appearance.palettes.classic',
      create: ClassicPaletteFamily.new,
    ),
    LmCatalogEntry<LmPaletteFamily>(
      id: 'bordeaux',
      nameKey: 'appearance.palettes.bordeaux',
      create: BordeauxPaletteFamily.new,
    ),
  ];

  static LmAppearance resolve(LmAppearance requested) =>
      structures.any((entry) => entry.id == requested.structureId) &&
              palettes.any((entry) => entry.id == requested.paletteId)
          ? requested
          : defaults;

  static ThemeData assemble(LmAppearance requested, Brightness brightness) {
    final appearance = resolve(requested);
    final structure =
        structures.firstWhere((e) => e.id == appearance.structureId).create();
    final family =
        palettes.firstWhere((e) => e.id == appearance.paletteId).create();
    final palette = family.of(brightness);
    final theme = structure.assemble(palette, brightness);
    return theme.copyWith(
      extensions: [
        ...theme.extensions.values,
        LmComponents(structure.buildComponents()),
        LmTokens(
          structureId: appearance.structureId,
          paletteId: appearance.paletteId,
          palette: palette,
          material: theme.colorScheme,
        ),
      ],
    );
  }

  static final _light = assemble(defaults, Brightness.light);
  static final _dark = assemble(defaults, Brightness.dark);
  static LmTokens fallbackTokens(Brightness brightness) =>
      (brightness == Brightness.light ? _light : _dark).extension<LmTokens>()!;
}
