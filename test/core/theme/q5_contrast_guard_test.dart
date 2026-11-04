import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/lm_palette.dart';
import 'package:lmstory/core/theme/system/palettes/bordeaux/bordeaux_palette.dart';
import 'package:lmstory/core/theme/system/palettes/classic/classic_palette.dart';
import 'package:lmstory/core/theme/system/structures/glass/glass_materials.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';

///  守卫：对比度与语义色合规。
///
/// 1. chip 标签对比度：未选中（labelStyle on backgroundColor）与选中
///    （secondaryLabelStyle on selectedColor）全部 ≥4.5:1——四组合 × 明暗。
/// 2. 结构分隔线 dividerStrong 对 bg ≥3:1（侧栏 1.36:1 不可见的修复）。
/// 3. 全量文字/背景矩阵扫描：把 ink/muted/faint/primary 对主要面色的对比度
///    打成表格输出（证据存进度日志附录），扫描本身不设阈值断言。
void main() {
  const families = <String, LmPaletteFamily>{
    'classic': ClassicPaletteFamily(),
    'bordeaux': BordeauxPaletteFamily(),
  };

  double ratio(Color a, Color b) {
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

  for (final entry in families.entries) {
    for (final brightness in Brightness.values) {
      testWidgets('${entry.key} $brightness：chip 标签对比度 ≥4.5', (
        tester,
      ) async {
        final theme = ThemeCatalog.assemble(
          LmAppearance(structureId: 'glass', paletteId: entry.key),
          brightness,
        );
        final palette = entry.value.of(brightness);
        final chip = theme.chipTheme;

        final fgUnselected = chip.labelStyle!.color!;
        final fgSelected =
            (chip.secondaryLabelStyle ?? chip.labelStyle)!.color!;
        final bgUnselected = Color.alphaBlend(
          chip.backgroundColor!,
          palette.bg,
        );
        final bgSelected = Color.alphaBlend(chip.selectedColor!, palette.bg);

        expect(
          ratio(fgUnselected, bgUnselected),
          greaterThanOrEqualTo(4.5),
          reason: '${entry.key} $brightness 未选中 chip',
        );
        expect(
          ratio(fgSelected, bgSelected),
          greaterThanOrEqualTo(4.5),
          reason: '${entry.key} $brightness 选中 chip',
        );
      });

      testWidgets('${entry.key} $brightness：dividerStrong 对 bg ≥3:1', (
        tester,
      ) async {
        final palette = entry.value.of(brightness);
        expect(
          ratio(palette.dividerStrong, palette.bg),
          greaterThanOrEqualTo(3.0),
          reason: '${entry.key} $brightness dividerStrong/bg',
        );
      });
    }
  }

  test('全量文字/背景对比度矩阵（扫描输出，不设阈值）', () {
    final buffer = StringBuffer()
      ..writeln('| 配色档 | 前景 | 背景 | 对比度 |')
      ..writeln('|---|---|---|---|');
    for (final entry in families.entries) {
      for (final brightness in Brightness.values) {
        final p = entry.value.of(brightness);
        final tag = '${entry.key}${brightness == Brightness.light ? '日' : '夜'}';
        final surfaces = <String, Color>{
          'bg': p.bg,
          'surface': p.surface,
          'surfaceElevated': p.surfaceElevated,
          'surfaceVariant': p.surfaceVariant,
        };
        final inks = <String, Color>{
          'ink': p.ink,
          'muted': p.muted,
          'faint': p.faint,
          'primary': p.primary,
        };
        for (final inkEntry in inks.entries) {
          for (final surfaceEntry in surfaces.entries) {
            buffer.writeln(
              '| $tag | ${inkEntry.key} | ${surfaceEntry.key} | '
              '${ratio(inkEntry.value, surfaceEntry.value).toStringAsFixed(2)} |',
            );
          }
        }
        // 玻璃填充底（叠加 bg 后）上的 ink/muted。
        for (final fill in <String, Color>{
          'fill6': GlassMaterials.fill6(p.bg),
          'fill16': GlassMaterials.fill16(p.bg),
          'fill22': GlassMaterials.fill22(p.bg),
        }.entries) {
          final blended = Color.alphaBlend(fill.value, p.bg);
          buffer
            ..writeln('| $tag | ink | ${fill.key}@bg | '
                '${ratio(p.ink, blended).toStringAsFixed(2)} |')
            ..writeln('| $tag | muted | ${fill.key}@bg | '
                '${ratio(p.muted, blended).toStringAsFixed(2)} |');
        }
      }
    }
    // ignore: avoid_print
    print(buffer);
    expect(buffer, isNotNull);
  });
}
