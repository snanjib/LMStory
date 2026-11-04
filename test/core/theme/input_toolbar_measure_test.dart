import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/lm_layout.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/structures/classic/narrative/input_toolbar.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// InputToolbar 阅读版心对齐测试（宽窗口下工具行
/// 通铺整窗、行末 chip 被推到窗口最右缘，与正文列失衡）。
///
/// 正文列的阅读限宽是**无条件**的（>800 即收窄居中），工具行同口径：
/// >800 全段钳到 readingMeasure 居中，≤800 钳制自然失效（通铺 + 自身
/// 边距）。若工具行走 ≥1280 门（LmMeasure），800–1280 段会出现
/// "正文已收窄、工具行仍通铺"的错位——本组测试钉住该段。
void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  Widget wrap(Widget child) {
    return TranslationProvider(
      child: MaterialApp(
        theme: ThemeCatalog.assemble(ThemeCatalog.defaults, Brightness.dark),
        home: Scaffold(
          body: Align(alignment: Alignment.bottomCenter, child: child),
        ),
      ),
    );
  }

  Widget toolbar() => InputToolbar(
        onAddQuote: () {},
        onAddParen: () {},
        onSuggest: () {},
        isGeneratingSuggest: false,
        canSuggest: true,
        trailing: const SizedBox(
          key: ValueKey('trailing-chip'),
          width: 40,
          height: 20,
        ),
      );

  Finder rowFinder() => find
      .descendant(
        of: find.byType(InputToolbar),
        matching: find.byType(Row),
      )
      .first;

  double expectedRowWidth(double windowWidth) {
    final measure = LmLayout.measureOf(windowWidth, LmLayout.readingMeasure);
    final contentWidth = windowWidth < measure ? windowWidth : measure;
    return contentWidth - 2 * LmSpacing.sMd;
  }

  double expectedChipRight(double windowWidth) =>
      windowWidth / 2 + expectedRowWidth(windowWidth) / 2;

  for (final width in <double>[900, 1000, 1280, 1600, 2560]) {
    testWidgets('$width px：工具行与正文同版心（>800 段钳制居中）', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(wrap(toolbar()));
      await tester.pumpAndSettle();

      expect(
        tester.getSize(rowFinder()).width,
        closeTo(expectedRowWidth(width), 1),
        reason: '工具行内容宽须等于版心（或窗口）减左右 sMd 边距',
      );
      expect(
        tester.getTopRight(find.byKey(const ValueKey('trailing-chip'))).dx,
        closeTo(expectedChipRight(width), 2),
        reason: '行末 chip 须对齐版心右缘，不再推到窗口最右缘',
      );
    });
  }

  testWidgets('≤800：钳制自然失效，通铺 + 自身边距（窄窗零变化）', (tester) async {
    tester.view.physicalSize = const Size(700, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(wrap(toolbar()));
    await tester.pumpAndSettle();

    expect(
      tester.getSize(rowFinder()).width,
      closeTo(700 - 2 * LmSpacing.sMd, 1),
    );
    expect(
      tester.getTopRight(find.byKey(const ValueKey('trailing-chip'))).dx,
      closeTo(700 - LmSpacing.sMd, 2),
      reason: '窄窗下行末 chip 仍贴窗口右缘（版心未启用）',
    );
  });
}
