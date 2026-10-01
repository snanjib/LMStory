import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/lm_palette.dart';
import 'package:lmstory/core/theme/system/palettes/bordeaux/bordeaux_palette.dart';
import 'package:lmstory/core/theme/system/palettes/classic/classic_palette.dart';
import 'package:lmstory/core/theme/system/structures/glass/glass_factories.dart';
import 'package:lmstory/core/theme/system/structures/glass/glass_materials.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';

///  守卫：辉光配色按配色族 accent 运行时派生（跨轴泄漏收口）。
///
/// 历史缺陷：`focusGlowColor` / `brandGlowColor` 写死波尔多 accent
/// （`0x4DFF4F6E` / `0x59FF4F6E`），导致「琉璃 + 经典配色」下聚焦环
/// 辉光是粉红，与本族琥珀 accent（日 `#9E7520` / 夜 `#B8862E`）冲突，
/// 且违反「颜色只能来自配色槽」红线。守卫锁死：
/// 1. 辉光 == 同族 accent 同 alpha（焦点 30% / 品牌 35%）——四档全量；
/// 2. 消费点实取运行时值（聚焦玻璃件的实际投影色随配色族走）；
/// 3. 字面量禁绝由 `glass_redline_guard_test` ③ 承担（本文件不重复）。
void main() {
  final combos = <(String, String, Brightness)>[
    ('classic', 'light', Brightness.light),
    ('classic', 'dark', Brightness.dark),
    ('bordeaux', 'light', Brightness.light),
    ('bordeaux', 'dark', Brightness.dark),
  ];

  LmPalette paletteOf(String familyId, Brightness brightness) =>
      (familyId == 'classic'
              ? const ClassicPaletteFamily()
              : const BordeauxPaletteFamily())
          .of(brightness);

  ThemeData themeOf(String familyId, Brightness brightness) =>
      ThemeCatalog.assemble(
        LmAppearance(structureId: 'glass', paletteId: familyId),
        brightness,
      );

  test('辉光 == 同族 accent 同 alpha（焦点 30% / 品牌 35%）', () {
    for (final (familyId, brightnessName, brightness) in combos) {
      final accent = paletteOf(familyId, brightness).accent;
      expect(
        GlassMaterials.focusGlow(accent),
        accent.withValues(alpha: 0x4D / 255),
        reason: '$familyId $brightnessName 焦点辉光必须 = accent@30%',
      );
      expect(
        GlassMaterials.brandGlow(accent),
        accent.withValues(alpha: 0x59 / 255),
        reason: '$familyId $brightnessName 品牌辉光必须 = accent@35%',
      );
    }
  });

  test('经典配色的辉光不再携带波尔多色相（跨轴泄漏本体）', () {
    for (final brightness in Brightness.values) {
      final classicAccent = const ClassicPaletteFamily().of(brightness).accent;
      final bordeauxAccent =
          const BordeauxPaletteFamily().of(brightness).accent;
      expect(classicAccent, isNot(bordeauxAccent));
      expect(
        GlassMaterials.focusGlow(classicAccent),
        isNot(GlassMaterials.focusGlow(bordeauxAccent)),
        reason: 'classic ${brightness.name} 辉光仍与波尔多同色（泄漏未收）',
      );
    }
  });

  testWidgets('聚焦玻璃件实取运行时辉光（GlassPillButton / GlassInput）', (
    tester,
  ) async {
    //  起玻璃件焦点环走 focus-visible 语义（鼠标点击不亮环，键盘导航
    // 才亮）。测试环境的 highlightStrategy 为 automatic，会按平台推断成
    // 触摸模式 → onShowFocusHighlight 恒 false。这里显式钉成
    // alwaysTraditional，让「请求焦点 ⇒ 环可见」这条断言稳定成立。
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    addTearDown(
      () => FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.automatic,
    );

    // 同一 tester 内连续 pumpWidget 且 MaterialApp 无 key 时，原位更新
    // 不会把新主题传播到已存在的依赖者。
    // 逐组合换 key 强制重挂，保证每轮读到的是本轮主题。
    var comboIndex = 0;
    for (final (familyId, brightnessName, brightness) in combos) {
      comboIndex++;
      final accent = paletteOf(familyId, brightness).accent;
      final pillFocus = FocusNode(debugLabel: 't05-pill');
      addTearDown(pillFocus.dispose);

      await tester.pumpWidget(
        KeyedSubtree(
          key: ValueKey('t05-glow-$comboIndex'),
          child: MaterialApp(
            theme: themeOf(familyId, brightness),
            home: Scaffold(
              body: Column(
                children: [
                  GlassPillButton(
                    label: 'focus',
                    onPressed: () {},
                    focusNode: pillFocus,
                  ),
                  const SizedBox(height: 16),
                  const GlassInput(child: TextField()),
                ],
              ),
            ),
          ),
        ),
      );

      // GlassPillButton：注入焦点 → 环 + 辉光。
      pillFocus.requestFocus();
      await tester.pump();
      expect(
        _glowColorOf(tester, find.byType(GlassPillButton)),
        GlassMaterials.focusGlow(accent),
        reason: '$familyId $brightnessName GlassPillButton 聚焦辉光必须随本族 accent',
      );
      pillFocus.unfocus();
      await tester.pump();

      // GlassInput：取其最外层 Focus 节点请求焦点 → 辉光。
      final innerFocus = tester
          .widgetList<Focus>(
            find.descendant(
              of: find.byType(GlassInput),
              matching: find.byWidgetPredicate(
                (w) => w is Focus && w.focusNode != null,
              ),
            ),
          )
          .first;
      innerFocus.focusNode!.requestFocus();
      await tester.pump();
      expect(
        _glowColorOf(tester, find.byType(GlassInput)),
        GlassMaterials.focusGlow(accent),
        reason: '$familyId $brightnessName GlassInput 聚焦辉光必须随本族 accent',
      );
      innerFocus.focusNode!.unfocus();
      await tester.pump();
    }
  });
}

Color _glowColorOf(WidgetTester tester, Finder scope) {
  final decorated = tester.widgetList<DecoratedBox>(
    find.descendant(
      of: scope,
      matching: find.byWidgetPredicate(
        (w) =>
            w is DecoratedBox &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).boxShadow != null,
      ),
    ),
  );
  expect(decorated, isNotEmpty, reason: '聚焦态应存在带投影的 DecoratedBox');
  return (decorated.first.decoration as BoxDecoration).boxShadow!.first.color;
}
