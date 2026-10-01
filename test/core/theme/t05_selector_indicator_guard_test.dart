import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/system/structures/classic/conversation/simple_selection_option.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';

///  守卫：单选选项行「选中行底色 + 行内左置指示」（发现 F 收口）。
///
/// 原行勾号挂在 Row 尾端：外观页选项行在 ≥1200px 全宽容器下勾号距
/// 标签约 1900px，扫读断裂。收口后选中态 = `primaryDim` 底 + 行内左置
/// 勾号，勾号-标签间距恒为 `LmSpacing.sSm`，与视口宽度无关。守卫锁死：
/// 1. 宽屏（1900px）：指示在标签左侧、间距 ≤ 3×sSm（构造值 8px 的容差）；
/// 2. 选中行底色 = primaryDim，未选中行无勾号无底色；
/// 3. 窄屏（<600px 断点）：同构造同观感不回归，行可点。
LmPalette paletteOf(Brightness brightness) =>
    ThemeCatalog.assemble(const LmAppearance(), brightness)
        .extension<LmTokens>()!
        .palette;

Future<void> pumpGroup(
  WidgetTester tester, {
  required double width,
  Brightness brightness = Brightness.light,
}) async {
  await tester.binding.setSurfaceSize(Size(width, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    KeyedSubtree(
      key: ValueKey('selector-$width-$brightness'),
      child: MaterialApp(
        theme: ThemeCatalog.assemble(const LmAppearance(), brightness),
        home: Scaffold(
          body: Center(
            child: Container(
              width: double.infinity,
              margin: const EdgeInsets.symmetric(horizontal: 24),
              decoration: BoxDecoration(
                color: paletteOf(brightness).surfaceVariant,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SimpleSelectionOption(
                    label: 'Option A',
                    isSelected: true,
                    onTap: () {},
                  ),
                  SimpleSelectionOption(
                    label: 'Option B',
                    isSelected: false,
                    onTap: () {},
                  ),
                  SimpleSelectionOption(
                    label: 'Option C',
                    isSelected: false,
                    isEnabled: false,
                    onTap: () {},
                    disabledLabel: '(v0.2)',
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('宽屏 1900px：指示左置且紧贴标签，选中行有 primaryDim 底', (
    tester,
  ) async {
    await pumpGroup(tester, width: 1900);

    final checkRect = tester.getRect(find.byIcon(Icons.check));
    final labelRect = tester.getRect(find.text('Option A'));

    expect(
      checkRect.center.dx,
      lessThan(labelRect.left),
      reason: '勾号必须在标签左侧（行内指示）',
    );
    expect(
      labelRect.left - checkRect.right,
      inInclusiveRange(0, LmSpacing.sSm * 3),
      reason: '勾号-标签间距必须紧贴（构造值 sSm=8px），宽屏不得断裂',
    );

    final tinted = tester.widgetList<Container>(
      find.byWidgetPredicate(
        (w) =>
            w is Container &&
            w.decoration is BoxDecoration &&
            (w.decoration! as BoxDecoration).color ==
                paletteOf(Brightness.light).primaryDim,
      ),
    );
    expect(tinted, hasLength(1), reason: '恰好选中行带 primaryDim 底色');
  });

  testWidgets('未选中行：无勾号、无底色；禁用行保留占位标签', (tester) async {
    await pumpGroup(tester, width: 1900);

    expect(find.byIcon(Icons.check), findsOneWidget);
    expect(find.text('(v0.2)'), findsOneWidget);

    final untinted = tester
        .widgetList<Container>(
          find.ancestor(
            of: find.text('Option B'),
            matching: find.byWidgetPredicate(
              (w) =>
                  w is Container &&
                  w.decoration is BoxDecoration &&
                  (w.decoration! as BoxDecoration).color != null,
            ),
          ),
        )
        .first;
    expect(
      (untinted.decoration! as BoxDecoration).color,
      isNot(paletteOf(Brightness.light).primaryDim),
      reason: '未选中行不得带选中底色',
    );
  });

  testWidgets('窄屏 400px（<600 断点）：同构造不回归，行可点', (tester) async {
    await pumpGroup(tester, width: 400, brightness: Brightness.dark);

    final checkRect = tester.getRect(find.byIcon(Icons.check));
    final labelRect = tester.getRect(find.text('Option A'));
    expect(checkRect.center.dx, lessThan(labelRect.left));
    expect(
      labelRect.left - checkRect.right,
      inInclusiveRange(0, LmSpacing.sSm * 3),
    );

    var tapped = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeCatalog.assemble(const LmAppearance(), Brightness.dark),
        home: Scaffold(
          body: SimpleSelectionOption(
            label: 'Tap me',
            isSelected: false,
            onTap: () => tapped = true,
          ),
        ),
      ),
    );
    await tester.tap(find.text('Tap me'));
    expect(tapped, isTrue);
  });
}
