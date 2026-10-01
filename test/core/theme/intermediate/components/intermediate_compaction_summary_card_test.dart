import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/intermediate/components/intermediate_compaction_summary_card.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 压缩摘要卡撤销入口（U2，2026-09-04）组件测试。
///
/// 覆盖：撤销按钮可见性（onUndo 为 null 不显示）、不可用置灰、
/// 确认弹窗拦截（取消不触发 / 确认才触发）。
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

  Future<void> expandCard(WidgetTester tester) async {
    await tester.tap(find.text('早期消息已摘要'));
    await tester.pumpAndSettle();
  }

  testWidgets('未提供 onUndo：展开态不显示撤销按钮', (tester) async {
    await tester.pumpWidget(
      wrap(const IntermediateCompactionSummaryCard(content: '摘要内容')),
    );
    await expandCard(tester);
    expect(find.text('撤销压缩'), findsNothing);
  });

  testWidgets('提供 onUndo：展开态显示撤销按钮，确认后才触发回调', (tester) async {
    var undoCalled = false;
    await tester.pumpWidget(
      wrap(
        IntermediateCompactionSummaryCard(
          content: '摘要内容',
          onUndo: () async => undoCalled = true,
        ),
      ),
    );
    await expandCard(tester);
    expect(find.text('撤销压缩'), findsOneWidget);

    // 先取消：回调不得触发
    await tester.tap(find.text('撤销压缩'));
    await tester.pumpAndSettle();
    expect(find.text('撤销这次压缩？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(undoCalled, isFalse);

    // 再确认：回调触发
    await tester.tap(find.text('撤销压缩'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('撤销压缩'),
      ),
    );
    await tester.pumpAndSettle();
    expect(undoCalled, isTrue);
  });

  testWidgets('undoEnabled=false：按钮置灰不可点，不弹确认窗', (tester) async {
    var undoCalled = false;
    await tester.pumpWidget(
      wrap(
        IntermediateCompactionSummaryCard(
          content: '摘要内容',
          onUndo: () async => undoCalled = true,
          undoEnabled: false,
        ),
      ),
    );
    await expandCard(tester);

    final button = tester.widget<TextButton>(
      find.widgetWithText(TextButton, '撤销压缩'),
    );
    expect(button.onPressed, isNull);

    await tester.tap(find.text('撤销压缩'));
    await tester.pumpAndSettle();
    expect(find.text('撤销这次压缩？'), findsNothing);
    expect(undoCalled, isFalse);
  });
}
