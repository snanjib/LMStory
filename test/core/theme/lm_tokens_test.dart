import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/lm_radius.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_structure.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/system/palettes/classic/classic_palette.dart';
import 'package:lmstory/core/theme/system/structures/classic/classic_structure.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';

void main() {
  test(
    'all original Daylight and night-voyage dark slots are unchanged',
    () {
      final expected = <LmPalette, List<int>>{
        ClassicPaletteValues.light: [
          0xfff4f5f7,
          0xffffffff,
          0xffeef0f3,
          0xffe7e9ed,
          0xff22222e,
          0xff5f5f72,
          0xff67677a,
          0xff4338ca,
          0x1f4338ca,
          0xffffffff,
          0xff9e7520,
          0x1f9e7520,
          0xffdde0e5,
          0xff1a8a52,
          0xffa07a20,
          0xffb02e2e,
          0x66161616,
        ],
        // 夜档为原夜航配色原值收编（全局夜间基础）
        ClassicPaletteValues.dark: [
          0xff0e1018,
          0xff141722,
          0xff1b1e2c,
          0xff171a26,
          0xffefede6,
          0xffb9b7ae,
          0xff9b9990,
          0xffd4a042,
          0x1fd4a042,
          0xff14100a,
          0xffb8862e,
          0x1fb8862e,
          0xff2a2d3a,
          0xff4caf6e,
          0xffd4b842,
          0xffc44830,
          0xb30e1018,
        ],
      };
      for (final entry in expected.entries) {
        final p = entry.key;
        expect(
          [
            p.bg,
            p.surface,
            p.surfaceElevated,
            p.surfaceVariant,
            p.ink,
            p.muted,
            p.faint,
            p.primary,
            p.primaryDim,
            p.onPrimary,
            p.accent,
            p.accentDim,
            p.divider,
            p.success,
            p.warning,
            p.error,
            p.scrim,
          ].map((color) => color.toARGB32()),
          entry.value,
        );
        // classic 族 bgGlow 已赋值（琉璃+经典场地渐变不再退化为
        // 平涂）；「缺省回退 bg」仅适用于未赋值的槽位场景（lm_palette 单测）。
        expect(p.bgGlow, isNot(p.bg));
      }
    },
  );

  test(
    'Classic preserves six radii nine spacings and independent reading measure',
    () {
      expect(
        [
          LmRadius.rXs,
          LmRadius.rSm,
          LmRadius.rMd,
          LmRadius.rLg,
          LmRadius.rXl,
          LmRadius.rFull,
        ],
        [
          4,
          8,
          12,
          16,
          20,
          9999,
        ],
      );
      expect(
        [
          LmSpacing.s3xs,
          LmSpacing.s2xs,
          LmSpacing.sXs,
          LmSpacing.sSm,
          LmSpacing.sMd,
          LmSpacing.sLg,
          LmSpacing.sXl,
          LmSpacing.s2xl,
          LmSpacing.s3xl,
        ],
        [
          2,
          4,
          6,
          8,
          12,
          16,
          24,
          32,
          48,
        ],
      );
      expect(LmReadingConstraints.width, 800);
    },
  );

  test(
    'structure assembly consumes the supplied palette at the same brightness',
    () {
      const structure = ClassicStructure();
      final before =
          structure.assemble(ClassicPaletteValues.light, Brightness.dark);
      final after =
          structure.assemble(ClassicPaletteValues.dark, Brightness.dark);
      expect(
        after.scaffoldBackgroundColor,
        ClassicPaletteValues.dark.bg,
      );
      expect(
        after.scaffoldBackgroundColor,
        isNot(before.scaffoldBackgroundColor),
      );
      expect(after.cardTheme.shape, before.cardTheme.shape);
      expect(
        after.inputDecorationTheme.contentPadding,
        before.inputDecorationTheme.contentPadding,
      );
    },
  );

  test(
    'token copy and interpolation preserve all appearance identities',
    () {
      final before = ThemeCatalog.fallbackTokens(Brightness.light);
      final after = ThemeCatalog.fallbackTokens(Brightness.dark)
          .copyWith(structureId: 'other', paletteId: 'other');
      expect(before.copyWith().palette, same(before.palette));
      expect(before.lerp(after, 0).palette.bg, before.palette.bg);
      expect(before.lerp(after, 1).palette.bg, after.palette.bg);
      expect(before.lerp(after, 1).structureId, 'other');
      expect(
        before.lerp(after, 0.5).palette.bg,
        Color.lerp(before.palette.bg, after.palette.bg, 0.5),
      );
      expect(before.lerp(null, 0.5), same(before));
    },
  );

  testWidgets(
    'context without a token host falls back to effective brightness',
    (tester) async {
      late LmTokens tokens;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Builder(
            builder: (context) {
              tokens = context.lm;
              return const SizedBox();
            },
          ),
        ),
      );
      expect(tokens.palette.ink, ClassicPaletteValues.dark.ink);
      expect(tokens.material, ThemeData.dark().colorScheme);
    },
  );
}
