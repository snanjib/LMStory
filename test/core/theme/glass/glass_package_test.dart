import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/system/palettes/bordeaux/bordeaux_palette.dart';
import 'package:lmstory/core/theme/system/structures/glass/glass_factories.dart';
import 'package:lmstory/core/theme/system/structures/glass/glass_structure.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart' show LmAppearance;
import 'package:lmstory/core/theme/system/theme_catalog.dart' show ThemeCatalog;

/// 琉璃包基础行为：装配、场地渐变（bgGlow 唯一消费点）、阅读卡不透明。
void main() {
  test('Glass 装配产出带 token 的 ThemeData，scaffold 底=palette.bg', () {
    for (final brightness in Brightness.values) {
      final palette = const BordeauxPaletteFamily().of(brightness);
      final theme = const GlassStructure().assemble(palette, brightness);
      expect(theme.scaffoldBackgroundColor, palette.bg);
      expect(theme.extension<LmTokens>()?.palette.bg, palette.bg);
    }
  });

  test('波尔多日夜两档槽值锚定（设计文档 §2.2/§3.1 定稿值）', () {
    const night = BordeauxPaletteValues.night;
    expect(night.bg, const Color(0xFF150C13));
    expect(night.bgGlow, const Color(0xFF5C1F38));
    expect(night.primary, const Color(0xFFE8DCE4));
    expect(night.primaryDim, const Color(0x1AE8DCE4));
    expect(night.onPrimary, const Color(0xFF231019));
    expect(night.accent, const Color(0xFFFF4F6E));
    expect(night.divider, const Color(0xFF3A2438));

    const day = BordeauxPaletteValues.day;
    expect(day.bg, const Color(0xFFF5F2F3));
    expect(day.bgGlow, const Color(0xFFE9D9DE));
    expect(day.primary, const Color(0xFF8C2440));
    expect(day.onPrimary, const Color(0xFFFFF5F8));
    expect(day.accent, const Color(0xFFB3325A));
    expect(day.divider, const Color(0xFFE5D8DC));
  });

  testWidgets('GlassBackdrop 绘制 bgGlow→bg 渐变（无 blur 无 ImageFilter）',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeCatalog.assemble(
          const LmAppearance(
            structureId: 'glass',
            paletteId: 'bordeaux',
          ),
          Brightness.dark,
        ),
        home: const GlassBackdrop(child: SizedBox.expand()),
      ),
    );
    final decorated =
        tester.widgetList<DecoratedBox>(find.byType(DecoratedBox));
    final gradients = decorated
        .map((d) => d.decoration)
        .whereType<BoxDecoration>()
        .expand((d) => [d.gradient])
        .whereType<LinearGradient>()
        .toList();
    expect(gradients, isNotEmpty);
    expect(gradients.first.colors.first, BordeauxPaletteValues.night.bgGlow);
    expect(gradients.first.colors.last, BordeauxPaletteValues.night.bg);
  });

  testWidgets('阅读卡=surface 不透明（零 blur 零 glow，流式宿主红线）', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeCatalog.assemble(
          const LmAppearance(
            structureId: 'glass',
            paletteId: 'bordeaux',
          ),
          Brightness.dark,
        ),
        home: const Scaffold(
          body: GlassReadingCard(child: Text('阅读正文')),
        ),
      ),
    );
    final card = tester.widget<DecoratedBox>(
      find.descendant(
        of: find.byType(GlassReadingCard),
        matching: find.byType(DecoratedBox),
      ),
    );
    final decoration = card.decoration as BoxDecoration;
    expect(decoration.color, BordeauxPaletteValues.night.surface);
    expect(decoration.color!.a, 1.0, reason: '阅读卡必须完全不透明');
    expect(find.byType(BackdropFilter), findsNothing);
  });
}

// 静态源扫描的仓库根定位（守卫测试复用）。
final Directory repoRoot = () {
  var dir = Directory.current;
  while (!Directory('${dir.path}${Platform.pathSeparator}pubspec.yaml')
      .existsSync()) {
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError('pubspec.yaml not found upward');
    }
    dir = parent;
  }
  return dir;
}();
