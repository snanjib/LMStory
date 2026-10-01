import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/system/palettes/bordeaux/bordeaux_palette.dart';
import 'package:lmstory/core/theme/system/palettes/classic/classic_palette.dart';
import 'package:lmstory/core/theme/system/structures/brutal/brutal_materials.dart';
import 'package:lmstory/core/theme/system/structures/brutal/brutal_radii.dart';
import 'package:lmstory/core/theme/system/structures/brutal/brutal_structure.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';

/// 棱角包基础行为：装配、目录注册、Token 锚定（《棱角档案》§2 数值表）。
void main() {
  test('Brutal 装配产出带 token 的 ThemeData，scaffold 底=palette.bg', () {
    for (final family in const [
      ClassicPaletteFamily(),
      BordeauxPaletteFamily(),
    ]) {
      for (final brightness in Brightness.values) {
        final palette = family.of(brightness);
        final theme = const BrutalStructure().assemble(palette, brightness);
        expect(theme.scaffoldBackgroundColor, palette.bg);
        expect(theme.extension<LmTokens>()?.structureId, 'brutal');
        expect(theme.extension<LmTokens>()?.palette.bg, palette.bg);
      }
    }
  });

  test('目录注册：ThemeCatalog.structures 含 brutal（i18n 键同拍板）', () {
    final ids = ThemeCatalog.structures.map((e) => e.id).toList();
    expect(ids, contains('brutal'));
    expect(
      ids,
      containsAll(['classic', 'glass']),
      reason: 'classic/glass 注册不得受影响',
    );
    final entry = ThemeCatalog.structures.firstWhere((e) => e.id == 'brutal');
    expect(entry.nameKey, 'appearance.structures.brutal');
  });

  test('几何 Token 锚定：《棱角档案》§2.1/§2.3 数值逐项', () {
    expect(BrutalRadii.frameInline, 2);
    expect(BrutalRadii.frameCard, 3);
    expect(BrutalRadii.frameOverlay, 4);
    expect(BrutalRadii.cornerNone, 0);
    expect(BrutalRadii.cornerField, 5);
    expect(BrutalRadii.pressOffset, const Offset(4, 4));
    expect(BrutalRadii.hoverOffset, const Offset(2, 2));
  });

  test('阴影唯一公式：offset(4,4)·blur0·spread0；pressed 偏移归零', () {
    final palette = const BordeauxPaletteFamily().of(Brightness.dark);
    final rest = BrutalMaterials.shadow(palette);
    expect(rest, hasLength(1));
    expect(rest.first.color, palette.dividerStrong, reason: '夜间阴影使用柔和结构色');
    expect(rest.first.offset, const Offset(4, 4));
    expect(rest.first.blurRadius, 0, reason: '禁 blur：阴影是几何色块');
    expect(rest.first.spreadRadius, 0);

    final pressed = BrutalMaterials.shadow(palette, pressed: true);
    expect(pressed.first.offset, Offset.zero, reason: '按压=阴影偏移归零（按进纸里）');
    expect(pressed.first.blurRadius, 0);
    expect(pressed.first.spreadRadius, 0);
  });

  test('结构墨色：日间取 ink，夜间取 dividerStrong', () {
    for (final family in const [
      ClassicPaletteFamily(),
      BordeauxPaletteFamily(),
    ]) {
      final light = family.of(Brightness.light);
      final dark = family.of(Brightness.dark);
      expect(BrutalMaterials.frameOf(light), light.ink);
      expect(BrutalMaterials.frameOf(dark), dark.dividerStrong);
      expect(
        light.ink.computeLuminance() < dark.ink.computeLuminance(),
        isTrue,
        reason: '${family.id} 族 ink 应日近黑/夜近白',
      );
    }
  });

  test('装配面描边档位：卡片 3 / 浮层 4 / 行内 2', () {
    final palette = const BordeauxPaletteFamily().of(Brightness.dark);
    final theme = const BrutalStructure().assemble(palette, Brightness.dark);

    ShapeBorder shapeOf(ShapeBorder? shape) => shape!;

    final cardSide =
        (shapeOf(theme.cardTheme.shape) as RoundedRectangleBorder).side;
    expect(cardSide.width, BrutalRadii.frameCard);
    expect(cardSide.color, palette.dividerStrong);

    final dialogSide =
        (shapeOf(theme.dialogTheme.shape) as RoundedRectangleBorder).side;
    expect(dialogSide.width, BrutalRadii.frameOverlay);
    expect(dialogSide.color, palette.dividerStrong);

    final drawerSide =
        (shapeOf(theme.drawerTheme.shape) as RoundedRectangleBorder).side;
    expect(drawerSide.width, BrutalRadii.frameOverlay);

    final sheetSide =
        (shapeOf(theme.bottomSheetTheme.shape) as RoundedRectangleBorder).side;
    expect(sheetSide.width, BrutalRadii.frameOverlay);

    final snackBarSide =
        (shapeOf(theme.snackBarTheme.shape) as RoundedRectangleBorder).side;
    expect(snackBarSide.width, BrutalRadii.frameInline);

    // ChipThemeData 的 side 是独立属性（shape 不携带描边， 惯例）。
    final chipSide = theme.chipTheme.side!;
    expect(chipSide.width, BrutalRadii.frameInline);
    expect(chipSide.color, palette.dividerStrong);

    final buttonSide = (theme.filledButtonTheme.style!.shape!.resolve({})!
            as RoundedRectangleBorder)
        .side;
    expect(buttonSide.width, BrutalRadii.frameInline);
    expect(buttonSide.color, palette.dividerStrong);
  });

  test('浮层零投影：dialog/drawer/bottomSheet/snackBar elevation 恒 0', () {
    final palette = const ClassicPaletteFamily().of(Brightness.dark);
    final theme = const BrutalStructure().assemble(palette, Brightness.dark);
    expect(theme.dialogTheme.elevation, 0, reason: '浮层走描边不走投影');
    expect(theme.bottomSheetTheme.elevation, 0);
    expect(theme.snackBarTheme.elevation, 0);
    expect(
      theme.dialogTheme.barrierColor,
      palette.scrim,
      reason: '遮罩用配色 scrim',
    );
  });
}
