import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/lm_palette.dart';
import 'package:lmstory/core/theme/system/palettes/bordeaux/bordeaux_palette.dart';
import 'package:lmstory/core/theme/system/palettes/classic/classic_palette.dart';
import 'package:lmstory/core/theme/system/structures/glass/glass_materials.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';

///  守卫：玻璃模态任务面的图底分离（发现 D）。
///
/// 玻璃弹窗面板原为 surfaceElevated 原值，与酒色 scrim 压暗后的场地
/// 明度几乎无差（波尔多夜间 1.14:1，轮廓不可辨）。守卫锁死：
/// 1. 玻璃 dialog 面板 = surfaceElevated + fill22 台阶（任务面）；
/// 2. 弹窗遮罩用配色 scrim（保留场地色性），非默认黑54；
/// 3. classic 结构不受影响（golden 基线不动）。
void main() {
  const families = <String, LmPaletteFamily>{
    'classic': ClassicPaletteFamily(),
    'bordeaux': BordeauxPaletteFamily(),
  };

  test('modalSurface 台阶 = surfaceElevated + T2 恒提亮档组合', () {
    for (final brightness in Brightness.values) {
      final base = families['bordeaux']!.of(brightness).surfaceElevated;
      expect(
        GlassMaterials.modalSurface(brightness, base),
        Color.alphaBlend(
          brightness == Brightness.light
              ? GlassMaterials.t2LiftLight
              : GlassMaterials.t2LiftDark,
          base,
        ),
      );
    }
  });

  for (final entry in families.entries) {
    for (final brightness in Brightness.values) {
      testWidgets('${entry.key} $brightness：玻璃 dialog 台阶 + scrim 遮罩', (
        tester,
      ) async {
        final theme = ThemeCatalog.assemble(
          LmAppearance(structureId: 'glass', paletteId: entry.key),
          brightness,
        );
        final dialog = theme.dialogTheme;
        final palette = entry.value.of(brightness);

        // 台阶：面板 = surfaceElevated +  恒提亮档，不等于原值。
        expect(
          dialog.backgroundColor,
          GlassMaterials.modalSurface(brightness, palette.surfaceElevated),
        );
        expect(dialog.backgroundColor, isNot(palette.surfaceElevated));

        // 图底分离：面板对 scrim 后场地的亮度阶差 >= 1.5:1（修复前 1.14:1）。
        final scrimmed = Color.alphaBlend(
          palette.scrim.withValues(alpha: 0.5),
          palette.bg,
        );
        final ratio = _contrastRatio(dialog.backgroundColor!, scrimmed);
        expect(ratio, greaterThan(1.5), reason: '${entry.key} $brightness');

        // 遮罩走配色 scrim。
        expect(dialog.barrierColor, palette.scrim.withValues(alpha: 0.5));
      });
    }
  }

  test('classic dialog 不消费玻璃台阶（golden 基线不动）', () {
    for (final brightness in Brightness.values) {
      final classic = const ClassicPaletteFamily().of(brightness);
      final theme = ThemeCatalog.assemble(const LmAppearance(), brightness);
      expect(
        theme.dialogTheme.backgroundColor,
        isNot(GlassMaterials.modalSurface(brightness, classic.surfaceElevated)),
      );
    }
  });
}

/// WCAG 相对亮度对比度（用于面与面的分离度，非文字合规口径）。
double _contrastRatio(Color a, Color b) {
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
