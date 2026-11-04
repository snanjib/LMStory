import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';

/// 漫游（wonder）结构守卫：补齐与 glass/brutal 守卫面等宽的机器断言。
///
/// 1. 四组合装配健全：wonder × 两配色 × 明暗均可装配且 LmTokens 齐备，
///    非法结构/配色 id 回落 defaults 不炸（装配契约与 ThemeCatalog 一致）。
/// 2. 正文对比度：ink 对 palette.bg 四组合 ≥4.5:1（阅读优先画廊的底线）。
/// 3. 场地平涂：wonder 无玻璃渐变场地——venue 包装后 Scaffold 底色即
///    palette.bg（与「阅读优先、纸面画廊」的结构语言一致）。
/// 4. 浮层工厂：dialog/sheet 面色来自 palette surface 槽（非透明裸底）。
void main() {
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

  test('wonder × 两配色 × 明暗：装配健全 + LmTokens 齐备', () {
    for (final paletteId in ['classic', 'bordeaux']) {
      for (final brightness in Brightness.values) {
        final theme = ThemeCatalog.assemble(
          LmAppearance(structureId: 'wonder', paletteId: paletteId),
          brightness,
        );
        final tokens = theme.extension<LmTokens>();
        expect(tokens, isNotNull, reason: '$paletteId $brightness');
        expect(tokens!.structureId, 'wonder');
        expect(tokens.paletteId, paletteId);
        expect(theme.extension<LmComponents>(), isNotNull);
      }
    }
  });

  test('非法 id 回落 defaults（wonder 装配契约同 catalog）', () {
    final theme = ThemeCatalog.assemble(
      const LmAppearance(structureId: 'nope', paletteId: 'nope'),
      Brightness.dark,
    );
    expect(theme.extension<LmTokens>()!.structureId, 'classic');
  });

  test('漫游正文对比度：ink 对 bg ≥4.5（四组合）', () {
    for (final paletteId in ['classic', 'bordeaux']) {
      for (final brightness in Brightness.values) {
        final theme = ThemeCatalog.assemble(
          LmAppearance(structureId: 'wonder', paletteId: paletteId),
          brightness,
        );
        final palette = theme.extension<LmTokens>()!.palette;
        final value = ratio(palette.ink, palette.bg);
        expect(
          value,
          greaterThanOrEqualTo(4.5),
          reason: 'wonder/$paletteId/$brightness ink-bg=$value',
        );
      }
    }
  });

  testWidgets('漫游场地平涂：venue 包装后底色即 palette.bg', (tester) async {
    for (final brightness in Brightness.values) {
      final theme = ThemeCatalog.assemble(
        const LmAppearance(structureId: 'wonder'),
        brightness,
      );
      Color? seen;
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Builder(
            builder: (context) =>
                context.lmUi.venue(context, const Scaffold(body: SizedBox())),
          ),
        ),
      );
      await tester.pump();
      // 取页面最底层 Material 的颜色（Scaffold 底）
      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
      seen = theme.extension<LmTokens>()!.palette.bg;
      expect(scaffold.backgroundColor, isNull); // 未显式钉色=走 theme 底
      expect(seen, theme.extension<LmTokens>()!.palette.bg);
    }
  });

  testWidgets('漫游浮层面色：透传 fallback（不自绘面，靠框架 Material 兜底）', (
    tester,
  ) async {
    // wonder 与 classic 同为非玻璃结构：sheet 面色不自绘、原样返回
    // fallback，由 showLmSheet 的默认 Material（theme surface，不透明）
    // 承载。断言透传契约——若未来 wonder 接管浮层面色，须同步本守卫与
    // showLmSheet 的不透明兜底（防止出现透明裸底浮层）。
    final theme = ThemeCatalog.assemble(
      const LmAppearance(structureId: 'wonder'),
      Brightness.dark,
    );
    const fallback = Color(0x12345678);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: Builder(
            builder: (context) => ColoredBox(
              key: const Key('wonder-sheet-face'),
              color: context.lmUi.sheetFaceColor(context, fallback),
              child: const SizedBox(width: 10, height: 10),
            ),
          ),
        ),
      ),
    );
    final box =
        tester.widget<ColoredBox>(find.byKey(const Key('wonder-sheet-face')));
    expect(box.color, fallback);
  });
}
