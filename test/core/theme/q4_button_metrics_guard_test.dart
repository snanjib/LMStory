import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/lm_button_metrics.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';

///  守卫：四组合 × 明暗 = 8 例，锁定按钮共享度量。
///
/// 红线：
/// - 四类按钮（filled/elevated/outlined/text）最小高度 ≥44（触控 a11y）；
/// - 实体按钮 padding 一致（solidPadding）、文字按钮 textPadding；
/// - primary/onPrimary 文字对比度 ≥4.5:1（按钮标签正文级）。
void main() {
  const combos = <(String, String)>[
    ('classic', 'classic'),
    ('classic', 'bordeaux'),
    ('glass', 'classic'),
    ('glass', 'bordeaux'),
  ];

  for (final (structureId, paletteId) in combos) {
    for (final brightness in Brightness.values) {
      testWidgets('$structureId+$paletteId $brightness：按钮度量', (
        tester,
      ) async {
        final theme = ThemeCatalog.assemble(
          LmAppearance(structureId: structureId, paletteId: paletteId),
          brightness,
        );
        final colorScheme = theme.colorScheme;

        final styles = <String, ButtonStyle?>{
          'filled': theme.filledButtonTheme.style,
          'elevated': theme.elevatedButtonTheme.style,
          'outlined': theme.outlinedButtonTheme.style,
          'text': theme.textButtonTheme.style,
        };
        expect(
          styles['filled'],
          isNotNull,
          reason: 'Classic 曾缺 filledButtonTheme（31 处调用点走 M3 默认）',
        );

        final solidPadding = <String, EdgeInsetsGeometry?>{};
        styles.forEach((name, style) {
          // 触控目标：四类按钮全部 ≥44。
          final minSize = style!.minimumSize?.resolve(const <WidgetState>{});
          expect(
            minSize!.height,
            greaterThanOrEqualTo(44.0),
            reason: '$name minimumSize.height',
          );

          // 内边距：实体按钮同源 solidPadding，文字按钮 textPadding。
          final padding = style.padding?.resolve(const <WidgetState>{});
          if (name == 'text') {
            expect(padding, LmButtonMetrics.textPadding, reason: name);
          } else {
            expect(padding, LmButtonMetrics.solidPadding, reason: name);
            solidPadding[name] = padding;
          }

          // 标签字重：全外观统一 w500。
          final label = style.textStyle?.resolve(const <WidgetState>{});
          expect(label!.fontWeight, FontWeight.w500, reason: '$name textStyle');
        });
        expect(
          solidPadding.values.toSet().length,
          1,
          reason: '实体按钮 padding 必须一致',
        );

        // primary/onPrimary 对比度 ≥4.5（按钮标签正文级文字）。
        final fg =
            styles['filled']!.foregroundColor!.resolve(const <WidgetState>{})!;
        final bg =
            styles['filled']!.backgroundColor!.resolve(const <WidgetState>{})!;
        expect(
          _contrastRatio(fg, bg),
          greaterThanOrEqualTo(4.5),
          reason: '$structureId+$paletteId $brightness onPrimary/primary',
        );
        // 兜底：色cheme两端也在位（防主题错接）。
        expect(colorScheme.primary, bg);
      });
    }
  }
}

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
