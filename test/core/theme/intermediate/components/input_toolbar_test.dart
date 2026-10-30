import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/structures/classic/narrative/input_toolbar.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/i18n/strings.g.dart';

///  圆环重嵌入：InputToolbar 通用尾部插槽回归。
/// 故事模式不传 trailing 必须零变化（不渲染 Spacer、无多余节点）。
void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  Widget wrap(Widget child) {
    return TranslationProvider(
      child: MaterialApp(
        theme: ThemeCatalog.assemble(ThemeCatalog.defaults, Brightness.dark),
        home: Scaffold(body: child),
      ),
    );
  }

  InputToolbar buildToolbar({Widget? trailing}) => InputToolbar(
        onAddQuote: () {},
        onAddParen: () {},
        onSuggest: () {},
        isGeneratingSuggest: false,
        canSuggest: true,
        trailing: trailing,
      );

  testWidgets('不传 trailing（故事模式）：零变化，无 Spacer', (tester) async {
    await tester.pumpWidget(wrap(buildToolbar()));

    expect(find.byType(InputToolbar), findsOneWidget);
    expect(find.byType(Spacer), findsNothing);
    // 三个功能 chip 照常渲染（InkWell 载体 + 文案）
    expect(
      find.descendant(
        of: find.byType(InputToolbar),
        matching: find.byType(InkWell),
      ),
      findsNWidgets(3),
    );
  });

  testWidgets('传 trailing（导演模式）：渲染在行末，右缘对齐 12px 内容边距', (
    tester,
  ) async {
    const screenW = 800.0;
    await tester.pumpWidget(
      wrap(
        SizedBox(
          width: screenW,
          child: buildToolbar(
            trailing: const SizedBox(
              key: Key('trailing-slot'),
              width: 40,
              height: 32,
            ),
          ),
        ),
      ),
    );

    expect(find.byType(Spacer), findsOneWidget);
    final trailingBox =
        tester.renderObject<RenderBox>(find.byKey(const Key('trailing-slot')));
    // toolbar 自带 right padding sMd=12：trailing 右缘 = 宽度 − 12
    expect(trailingBox.size.width, 40);
    expect(
      trailingBox.localToGlobal(Offset.zero).dx,
      closeTo(screenW - 12 - 40, 0.5),
    );
  });
}
