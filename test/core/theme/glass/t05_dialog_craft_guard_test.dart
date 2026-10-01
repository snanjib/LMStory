import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/lm_palette.dart';
import 'package:lmstory/core/theme/system/palettes/bordeaux/bordeaux_palette.dart';
import 'package:lmstory/core/theme/system/palettes/classic/classic_palette.dart';
import 'package:lmstory/core/theme/system/structures/glass/glass_materials.dart';
import 'package:lmstory/core/theme/system/structures/glass/glass_radii.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';

///  守卫：玻璃 dialog 面工艺对齐  档 + 图底分离不降。
///
/// 维持 dialog 走  台阶（GlassModal 不接线）。工艺微调：
/// 1. 阴影显式化（elevation + shadowColor 来自材质常量，替代  默认）；
/// 2. 圆角与模态/弹层同档（GlassRadii.card）；顶部内高光描边在位；
/// 3. 分离度不降：面板（modalSurface）对 scrim 后场地的亮度阶差保持
///     口径（>1.5:1，波尔多夜实测 2.22:1）—— backgroundColor /
///    barrierColor 未随工艺微调变动，由锚值相等锁死。
void main() {
  final combos = <(String, Brightness)>[
    ('classic', Brightness.light),
    ('classic', Brightness.dark),
    ('bordeaux', Brightness.light),
    ('bordeaux', Brightness.dark),
  ];

  LmPalette paletteOf(String familyId, Brightness brightness) =>
      (familyId == 'classic'
              ? const ClassicPaletteFamily()
              : const BordeauxPaletteFamily())
          .of(brightness);

  for (final (familyId, brightness) in combos) {
    test('$familyId ${brightness.name}：dialog 工艺对齐 T2 档', () {
      final palette = paletteOf(familyId, brightness);
      final theme = ThemeCatalog.assemble(
        LmAppearance(structureId: 'glass', paletteId: familyId),
        brightness,
      );
      final dialog = theme.dialogTheme;

      // 台阶锚值不回归（分离度的唯一来源）。
      expect(
        dialog.backgroundColor,
        GlassMaterials.modalSurface(brightness, palette.surfaceElevated),
      );
      expect(dialog.barrierColor, palette.scrim.withValues(alpha: 0.5));

      // 圆角与高光边。
      final shape = dialog.shape! as RoundedRectangleBorder;
      expect(shape.borderRadius, BorderRadius.circular(GlassRadii.card));
      expect(shape.side.color, GlassMaterials.topInnerHighlight);

      //  阴影显式化。
      expect(dialog.elevation, GlassMaterials.t2Elevation);
      expect(dialog.shadowColor, GlassMaterials.t2ShadowColor);

      // 分离度：同  口径逐组合实测（波尔多夜 ≈2.22:1）。
      final scrimmed = Color.alphaBlend(
        palette.scrim.withValues(alpha: 0.5),
        palette.bg,
      );
      final ratio = contrastRatio(dialog.backgroundColor!, scrimmed);
      expect(ratio, greaterThan(1.5), reason: '$familyId ${brightness.name}');
    });
  }
}

double contrastRatio(Color a, Color b) {
  double luminance(Color c) {
    double channel(double v) => v <= 0.04045
        ? v / 12.92
        : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
    return 0.2126 * channel(c.r) +
        0.7152 * channel(c.g) +
        0.0722 * channel(c.b);
  }

  final la = luminance(a);
  final lb = luminance(b);
  final lighter = la > lb ? la : lb;
  final darker = la > lb ? lb : la;
  return (lighter + 0.05) / (darker + 0.05);
}
