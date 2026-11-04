import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/palettes/classic/classic_palette.dart';
import 'package:lmstory/core/theme/system/structures/classic/narrative/intermediate_confirm_dialog.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// IntermediateConfirmDialog 组件测试（简化 Fork）
///
/// 验证：
/// - 渲染：标题 / 正文 / 取消按钮 / 确认按钮文案正确
/// - 取消按钮：muted 文字色（偏离 textButtonTheme 的 primary）
/// - 确认按钮：error 底 + bg 文字色（危险操作对比度 5.9:1）
/// - 交互：取消 → false；确认 → true；barrier dismiss → false
void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  Widget wrap() {
    return TranslationProvider(
      child: MaterialApp(
        theme: ThemeCatalog.assemble(ThemeCatalog.defaults, Brightness.dark),
        home: const Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: null,
              child: Text('host'),
            ),
          ),
        ),
      ),
    );
  }

  /// 启动弹窗并返回 result Future（不 await，让弹窗保持打开直到交互）
  Future<bool> launchDialog(WidgetTester tester) {
    final state = tester.state(find.byType(ElevatedButton));
    return IntermediateConfirmDialog.show(
      context: state.context,
      title: '确认删除',
      content: '删除此轮及之后的所有消息？此操作不可恢复。',
      confirmLabel: '删除',
    );
  }

  group('IntermediateConfirmDialog', () {
    testWidgets('1. 渲染标题、正文、按钮文案', (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      // ignore: unawaited_futures
      launchDialog(tester);
      await tester.pumpAndSettle();

      expect(find.text('确认删除'), findsOneWidget);
      expect(
        find.text('删除此轮及之后的所有消息？此操作不可恢复。'),
        findsOneWidget,
      );
      // 取消按钮使用 i18n 的 t.common.cancel = "取消"
      expect(find.text('取消'), findsOneWidget);
      // 确认按钮文字（find.text 精确匹配，正文是不同字符串）
      expect(find.text('删除'), findsOneWidget);
    });

    testWidgets('2. 点取消按钮返回 false', (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      final future = launchDialog(tester);
      await tester.pumpAndSettle();

      await tester.tap(find.text('取消'));
      final result = await future;
      await tester.pumpAndSettle();

      expect(result, isFalse);
    });

    testWidgets('3. 点确认按钮返回 true', (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      final future = launchDialog(tester);
      await tester.pumpAndSettle();

      // "删除" 同时是 confirmLabel 和正文里的词——用 descendant 限定到 ElevatedButton
      final confirmButton = find.descendant(
        of: find.byType(ElevatedButton),
        matching: find.text('删除'),
      );
      await tester.tap(confirmButton);
      final result = await future;
      await tester.pumpAndSettle();

      expect(result, isTrue);
    });

    testWidgets('4. barrier dismiss 返回 false（默认值）', (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      final future = launchDialog(tester);
      await tester.pumpAndSettle();

      // 点 barrier 关闭弹窗（屏幕左上角，远离弹窗中心）
      await tester.tapAt(const Offset(10, 10));
      final result = await future;
      await tester.pumpAndSettle();

      expect(result, isFalse);
    });

    testWidgets('5. 取消按钮使用 muted 文字色', (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      // ignore: unawaited_futures
      launchDialog(tester);
      await tester.pumpAndSettle();

      final cancelButtonFinder = find.ancestor(
        of: find.text('取消'),
        matching: find.byType(TextButton),
      );
      final cancelButton = tester.widget<TextButton>(cancelButtonFinder);
      final fgColor = cancelButton.style?.foregroundColor?.resolve({});
      expect(fgColor, ClassicPaletteValues.dark.muted);
    });

    testWidgets('6. 确认按钮使用 error 底 + bg 文字色', (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      // ignore: unawaited_futures
      launchDialog(tester);
      await tester.pumpAndSettle();

      final confirmButtonFinder = find.ancestor(
        of: find.text('删除'),
        matching: find.byType(ElevatedButton),
      );
      final confirmButton = tester.widget<ElevatedButton>(confirmButtonFinder);
      final bgColor = confirmButton.style?.backgroundColor?.resolve({});
      final fgColor = confirmButton.style?.foregroundColor?.resolve({});
      expect(bgColor, ClassicPaletteValues.dark.error);
      expect(fgColor, ClassicPaletteValues.dark.bg);
    });
  });
}
