import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/palettes/bordeaux/bordeaux_palette.dart';
import 'package:lmstory/core/theme/system/palettes/classic/classic_palette.dart';
import 'package:lmstory/core/theme/system/structures/glass/glass_factories.dart';
import 'package:lmstory/core/theme/system/structures/glass/glass_surface.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';

///  守卫：classic 配色族 bgGlow（场地渐变端点）。
///
/// 背景：`LmPalette.bgGlow` 缺省回退 = bg，「琉璃 + 经典配色」的场地
/// 渐变退化成平涂，琉璃的结构签名在该组合下整个消失（已补值）。
/// 判定口径：「场地可辨，但不抢内容、不改变该族克制中性的性格」。
/// 守卫锁死：
/// 1. classic 两档 bgGlow 已赋值（≠ bg），锚值精确；
/// 2. 克制带：glow 对 bg 的分离度 ∈ [1.10, 1.45]（可辨下限 / 抢戏上限；
///    波尔多夜 ≫ 上限是设计内的戏剧性，不受此带约束）；
/// 3. 内容可读性：ink 对 bgGlow ≥ 4.5:1（场地角部仍有正文）；
/// 4. 唯一消费点闭环：GlassBackdrop 渐变端点 = [bgGlow, bg]；
///    classic 结构不消费场地（classic+classic 零视觉变化的代码面前提，
///    golden 面由 appearance_visual_parity_test 锁死）。
void main() {
  test('classic 两档 bgGlow 已赋值且锚值精确', () {
    expect(
      ClassicPaletteValues.light.bgGlow,
      const Color(0xFFDDE3EE),
      reason: '日间场地端点：本族冷灰自身色相低彩度加深',
    );
    expect(
      ClassicPaletteValues.dark.bgGlow,
      const Color(0xFF202A40),
      reason: '夜间场地端点：夜航深蓝黑抬升一档',
    );
    expect(
      ClassicPaletteValues.light.bgGlow,
      isNot(ClassicPaletteValues.light.bg),
    );
    expect(
      ClassicPaletteValues.dark.bgGlow,
      isNot(ClassicPaletteValues.dark.bg),
    );
  });

  test('克制带：glow 对 bg 分离度 ∈ [1.10, 1.45]，波尔多夜不受此带约束', () {
    const cases = <(String, Color, Color)>[
      (
        'classic light',
        ClassicPaletteValues.lightBgGlow,
        ClassicPaletteValues.lightBg
      ),
      (
        'classic dark',
        ClassicPaletteValues.darkBgGlow,
        ClassicPaletteValues.darkBg
      ),
    ];
    for (final (name, glow, bg) in cases) {
      final ratio = contrastRatio(glow, bg);
      expect(ratio, greaterThanOrEqualTo(1.10), reason: '$name 场地不可辨');
      expect(ratio, lessThanOrEqualTo(1.45), reason: '$name 场地抢戏');
    }
    // 波尔多两档为设计内既有值，仅锚定不回归（夜场戏剧性远超 classic 带）。
    expect(
      BordeauxPaletteValues.bgGlow,
      const Color(0xFF5C1F38),
    );
    expect(BordeauxPaletteValues.dayBgGlow, const Color(0xFFE9D9DE));
  });

  test('内容可读性：ink 对 bgGlow ≥ 4.5:1', () {
    expect(
      contrastRatio(
        ClassicPaletteValues.lightInk,
        ClassicPaletteValues.lightBgGlow,
      ),
      greaterThanOrEqualTo(4.5),
      reason: '日间场地角部正文',
    );
    expect(
      contrastRatio(
        ClassicPaletteValues.darkInk,
        ClassicPaletteValues.darkBgGlow,
      ),
      greaterThanOrEqualTo(4.5),
      reason: '夜间场地角部正文',
    );
  });

  testWidgets('GlassBackdrop 渐变端点 = [bgGlow, bg]（classic 配色）', (tester) async {
    for (final brightness in Brightness.values) {
      final palette = ClassicPaletteValues.of(brightness);
      await tester.pumpWidget(
        KeyedSubtree(
          key: ValueKey('venue-${brightness.name}'),
          child: MaterialApp(
            theme: ThemeCatalog.assemble(
              const LmAppearance(structureId: 'glass'),
              brightness,
            ),
            home: const _VenueHost(),
          ),
        ),
      );
      final backdrop = tester.widget<DecoratedBox>(
        find
            .descendant(
              of: find.byType(GlassBackdrop),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      final gradient =
          (backdrop.decoration as BoxDecoration).gradient! as LinearGradient;
      expect(gradient.colors, [palette.bgGlow, palette.bg]);
    }
  });

  test('classic 结构不消费场地（classic+classic 零变化的代码面前提）', () {
    for (final brightness in Brightness.values) {
      final theme = ThemeCatalog.assemble(const LmAppearance(), brightness);
      expect(
        theme.scaffoldBackgroundColor,
        ClassicPaletteValues.of(brightness).bg,
        reason: 'classic 脚手架底恒为 bg 平涂',
      );
    }
  });
}

class _VenueHost extends StatelessWidget {
  const _VenueHost();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: context.glassVenue(const SizedBox.expand()),
    );
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
