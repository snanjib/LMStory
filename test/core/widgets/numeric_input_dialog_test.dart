import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/widgets/numeric_input_dialog.dart';
import 'package:lmstory/i18n/strings.g.dart';

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  Future<void> openDialog(
    WidgetTester tester, {
    required void Function(double) onConfirmed,
  }) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => showNumericInputDialog(
                    context: context,
                    title: '温度',
                    currentValue: 0.5,
                    min: 0,
                    max: 1,
                    onConfirmed: onConfirmed,
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('valid input confirms the parsed value', (tester) async {
    double? result;
    await openDialog(tester, onConfirmed: (v) => result = v);

    await tester.enterText(find.byType(TextField), '0.75');
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();

    expect(result, 0.75);
  });

  testWidgets('non-numeric input shows invalid snackbar and does not confirm',
      (tester) async {
    double? result;
    await openDialog(tester, onConfirmed: (v) => result = v);

    await tester.enterText(find.byType(TextField), 'abc');
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();

    expect(result, isNull);
    expect(find.text('请输入有效数值'), findsOneWidget);
  });

  testWidgets('out-of-range input shows out-of-range snackbar', (tester) async {
    double? result;
    await openDialog(tester, onConfirmed: (v) => result = v);

    await tester.enterText(find.byType(TextField), '5');
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();

    expect(result, isNull);
    expect(find.text('数值超出范围'), findsOneWidget);
  });

  testWidgets('cancel closes the dialog without confirming', (tester) async {
    double? result;
    await openDialog(tester, onConfirmed: (v) => result = v);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(result, isNull);
    expect(find.byType(AlertDialog), findsNothing);
  });
}
